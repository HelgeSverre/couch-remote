import Foundation
import TVKit

// tvctl: command-line twin of Couch Remote. Shares its config file (and therefore its pairing token).

let usage = """
usage: tvctl [--host <ip>] <command> [args]

  discover              find Samsung TVs on this network and remember the first
  use <ip>              remember a TV address
  info                  model, power state, developer mode
  pair [--again]        connect and wait for Allow on the TV; saves the token
  key <KEY> [...]       send remote keys, e.g. key VOLUP VOLUP or key KEY_HOME
  hold <KEY> <seconds>  hold a key down, e.g. hold RIGHT 1.5 to keep moving right
  apps                  find installed apps (checks known app IDs)
  launch <id|name>      open an app
  status <id>           running / in-front state of an app
  volume [0-100]        read or set volume
  mute [on|off]         read or set mute
  text <words...>       type into the TV's on-screen keyboard
  remap <from> <to>     open app <to> whenever app <from> comes to the front (runs until Ctrl-C)
  wake                  send Wake-on-LAN to the TV's Wi-Fi MAC
  raw '<json>' [...]    send WebSocket messages as-is (with TVKIT_DEBUG=1 to see replies)
"""

var config = ConfigStore.load()
var args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--host"), i + 1 < args.count {
    config.host = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let command = args.first ?? "help"
