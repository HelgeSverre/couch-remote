# TVKit

Swift library and CLI (`tvctl`) for controlling Samsung Tizen TVs on the local network. No dependencies.

Tested on a Samsung QE55Q65AAUXXC (2021, Tizen 6). The notes below describe that TV; where other model years are known to differ, TVKit adapts (see "Other model years").

## Use it from another package

TVKit is a library product of the Couch Remote package:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/HelgeSverre/couch-remote.git", branch: "main"),
],
// in your target:
dependencies: [.product(name: "TVKit", package: "couch-remote")]
```

SwiftPM names a dependency after its repository or folder (`couch-remote`), not after the
manifest's `name:`. With `.package(path:)`, use the folder name.

```swift
import TVKit

let tv = SamsungTV(host: "192.168.10.57", token: savedToken)
try await tv.connect(allowPairing: true)   // first time: press Allow on the TV
let token = await tv.token                 // store this

tv.press(.volumeUp)                        // queued, sent in order
tv.press(.home)
tv.hold(.right); tv.release(.right)        // held keys repeat on the TV, like the physical remote
tv.movePointer(dx: 120, dy: -40)           // browser cursor, ~1 unit per pixel at 1920×1080
tv.click(.left)
tv.setText("star wars")                    // replaces the focused field's contents
tv.submitText()
try await tv.launch(appID: KnownApps.youtube)
try await tv.setVolume(12)
let apps = await tv.installedApps()        // [TVApp]
let front = await tv.statuses(ofApps: apps.map(\.id)).first(where: \.visible)
```

`SamsungTV.events` reports pairing (`.paired(token:)`), connection changes and the TV's on-screen keyboard opening and closing.

## What the TV exposes

Full message formats, tested behavior and sdb details: [docs/PROTOCOL.md](../../docs/PROTOCOL.md).

| Port | Interface | Pairing | Used for |
|---|---|---|---|
| 8001 | REST (`/api/v2/`) | no | device info, app state, launching apps |
| 8002 | WebSocket `samsung.remote.control` (TLS, self-signed) | yes, Allow prompt on TV | remote keys, text input, pointer |
| 9197 | UPnP RenderingControl | no | volume and mute |
| 8080 | DIAL | no | cast-style app info (not used) |
| 26101 | sdb (Smart Development Bridge, adb protocol) | Developer Mode, host IP set on TV | exact app list, file copies, starting system apps |
| — | Wake-on-LAN to the Wi-Fi MAC | no | power on from standby |

## Other model years

These come from other projects' reports, not from testing here:

- **Remote socket:** TVs that report `TokenAuthSupport: "true"` (about 2018 on) use `wss://…:8002` with a token. Older Tizen TVs omit it or report false; `SamsungTV` then uses plain `ws://…:8001` without pairing. Pre-2016 (non-Tizen) TVs use a different protocol and aren't supported.
- **Launching:** `SamsungTV.launch` tries `POST /api/v2/applications/{id}` and falls back to the socket's `ed.apps.launch` when the TV refuses it.
- **Volume:** the RenderingControl address is read from `http://<tv>:9197/dmr`, with `/upnp/control/RenderingControl1` as fallback. With a soundbar on HDMI ARC the TV's own volume may not apply.
- **App IDs** differ by model year and region (Netflix is `11101200001` on older TVs, `3201907018807` on newer ones). Always take IDs from `installedApps()` on the TV at hand; `KnownApps` lists what the tested TV uses.
- **Wake-on-LAN** sends to the Wi-Fi MAC the TV reports. A TV on Ethernet needs its Ethernet MAC, and the TV must have "Power On with Mobile" enabled.

## Firmware quirks (2021 / Tizen 6)

- **No installed-apps list.** `ed.installedApp.get` and `ed.apps.icon` get no reply. `AppCatalog.scan` checks about 200 known app IDs over REST instead (about 3 s). Names come from the TV, so a wrong catalog entry can't mislabel an app.
- **Launching over the WebSocket is ignored.** `POST /api/v2/applications/{id}` works.
- **App IDs** are `320` + registration month (YYMM) + a running counter, e.g. `3202012022410` is NRK TV (registered December 2020). Package IDs like `9Ur5IzDKqV.TizenYouTube` also work with the REST API.
- **Holding keys:** `Cmd: "Press"` then `"Release"`; the TV auto-repeats in between (2 s of Volume Up: +30). A quick press and release is one step.
- **Pointer:** `TypeOfRemote: "ProcessMouseDevice"` with `Cmd: "Move"` (relative x/y) or `"LeftClick"`/`"RightClick"`.
- **Text input** (`SendInputString`) replaces the field's contents: "ab" then "abc" leaves "abc". The TV answers with `ms.remote.imeDone`.
- **Input keys:** `KEY_SOURCE` opens the input list; `KEY_HDMI1`/`KEY_HDMI2` do nothing.
- **Icons** aren't available from the TV; `AppIcons` fetches them from each app's website.

## Developer Mode and sdb

With Developer Mode on (Apps screen → 1 2 3 4 5 → On, Host PC IP = your Mac, restart the TV), `SDB` talks to the TV's sdb daemon directly. No Tizen Studio needed: sdb is Tizen's fork of adb with the same wire protocol, and the TV asks for no authentication.

```swift
let sdb = SDB(host: "192.168.10.57")
let apps = try await sdb.installedApps()        // ID, Tizen ID, install date, use count
let tile = try await sdb.pull("/opt/share/webappservice/apps_icon/all/111399002181/304x304.png")
try await sdb.execute("org.volt.apps")           // open the Apps screen
let raw = try await sdb.shell("0 applist")       // all 400+ Tizen apps, system ones included
```

The TV has no interactive shell; only `shell:0 <command>` works. `SamsungTV.installedApps()` uses sdb when it can and falls back to `AppCatalog.scan`.

## tvctl

```
swift run tvctl info
swift run tvctl pair
swift run tvctl key VOLUP VOLUP HOME
swift run tvctl apps
swift run tvctl launch netflix
swift run tvctl remap "Prime Video" YouTube
swift run tvctl sdb apps                # Developer Mode only
swift run tvctl sdb 0 getduid
```

`tvctl` and Couch Remote share `~/Library/Application Support/CouchRemote/config.json`, including the pairing token.
