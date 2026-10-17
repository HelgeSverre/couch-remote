# Samsung Tizen TV network protocols

How Couch Remote and TVKit talk to a Samsung Tizen TV on the local network. Everything here was checked against a **QE55Q65AAUXXC (2021, Tizen 6.0)** unless marked *reported*: those notes come from other open-source projects and haven't been tested here.

| Port | Interface | Pairing | Used for |
|---|---|---|---|
| 1900/udp | SSDP | no | finding TVs |
| 8001 | REST API (HTTP) | no | device info, app state, launching apps |
| 8002 | Remote-control WebSocket (TLS) | yes | keys, pointer, text input |
| 9197 | UPnP media renderer | no | volume and mute |
| 8080 | DIAL | no | cast-style app info |
| 9/udp | Wake-on-LAN | no | power on from standby |
| 26101 | sdb (Developer Mode only) | host IP set on the TV | exact app list, files, starting system apps |

## Discovery (SSDP)

Send an M-SEARCH to `239.255.255.250:1900`:

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 2
ST: urn:samsung.com:device:RemoteControlReceiver:1
```

Samsung TVs answer from their own IP. TVKit takes the sender address and confirms it with the REST API (`Discovery.find()`).

## REST API (port 8001)

### Device info

`GET http://<tv>:8001/api/v2/`

```json
{
  "device": {
    "name": "Samsung Q65AA 55 TV",
    "modelName": "QE55Q65AAUXXC",
    "model": "21_NIKEL_UHD",
    "PowerState": "on",
    "OS": "Tizen",
    "TokenAuthSupport": "true",
    "wifiMac": "8C:EA:48:63:07:28",
    "networkType": "wireless",
    "developerMode": "0",
    "developerIP": "0.0.0.0",
    "resolution": "3840x2160"
  },
  "version": "2.0.25"
}
```

- `PowerState` is `on` or `standby`. In standby the API still answers; when the TV is fully off nothing does. *Reported:* older firmware omits the field.
- `TokenAuthSupport` decides which remote-control socket to use (below).
- `wifiMac` is the target for Wake-on-LAN.

### App state

`GET http://<tv>:8001/api/v2/applications/<app id>`

```json
{"id":"111299001912","name":"YouTube","running":true,"version":"2.1.513","visible":true}
```

`visible: true` means the app is in front. Not installed: HTTP 404 with `{"code":404,"message":"Not found error.","status":404}`. Both store IDs (`111299001912`) and Tizen package IDs (`9Ur5IzDKqV.TizenYouTube`) work. System apps (the Apps screen, Settings) answer 404.

### Launching an app

`POST http://<tv>:8001/api/v2/applications/<app id>` → `true`. Works without pairing on the tested TV. *Reported:* some newer firmware refuses it; TVKit then falls back to the socket's `ed.apps.launch`.

### No installed-apps list

The socket call `ed.installedApp.get` gets no reply on the tested TV (Samsung removed it around 2020). TVKit finds apps by asking about ~200 known IDs, or uses sdb in Developer Mode.

## Remote-control WebSocket

### Connecting

TVs with `TokenAuthSupport: "true"`:

```
wss://<tv>:8002/api/v2/channels/samsung.remote.control?name=<base64 client name>&token=<token>
```

The TV uses a self-signed certificate; trust it for that host only. *Reported:* older Tizen TVs without token auth use `ws://<tv>:8001/api/v2/channels/samsung.remote.control?name=<base64>` and never prompt.

The first connection without a token shows an **Allow / Deny** prompt on the TV. After Allow:

```json
{"event":"ms.channel.connect","data":{"id":"…","token":"85418879","clients":[…]}}
```

Store the token; later connections pass it and connect without a prompt. The token belongs to the client name (`Q291Y2ggUmVtb3Rl` = "Couch Remote"). Deny sends `ms.channel.unauthorized`.

### Keys

```json
{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_VOLUP","Option":"false","TypeOfRemote":"SendRemoteKey"}}
```

`Cmd` is `Click` for a tap, or `Press` then `Release` to hold a key. While a key is held, the TV repeats it itself: two seconds of `KEY_VOLUP` raised the volume by 30. A quick `Press` + `Release` (80 ms apart) counts as one step.

| Works | Keys |
|---|---|
| Tested | `KEY_UP` `KEY_DOWN` `KEY_LEFT` `KEY_RIGHT` `KEY_ENTER` `KEY_RETURN` `KEY_HOME` `KEY_VOLUP` `KEY_VOLDOWN` `KEY_SOURCE` `KEY_1`–`KEY_5` |
| Used, not individually verified | `KEY_POWER` `KEY_MUTE` `KEY_PLAY` `KEY_PAUSE` `KEY_INFO` `KEY_CHUP` `KEY_CHDOWN` `KEY_0` `KEY_6`–`KEY_9` |
| No effect on the tested TV | `KEY_HDMI1` `KEY_HDMI2` `KEY_APP_LIST` `KEY_CONTENTS` |