let rest = Array(args.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@MainActor func save() {
    do { try ConfigStore.save(config) } catch { fail("Could not save \(ConfigStore.fileURL.path): \(error)") }
}

@MainActor func makeTV() -> SamsungTV {
    guard let host = config.host else { fail("No TV address. Run `tvctl discover` or pass --host <ip>.") }
    return SamsungTV(host: host, token: config.token)
}

/// Connects (pairing if needed) and stores any token the TV issues.
@MainActor func connected() async -> SamsungTV {
    let tv = makeTV()
    if config.token == nil { print("Press Allow on the TV…") }
    do {
        try await tv.connect(allowPairing: true)
    } catch {
        fail("Could not connect: \(error.localizedDescription)")
    }
    if let token = await tv.token, token != config.token {
        config.token = token
        save()
    }
    return tv
}

@MainActor func resolveApp(_ query: String) async -> String {
    let apps = config.knownApps.isEmpty ? await makeTV().installedApps(extraIDs: config.customAppIDs) : config.knownApps
    let needle = query.lowercased()
    return apps.first(where: { $0.id == query || $0.name.lowercased().hasPrefix(needle) })?.id ?? query
}

func keyName(_ raw: String) -> RemoteKey {
    let upper = raw.uppercased()
    return RemoteKey(upper.hasPrefix("KEY_") ? upper : "KEY_" + upper)
}

@MainActor func run() async throws {
    switch command {
    case "discover":
        let tvs = await Discovery.find()
        guard !tvs.isEmpty else { fail("No Samsung TV answered on this network.") }
        for tv in tvs { print("\(tv.host)\t\(tv.name)\t\(tv.modelName)") }
        if config.host == nil, let first = tvs.first {
            config.host = first.host
            save()
            print("Saved \(first.host)")
        }

    case "use":
        guard let host = rest.first else { fail("usage: tvctl use <ip>") }
        if host != config.host {
            config.token = nil
            config.knownApps = []
        }
        config.host = host
        save()
        print("Saved \(host)")

    case "info":
        let info = try await makeTV().info()
        print("""
        name        \(info.name)
        model       \(info.modelName) (\(info.model ?? "?"))
        power       \(info.powerState ?? "?")
        os          \(info.os ?? "?")
        wifi mac    \(info.wifiMAC ?? "?")
        developer   \(info.developerMode ? "on, host \(info.developerIP ?? "?")" : "off")
        paired      \(config.token == nil ? "no" : "yes")
        """)
        if config.wifiMAC == nil, let mac = info.wifiMAC {
            config.wifiMAC = mac
            save()
        }

    case "pair":
        if rest.first == "--again" { config.token = nil }
        let tv = await connected()
        print("Paired. Token saved to \(ConfigStore.fileURL.path)")
        await tv.disconnect()

    case "key":
        guard !rest.isEmpty else { fail("usage: tvctl key <KEY> [...]") }
        let tv = await connected()
        for raw in rest {
            try await tv.send(keyName(raw))
            try await Task.sleep(for: .milliseconds(350))
        }
        await tv.disconnect()

    case "hold":
        guard rest.count == 2, let seconds = Double(rest[1]) else { fail("usage: tvctl hold <KEY> <seconds>") }
        let tv = await connected()
        tv.hold(keyName(rest[0]))
        try await Task.sleep(for: .seconds(seconds))
        tv.release(keyName(rest[0]))
        try await Task.sleep(for: .milliseconds(400))
        await tv.disconnect()

    case "apps":
        let apps = await makeTV().installedApps(extraIDs: config.customAppIDs)
        for app in apps.sorted(by: { AppCatalog.rank(of: $0) < AppCatalog.rank(of: $1) }) {
            print("\(app.id)\t\(app.name)")
        }
        config.knownApps = apps
        save()

    case "launch":
        guard !rest.isEmpty else { fail("usage: tvctl launch <id|name>") }
        let id = await resolveApp(rest.joined(separator: " "))
        try await makeTV().launch(appID: id)
        print("Opened \(config.knownApps.first(where: { $0.id == id })?.name ?? id)")

    case "status":
        guard let id = rest.first else { fail("usage: tvctl status <id>") }
        guard let status = try await makeTV().status(ofApp: id) else { fail("Not installed.") }
        print("\(status.name)\trunning=\(status.running)\tvisible=\(status.visible)")

    case "volume":
        let tv = makeTV()
        if let raw = rest.first {
            guard let value = Int(raw) else { fail("usage: tvctl volume [0-100]") }
            try await tv.setVolume(value)
        }
        print(try await tv.volume())

    case "mute":
        let tv = makeTV()
        if let raw = rest.first { try await tv.setMuted(raw == "on") }
        print(try await tv.isMuted() ? "on" : "off")

    case "text":
        guard !rest.isEmpty else { fail("usage: tvctl text <words...>") }
        let tv = await connected()
        tv.type(rest.joined(separator: " "))
        try await Task.sleep(for: .milliseconds(600))
        await tv.disconnect()

    case "remap":
        guard rest.count == 2 else { fail("usage: tvctl remap <from> <to>") }
        let from = await resolveApp(rest[0]), to = await resolveApp(rest[1])
        print("Opening \(to) whenever \(from) comes to the front. Ctrl-C to stop.")
        await makeTV().runRemaps([from: to])

    case "raw":
        guard !rest.isEmpty else { fail("usage: TVKIT_DEBUG=1 tvctl raw '<json>' [...]") }
        guard let host = config.host else { fail("No TV address.") }
        let channel = RemoteChannel(host: host)
        _ = try await channel.connect(token: config.token)
        for message in rest {
            guard let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
            else { fail("Not a JSON object: \(message)") }
            try channel.send(object)
            try await Task.sleep(for: .seconds(2))
        }
        channel.close()

    case "sdb":
        // Developer Mode only. `tvctl sdb 0 vd_applist`, `tvctl sdb pull <path> <file>`, `tvctl sdb apps`.
        guard let host = config.host else { fail("No TV address.") }
        let sdb = SDB(host: host)
        switch rest.first {
        case "pull":
            guard rest.count == 3 else { fail("usage: tvctl sdb pull <remote path> <local file>") }
            let data = try await sdb.pull(rest[1])
            try data.write(to: URL(fileURLWithPath: rest[2]))
            print("Saved \(data.count) bytes to \(rest[2])")
        case "apps":
            for app in try await sdb.installedApps().sorted(by: { $0.useCount > $1.useCount }) {
                print("\(app.id)\t\(app.useCount)\t\(app.tizenID)\t\(app.title)")
            }
        case nil:
            fail("usage: tvctl sdb <shell command> | pull <path> <file> | apps")
        default:
            print(try await sdb.shell(rest.joined(separator: " ")), terminator: "")
        }

    case "wake":
        guard let mac = config.wifiMAC else { fail("No MAC address saved. Run `tvctl info` while the TV is on.") }
        try SamsungTV.wake(mac: mac, near: config.host)
        print("Sent Wake-on-LAN to \(mac)")

    default:
        print(usage)
    }
}

do {
    try await run()
} catch {
    fail(error.localizedDescription)
}
