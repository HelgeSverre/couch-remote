import Foundation

/// An app installed on the TV, as reported by `ed.installedApp.get`.
public struct TVApp: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    /// 2 = web app (launched as DEEP_LINK), 4 = native app (NATIVE_LAUNCH).
    public let appType: Int
    public let iconPath: String?

    public init(id: String, name: String, appType: Int = 2, iconPath: String? = nil) {
        self.id = id
        self.name = name
        self.appType = appType
        self.iconPath = iconPath
    }

    init?(json: [String: Any]) {
        guard let id = json["appId"] as? String, let name = json["name"] as? String else { return nil }
        let type = (json["app_type"] as? Int) ?? Int(json["app_type"] as? String ?? "") ?? 2
        let icon = (json["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(id: id, name: name, appType: type, iconPath: icon)
    }
}

/// Run state of one app, from `GET /api/v2/applications/{id}`.
public struct AppStatus: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let running: Bool
    /// True when the app is in front on screen.
    public let visible: Bool
    public let version: String?
}