`KEY_POWER` toggles power. Turning the tested TV on from standby works with Wake-on-LAN plus `KEY_POWER` (Couch Remote sends both; which one did it wasn't isolated).

### Pointer

```json
{"method":"ms.remote.control","params":{"Cmd":"Move","Position":{"x":120,"y":-40,"Time":"0"},"TypeOfRemote":"ProcessMouseDevice"}}
{"method":"ms.remote.control","params":{"Cmd":"LeftClick","TypeOfRemote":"ProcessMouseDevice"}}
```

`Move` is relative, in roughly pixels of a 1920×1080 screen (250 units ≈ 1/8 of the width); negative values move left and up. Works in the TV's Browser. `RightClick` exists as well.

### Text input

```json
{"method":"ms.remote.control","params":{"Cmd":"<base64 text>","DataOfCmd":"base64","TypeOfRemote":"SendInputString"}}
{"method":"ms.remote.control","params":{"TypeOfRemote":"SendInputEnd"}}
```

`SendInputString` **replaces** the focused field's contents: sending `ab` then `abc` leaves `abc`. Live typing therefore sends the whole string on each keystroke. `SendInputEnd` presses the on-screen keyboard's Done. Each `SendInputString` is answered with `ms.remote.imeDone` events (`"data":"disable"`, then `"enable"`).

### Other socket calls

```json
{"method":"ms.channel.emit","params":{"event":"ed.apps.launch","to":"host","data":{"appId":"…","action_type":"DEEP_LINK","metaTag":""}}}
```

Ignored by the tested TV (use REST). `ed.installedApp.get` and `ed.apps.icon` get no reply.

## UPnP media renderer (port 9197)

The description at `http://<tv>:9197/dmr` lists the services. Volume uses RenderingControl, whose `controlURL` is `/upnp/control/RenderingControl1` on the tested TV:

```
POST /upnp/control/RenderingControl1
SOAPACTION: "urn:schemas-upnp-org:service:RenderingControl:1#GetVolume"

<s:Envelope …><s:Body><u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
  <InstanceID>0</InstanceID><Channel>Master</Channel>
</u:GetVolume></s:Body></s:Envelope>
```

Reply: `<CurrentVolume>9</CurrentVolume>`. `SetVolume` takes `<DesiredVolume>`; `GetMute` / `SetMute` use `<CurrentMute>` / `<DesiredMute>` (0 or 1). No pairing. AVTransport on the same port can play a media URL on the TV (not used by Couch Remote).

## DIAL (port 8080)

`GET http://<tv>:8080/ws/apps/<name>` returns an app's DIAL state (`running` / `stopped`, version) for registered names such as `YouTube`, `Netflix`, `NRK TV`. Launching third-party apps by `POST` returned 404 on the tested TV, so Couch Remote doesn't use DIAL.

## Wake-on-LAN

A magic packet (6 × `0xFF`, then the MAC 16 times) to UDP port 9 on the broadcast address wakes the TV from standby. Use `wifiMac` from the REST API. Requires the TV setting *Power On with Mobile*. *Reported:* a TV on Ethernet needs its Ethernet MAC instead.

## sdb (Developer Mode)

With Developer Mode on (Apps → `1 2 3 4 5` → On, Host PC IP = your Mac, restart the TV), port 26101 runs sdbd: Tizen's fork of Android's adb daemon, with the same wire protocol and no authentication step. TVKit's `SDB` speaks it directly; Tizen Studio isn't needed.

Every message is a 24-byte little-endian header followed by the payload:

| Field | Meaning |
|---|---|
| command | `CNXN`, `OPEN`, `OKAY`, `WRTE`, `CLSE` as 4 ASCII bytes |
| arg0, arg1 | local and remote stream IDs (or version and max payload for `CNXN`) |
| length | payload length |
| checksum | sum of payload bytes |
| magic | command XOR `0xFFFFFFFF` |

1. Send `CNXN(0x02000000, 262144, "host::\0")`. The TV answers `CNXN` with `device::QE55Q65AAUXXC::0`.
2. `OPEN(local, 0, "shell:0 vd_applist\0")` runs a command. Collect `WRTE` payloads, answering each with `OKAY`, until `CLSE`.
3. `OPEN(local, 0, "sync:\0")` then `WRTE("RECV" + length + path)` copies a file: `DATA` records, then `DONE`, or `FAIL` + reason.

The TV has no interactive shell; only `shell:0 <command>`:

| Command | Returns |
|---|---|
| `vd_applist` | installed apps: store ID, Tizen ID, title, version, install date, use count, icon folder |
| `applist` | all Tizen apps (400+), system apps included |
| `execute <tizen id>` | starts any app, e.g. `org.volt.apps` (the Apps screen) |
| `getduid` | the TV's device ID (needed to sign your own apps) |
| `getappinstallpath` | `/opt/usr/home/owner/apps_rw` |

App tiles can be copied from `/opt/share/webappservice/apps_icon/all/<app id>/304x304.png`.

## App IDs

Store ("WAS") IDs look like `320` + year and month registered (YYMM) + a counter: NRK TV is `3202012022410`, registered December 2020. Older apps use other formats (TV 2 Play: `111399002181`). The same app can have different IDs by model year and region (Netflix: `11101200001` on older TVs, `3201907018807` on newer). Each app also has a Tizen package ID (`9Ur5IzDKqV.TizenYouTube`), which the REST API accepts too.
