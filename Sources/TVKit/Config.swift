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
    /// Source app ID → app to open instead. Repurposes the remote's hard-wired app buttons.
    public var remaps: [String: String]

    public init() {
        appOrder = []
        hiddenApps = []
        customAppIDs = []
        knownApps = []
        remaps = [:]
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
        remaps = try c.decodeIfPresent([String: String].self, forKey: .remaps) ?? [:]
    }
}

/// App buttons printed on the 2021 Samsung remote. Their target can be changed through `TVConfig.remaps`.
public enum RemoteAppButton: String, CaseIterable, Sendable, Identifiable {
    case netflix
    case primeVideo
    /// Only remappable while Samsung TV Plus is enabled on the TV; when it's disabled the button opens nothing.
    case samsungTVPlus

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .netflix: "Netflix button"
        case .primeVideo: "Prime Video button"
        case .samsungTVPlus: "Samsung TV Plus button"
        }
    }

    /// The app the button opens on this TV.
    public var appID: String {
        switch self {
        case .netflix: KnownApps.netflix
        case .primeVideo: KnownApps.primeVideo
        case .samsungTVPlus: KnownApps.samsungTVPlus
        }
    }
}

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
