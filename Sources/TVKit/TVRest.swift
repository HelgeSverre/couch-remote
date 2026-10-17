import Foundation

/// What the TV says about itself at `GET http://<tv>:8001/api/v2/`.
public struct DeviceInfo: Sendable, Equatable {
    public var name: String
    public var modelName: String
    public var model: String?
    /// "on" or "standby".
    public var powerState: String?
    public var wifiMAC: String?
    public var ip: String?
    public var os: String?
    public var developerMode: Bool
    public var developerIP: String?
    public var tokenAuth: Bool

    public var isOn: Bool { (powerState ?? "on") == "on" }
}

extension DeviceInfo: Decodable {
    private struct Envelope: Decodable { let device: DeviceInfoJSON }
    public init(from decoder: Decoder) throws {
        let raw = try Envelope(from: decoder).device
        name = raw.name ?? "Samsung TV"
        modelName = raw.modelName ?? ""
        model = raw.model
        powerState = raw.powerState
        wifiMAC = raw.wifiMac
        ip = raw.ip
        os = raw.os
        developerMode = raw.developerMode == "1"
        developerIP = raw.developerIP
        tokenAuth = raw.tokenAuthSupport == "true"
    }
}

/// `device` object of `GET /api/v2/` as the TV sends it.
private struct DeviceInfoJSON: Decodable {
    let name: String?
    let modelName: String?
    let model: String?
    let powerState: String?
    let wifiMac: String?
    let ip: String?
    let os: String?
    let developerMode: String?
    let developerIP: String?
    let tokenAuthSupport: String?

    /// The TV mixes key styles (`PowerState`, `OS`, `TokenAuthSupport`).
    enum CodingKeys: String, CodingKey {
        case name, modelName, model, wifiMac, ip, developerMode, developerIP
        case powerState = "PowerState"
        case os = "OS"
        case tokenAuthSupport = "TokenAuthSupport"
    }
}

/// The TV's plain HTTP API on port 8001. Needs no pairing.
public enum TVRest {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 4
        return URLSession(configuration: config)
    }()

    static func url(_ host: String, _ path: String) -> URL? {
        URL(string: "http://\(host):8001/api/v2/\(path)")
    }

    public static func deviceInfo(host: String) async throws -> DeviceInfo {
        guard let url = url(host, "") else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    /// `nil` when the app is not installed.
    public static func appStatus(host: String, appID: String) async throws -> AppStatus? {
        guard let url = url(host, "applications/\(appID)") else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(AppStatus.self, from: data)
    }

    /// Launch without the WebSocket. Some firmware refuses this without a token; prefer `RemoteChannel.launch`.
    @discardableResult
    public static func launch(host: String, appID: String) async throws -> Bool {
        guard let url = url(host, "applications/\(appID)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
