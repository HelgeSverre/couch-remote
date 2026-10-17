import Foundation

/// Everything Couch Remote remembers between launches. Shared by the menu bar app and `tvctl`.
public struct TVConfig: Codable, Equatable, Sendable {
    public var host: String?
    public var name: String?
    public var modelName: String?
    /// Wi-Fi MAC of the TV, used for Wake-on-LAN.
    public var wifiMAC: String?
    /// Token the TV issues after you press Allow. Bound to the client name "Couch Remote".
    public var token: String?
    /// App IDs in the order the user arranged them. Apps not listed follow, in catalog order.
    public var appOrder: [String]
    public var hiddenApps: [String]
    /// App IDs added by hand, scanned in addition to the built-in catalog.
    public var customAppIDs: [String]
    /// Result of the last app scan, so the popover has apps to show right away.
    public var knownApps: [TVApp]
    /// "When this app opens, open that one instead", to repurpose the remote's hard-wired app buttons.
    public var remaps: [AppRemap]

    public init() {
        appOrder = []
        hiddenApps = []
        customAppIDs = []
        knownApps = []
        remaps = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        wifiMAC = try c.decodeIfPresent(String.self, forKey: .wifiMAC)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        appOrder = try c.decodeIfPresent([String].self, forKey: .appOrder) ?? []
        hiddenApps = try c.decodeIfPresent([String].self, forKey: .hiddenApps) ?? []
        customAppIDs = try c.decodeIfPresent([String].self, forKey: .customAppIDs) ?? []
        knownApps = try c.decodeIfPresent([TVApp].self, forKey: .knownApps) ?? []
        if let rules = try? c.decodeIfPresent([AppRemap].self, forKey: .remaps) {
            remaps = rules
        } else if let table = try? c.decodeIfPresent([String: String].self, forKey: .remaps) {
            // Early configs stored a plain source → target table.
            remaps = table.sorted { $0.key < $1.key }.map { AppRemap(fromAppID: $0.key, toAppID: $0.value) }
        } else {
            remaps = []
        }
    }

    /// Source app ID → target app ID, for `SamsungTV.runRemaps`. The first rule for a source wins.
    public var remapTable: [String: String] {
        Dictionary(remaps.map { ($0.fromAppID, $0.toAppID) }, uniquingKeysWith: { first, _ in first })
    }
}

/// One remap rule. Both IDs come from the apps scanned on the user's own TV, so they match that TV
/// whatever its model year or region (the same app can have different IDs on different TVs).
public struct AppRemap: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var fromAppID: String
    public var toAppID: String

    public init(id: UUID = UUID(), fromAppID: String, toAppID: String) {
        self.id = id
        self.fromAppID = fromAppID
        self.toAppID = toAppID
    }
}

/// App IDs as seen on a 2021 European model (Tizen 6). The same app can have a different ID on other
/// model years and regions, so prefer IDs from `SamsungTV.installedApps()` for anything user-facing.
public enum KnownApps {
    public static let youtube = "111299001912"
    public static let primeVideo = "3201910019365"
    public static let netflix = "3201907018807"
    public static let samsungTVPlus = "3202006020992"
    public static let nrkTV = "3202012022410"
    public static let tv2Play = "111399002181"
}

public enum ConfigStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CouchRemote", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }

    public static func load() -> TVConfig {
        guard let data = try? Data(contentsOf: fileURL),
            let config = try? JSONDecoder().decode(TVConfig.self, from: data)
        else { return TVConfig() }
        return config
    }

    public static func save(_ config: TVConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}
