# TVKit

Swift library and CLI (`tvctl`) for controlling Samsung Tizen TVs on the local network. Built and tested against a 2021 QE55Q65AAUXXC (Tizen 6). No dependencies.

## Use it from another package

```swift
.package(path: "<path to this package>")   // TVKit is a library product of this package
// target dependency:
.product(name: "TVKit", package: "CouchRemote")
```

```swift
import TVKit

let tv = SamsungTV(host: "192.168.10.170", token: savedToken)
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

| Port | Interface | Pairing | Used for |
|---|---|---|---|
| 8001 | REST (`/api/v2/`) | no | device info, app state, launching apps |
| 8002 | WebSocket `samsung.remote.control` (TLS, self-signed) | yes, Allow prompt on TV | remote keys, text input |
| 9197 | UPnP RenderingControl | no | volume and mute |
| 8080 | DIAL | no | cast-style app info (not used) |
| 26101 | sdb (Smart Development Bridge, adb protocol) | Developer Mode, host IP set on TV | exact app list, file copies, starting system apps |
| — | Wake-on-LAN to the Wi-Fi MAC | no | power on from standby |

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
let sdb = SDB(host: "192.168.10.170")
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
