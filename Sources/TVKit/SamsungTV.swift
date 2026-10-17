import Foundation

public enum SamsungTVError: LocalizedError {
    /// No token yet and pairing was not allowed for this call.
    case notPaired

    public var errorDescription: String? {
        switch self {
        case .notPaired: "Couch Remote isn't paired with this TV yet."
        }
    }
}

/// One TV, with everything that can be done to it over the network.
///
/// Combines the three interfaces the TV exposes:
/// - remote-control WebSocket (port 8002, needs pairing): keys and text
/// - REST API (port 8001, no pairing): device info, app state, launching apps
/// - UPnP RenderingControl (port 9197, no pairing): volume and mute
///
/// Keys and text sent with `press(_:)`, `hold(_:)`/`release(_:)` and `type(_:)` go through one queue,
/// so they reach the TV in order.
/// Connection changes, pairing results and on-screen keyboard state arrive on `events`.
public actor SamsungTV {
    public enum Event: Sendable {
        /// The TV is showing its Allow prompt.
        case awaitingApproval
        case connected
        case disconnected
        /// The TV issued a new token (store it), or revoked it (`nil`).
        case paired(token: String?)
        case keyboardShown
        case keyboardHidden
        case commandFailed(String)
    }

    public nonisolated let host: String
    public nonisolated let clientName: String
    public nonisolated let events: AsyncStream<Event>
    public private(set) var token: String?

    private nonisolated let eventSink: AsyncStream<Event>.Continuation
    private nonisolated let commandSink: AsyncStream<Command>.Continuation
    private var channel: RemoteChannel?
    private var connectTask: Task<Void, Error>?
    /// Keys sent as `Press` and not yet released.
    private var held: Set<RemoteKey> = []

    private enum Command: Sendable {
        case key(RemoteKey, KeyAction)
        case text(String)
        case submitText
        case releaseAll
        case pointer(dx: Int, dy: Int)
        case click(PointerButton)
    }

    public init(host: String, token: String?, clientName: String = "Couch Remote") {
        self.host = host
        self.token = token
        self.clientName = clientName
        (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(64))
        let (commands, commandSink) = AsyncStream.makeStream(of: Command.self)
        self.commandSink = commandSink
        Task { [weak self] in
            for await command in commands {
                await self?.run(command)
            }
        }
    }

    // MARK: Connection

    public var isConnected: Bool { channel?.isConnected == true }

    /// Connects the remote-control socket. With `allowPairing`, a TV without our token shows its Allow
    /// prompt and this waits up to 45 seconds for it.
    public func connect(allowPairing: Bool = false) async throws {
        if isConnected { return }
        if let connectTask { return try await connectTask.value }
        guard token != nil || allowPairing else { throw SamsungTVError.notPaired }
        let task = Task { try await openChannel() }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    /// Forgets the token and closes the connection. The next `connect(allowPairing: true)` pairs again.
    public func unpair() {
        disconnect()
        token = nil
        eventSink.yield(.paired(token: nil))
    }

    public func disconnect() {
        channel?.close()
        channel = nil
    }

    private func openChannel() async throws {
        let pairing = token == nil
        if pairing { eventSink.yield(.awaitingApproval) }
        let channel = RemoteChannel(host: host, clientName: clientName)
        do {
            let issued = try await channel.connect(token: token, timeout: pairing ? 45 : 8)
            if let issued, issued != token {
                token = issued
                eventSink.yield(.paired(token: issued))
            }
        } catch RemoteChannelError.unauthorized {
            token = nil
            eventSink.yield(.paired(token: nil))
            throw RemoteChannelError.unauthorized
        }
        self.channel = channel
        eventSink.yield(.connected)
        Task { [weak self] in
            for await event in channel.events {
                await self?.forward(event, from: channel)
            }
            await self?.channelEnded(channel)
        }
    }

    private func forward(_ event: RemoteEvent, from source: RemoteChannel) {
        switch event {
        case .keyboardShown: eventSink.yield(.keyboardShown)
        case .keyboardHidden: eventSink.yield(.keyboardHidden)
        case .disconnected: channelEnded(source)
        case .installedApps, .icon: break
        }
    }

    private func channelEnded(_ source: RemoteChannel) {
        guard channel === source else { return }
        channel = nil
        held.removeAll()
        eventSink.yield(.disconnected)
    }

    // MARK: Remote

    /// Queues a key press. Connects first if needed (never pairs).
    public nonisolated func press(_ key: RemoteKey) {
        commandSink.yield(.key(key, .click))
    }

    /// Starts holding a key, like keeping a remote button down: the TV repeats it (moving a cursor,
    /// scrolling, raising volume) until `release(_:)`. A quick hold then release counts as one press.
    public nonisolated func hold(_ key: RemoteKey) {
        commandSink.yield(.key(key, .press))
    }

    public nonisolated func release(_ key: RemoteKey) {
        commandSink.yield(.key(key, .release))
    }

    /// Releases every held key. Call when the UI loses track of the mouse or keyboard, so nothing sticks.
    public nonisolated func releaseAll() {
        commandSink.yield(.releaseAll)
    }

    /// Moves the TV's pointer by a relative amount (about one pixel of a 1920×1080 screen per unit).
    /// Works in the TV's browser and other pointer-aware apps.
    public nonisolated func movePointer(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        commandSink.yield(.pointer(dx: dx, dy: dy))
    }

    public nonisolated func click(_ button: PointerButton = .left) {
        commandSink.yield(.click(button))
    }

    /// Replaces the contents of the TV's focused text field (the field shows exactly `text` afterwards).
    /// Send the whole string on every keystroke for live typing; send a shorter one to erase.
    public nonisolated func setText(_ text: String) {
        commandSink.yield(.text(text))
    }

    /// Confirms the text field, like pressing Done on the TV's keyboard.
    public nonisolated func submitText() {
        commandSink.yield(.submitText)
    }

    /// Sets the focused text field to `text` and confirms it.
    public nonisolated func type(_ text: String) {
        setText(text)
        submitText()
    }

    /// Sends a key right away and reports failure to the caller.
    public func send(_ key: RemoteKey, action: KeyAction = .click) async throws {
        try await connect()
        try channel?.sendKey(key, action: action)
    }

    private func run(_ command: Command) async {
        do {
            try await connect()
            switch command {
            case .key(let key, let action):
                try channel?.sendKey(key, action: action)
                switch action {
                case .press: held.insert(key)
                case .release: held.remove(key)
                case .click: break
                }
            case .releaseAll:
                for key in held { try channel?.sendKey(key, action: .release) }
                held.removeAll()
            case .pointer(let dx, let dy):
                try channel?.movePointer(dx: dx, dy: dy)
            case .click(let button):
                try channel?.clickPointer(button)
            case .text(let text):
                try channel?.sendText(text)
            case .submitText:
                try channel?.endText()
            }
        } catch {
            eventSink.yield(.commandFailed(error.localizedDescription))
        }
    }

    // MARK: Apps, status, volume (no pairing needed)

    public nonisolated func info() async throws -> DeviceInfo {
        try await TVRest.deviceInfo(host: host)
    }

    public nonisolated func launch(appID: String) async throws {
        guard try await TVRest.launch(host: host, appID: appID) else {
            throw URLError(.badServerResponse)
        }
    }

    public nonisolated func status(ofApp appID: String) async throws -> AppStatus? {
        try await TVRest.appStatus(host: host, appID: appID)
    }

    /// Statuses of the given apps, fetched in parallel. Apps that aren't installed are left out.
    public nonisolated func statuses(ofApps appIDs: [String]) async -> [AppStatus] {
        let host = host
        return await withTaskGroup(of: AppStatus?.self) { group in
            for id in appIDs { group.addTask { try? await TVRest.appStatus(host: host, appID: id) } }
            var found: [AppStatus] = []
            for await status in group { if let status { found.append(status) } }
            return found
        }
    }

    /// Installed apps, most used first when the TV is in Developer Mode (exact list over sdb),
    /// otherwise in catalog order (found by checking known app IDs).
    public nonisolated func installedApps(extraIDs: [String] = []) async -> [TVApp] {
        if let apps = try? await SDB(host: host).installedApps(), !apps.isEmpty {
            return apps.sorted { $0.useCount > $1.useCount }.map { TVApp(id: $0.id, name: $0.title) }
        }
        return await AppCatalog.scan(host: host, extraIDs: extraIDs)
    }

    public nonisolated func volume() async throws -> Int {
        try await RenderingControl(host: host).volume()
    }

    public nonisolated func setVolume(_ volume: Int) async throws {
        try await RenderingControl(host: host).setVolume(volume)
    }

    public nonisolated func isMuted() async throws -> Bool {
        try await RenderingControl(host: host).isMuted()
    }

    public nonisolated func setMuted(_ muted: Bool) async throws {
        try await RenderingControl(host: host).setMuted(muted)
    }

    /// Watches for any source app in `remaps` coming to the front and opens its target instead.
    /// Runs until the calling task is cancelled. The source app shows for about a second before the switch.
    public nonisolated func runRemaps(_ remaps: [String: String], every interval: Duration = .milliseconds(700)) async {
        let sources = Array(remaps.keys)
        guard !sources.isEmpty else { return }
        while !Task.isCancelled {
            let front = await statuses(ofApps: sources).first(where: \.visible)
            if let front, let target = remaps[front.id] {
                try? await launch(appID: target)
                try? await Task.sleep(for: .seconds(3))
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// Wakes a TV in standby. Needs the TV's MAC address, which `info()` reports while it is on.
    public static func wake(mac: String, near host: String? = nil) throws {
        try WakeOnLAN.send(mac: mac, near: host)
    }
}
