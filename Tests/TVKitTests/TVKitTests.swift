import XCTest
@testable import TVKit

final class TVKitTests: XCTestCase {
    func testMagicPacket() throws {
        let packet = try XCTUnwrap(WakeOnLAN.packet(mac: "8C:EA:48:63:07:28"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(packet[6..<12]), [0x8C, 0xEA, 0x48, 0x63, 0x07, 0x28])
        XCTAssertEqual(Array(packet.suffix(6)), [0x8C, 0xEA, 0x48, 0x63, 0x07, 0x28])
        XCTAssertNil(WakeOnLAN.packet(mac: "not a mac"))
    }

    func testDeviceInfoDecodesRealResponse() throws {
        let json = """
        {"device":{"PowerState":"on","OS":"Tizen","developerIP":"0.0.0.0","developerMode":"0",
        "model":"21_NIKEL_UHD","modelName":"QE55Q65AAUXXC","name":"Samsung Q65AA 55 TV",
        "wifiMac":"8C:EA:48:63:07:28","TokenAuthSupport":"true"},"name":"Samsung Q65AA 55 TV"}
        """
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.modelName, "QE55Q65AAUXXC")
        XCTAssertEqual(info.wifiMAC, "8C:EA:48:63:07:28")
        XCTAssertTrue(info.isOn)
        XCTAssertFalse(info.developerMode)
        XCTAssertTrue(info.tokenAuth)
    }

    func testRenderingControlParsesVolume() {
        let xml = "<s:Body><u:GetVolumeResponse><CurrentVolume>9</CurrentVolume>\n</u:GetVolumeResponse></s:Body>"
        XCTAssertEqual(RenderingControl.value(of: "CurrentVolume", in: xml), "9")
        XCTAssertNil(RenderingControl.value(of: "CurrentMute", in: xml))
    }

    func testFindsRenderingControlPathInDescription() {
        let xml = """
        <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/upnp/control/ConnectionManager1</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <SCPDURL>/RenderingControl_1.xml</SCPDURL><controlURL>/upnp/control/RenderingControl1</controlURL></service>
        """
        XCTAssertEqual(RenderingControl.renderingControlPath(inDescription: xml), "/upnp/control/RenderingControl1")
        XCTAssertEqual(RenderingControl.renderingControlPath(inDescription: "<root/>"), nil)
    }

    func testInstalledAppParsing() {
        let app = TVApp(json: ["appId": "111299001912", "name": "YouTube", "app_type": 2, "icon": "/opt/icon.png"])
        XCTAssertEqual(app?.id, "111299001912")
        XCTAssertEqual(app?.iconPath, "/opt/icon.png")
        XCTAssertEqual(TVApp(json: ["appId": "1", "name": "X", "app_type": "4", "icon": ""])?.appType, 4)
        XCTAssertNil(TVApp(json: ["appId": "1", "name": "X", "icon": ""])?.iconPath)
        XCTAssertNil(TVApp(json: ["name": "No id"]))
    }

    func testChannelURLCarriesNameAndToken() throws {
        let url = try XCTUnwrap(RemoteChannel.url(host: "192.168.10.57", clientName: "Couch Remote", token: "123"))
        XCTAssertEqual(url.absoluteString,
                       "wss://192.168.10.57:8002/api/v2/channels/samsung.remote.control?name=Q291Y2ggUmVtb3Rl&token=123")
        // Older TVs without token auth: plain ws on 8001, no token.
        let legacy = try XCTUnwrap(RemoteChannel.url(host: "192.168.10.57", clientName: "Couch Remote", token: "123", secure: false))
        XCTAssertEqual(legacy.absoluteString,
                       "ws://192.168.10.57:8001/api/v2/channels/samsung.remote.control?name=Q291Y2ggUmVtb3Rl")
    }

    func testConfigDecodesOlderFiles() throws {
        let config = try JSONDecoder().decode(TVConfig.self, from: Data(#"{"host":"192.168.10.57"}"#.utf8))
        XCTAssertEqual(config.host, "192.168.10.57")
        XCTAssertEqual(config.appOrder, [])
        XCTAssertEqual(config.remaps, [])
    }

    func testConfigMigratesRemapTable() throws {
        let json = #"{"remaps":{"3201910019365":"111299001912"}}"#
        let config = try JSONDecoder().decode(TVConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.remaps.count, 1)
        XCTAssertEqual(config.remapTable, ["3201910019365": "111299001912"])
        // Round trip keeps the new format.
        let again = try JSONDecoder().decode(TVConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.remaps, config.remaps)
    }

    func testCatalogRanksKnownAppsFirstAndDedupesIDs() {
        let youtube = TVApp(id: KnownApps.youtube, name: "YouTube")
        let nrk = TVApp(id: "x", name: "NRK TV")
        let unknown = TVApp(id: "y", name: "Some Obscure App")
        XCTAssertLessThan(AppCatalog.rank(of: youtube), AppCatalog.rank(of: nrk))
        XCTAssertLessThan(AppCatalog.rank(of: nrk), AppCatalog.rank(of: unknown))
        XCTAssertEqual(AppCatalog.brand(for: "HBO Max")?.icon, "hbo-max")
        XCTAssertEqual(AppCatalog.brand(for: "YouTube Kids")?.icon, "youtube-kids")
        XCTAssertEqual(AppCatalog.brand(for: "TV 2 Play")?.icon, "tv-2-play")
        XCTAssertEqual(Set(AppCatalog.candidateIDs).count, AppCatalog.candidateIDs.count, "duplicate catalog IDs")
    }

    func testEveryBrandIconIsBundled() throws {
        let directory = try XCTUnwrap(AppIcons.directory, "TVKit resource bundle not found")
        for slug in Set(AppCatalog.brands.compactMap(\.icon)) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(slug).png").path), slug)
        }
        XCTAssertNotNil(AppIcons.png(forAppNamed: "NRK TV"))
    }

    func testParsesVdApplist() {
        let output = """
        get app list...
        apps count: 2
        ---------------------------------------------------------------------------------------------
        --------------app_id                                =3201907018807-------------
        --------------app_title                             =Netflix-------------
        --------------app_version                           =70.23.15090-------------
        --------------install_date                          =2021-07-15 19:57:31-------------
        --------------app_tizen_id                          =org.tizen.netflix-app-------------
        --------------use_count                             =2712-------------
        --------------app_panel_icon_path                   =/opt/share/webappservice/apps_icon/all/3201907018807/-------------
        ---------------------------------------------------------------------------------------------
        --------------app_id                                =111399002181-------------
        --------------app_title                             =TV 2 Play-------------
        --------------use_count                             =241-------------
        """
        let apps = InstalledApp.parse(output)
        XCTAssertEqual(apps.map(\.id), ["3201907018807", "111399002181"])
        XCTAssertEqual(apps[0].tizenID, "org.tizen.netflix-app")
        XCTAssertEqual(apps[0].installDate, "2021-07-15 19:57:31")
        XCTAssertEqual(apps[1].useCount, 241)
        XCTAssertEqual(apps[1].title, "TV 2 Play")
    }
}
