import Foundation

/// Finds installed apps by asking the TV about known app IDs one by one.
///
/// Samsung removed the installed-apps call (`ed.installedApp.get`) from 2020+ firmware: the TV accepts the
/// request and never answers. `GET /api/v2/applications/{id}` still answers for any installed app, so a scan
/// over community-collected IDs (homebridge-samsung-tizen, rs.ltd) finds what is there. Names come from the
/// TV, so a stale catalog entry can't mislabel an app.
public enum AppCatalog {
    /// Numeric IDs first: when an app answers under several IDs, the first one wins.
    public static let candidateIDs: [String] = [
        // Popular streaming
        "3202012022410", "111399002181", "3202009021664", "3202006021088", "111299001912", "3201907018807", "11101200001", "3201910019365", "3201512006785",
        "3201901017640", "3202009021709", "3202204027038", "3202301029760", "3201601007230",
        "111299002125", "3201810017074", "11111300404", "3202208028071", "3201803015944",
        "3202006021105", "3201807016597", "3201908019041", "3201606009684", "3201512006963",
        "3202203026841", "3202203026799", "3201808016802", "3201511006428", "3202008021577",
        "3201611010983", "3201707014489", "3201806016390", "3201805016367", "3201608010191",
        "3201710014874", "3202302030097", "3202102023078", "3201702011851", "3201601007625",
        "3201710014981", "3202110025305", "3202006020991", "3201504001965", "121299000101",
        "3201605009379", "3201606009910", "3201901017732", "3201703012079", "3201708014618",
        // Samsung and system apps
        "3202006020992", "3202010022079", "3201907018784", "3201710015037", "3201910019378", "3201710015016",
        "3202311033054", "3201909019211", "3202004020626", "3202004020674", "3202008021439",
        "20212100002", "20212100003", "20202100002", "3202303030290", "3201710015067", "3202009021877", "3201807016658",
        // Regional and less common
        "3201704012147", "3201905018499", "3201606009882", "3201803015934", "3201607010031",
        "3201806016508", "3201812017479", "111299002148", "3201811017337", "3201808016819",
        "3201611011005", "3201412000679", "3202011022316", "3201910019420", "3201601007670",
        "3201602007865", "3202003020365", "3202007021336", "3202010022098", "3201705012375",
        "3201412000690", "3201909019175", "3201905018484", "3201803015869", "3201711015155",
        "3201505002690", "3201704012161", "3201812017516", "3201506003488", "111299001664",
        "3201506003486", "3202205027432", "3201907018786", "3201611011040", "3201801015541",
        "3201902017822", "3201812017511", "3201901017758", "111399002250", "3201804016109",
        "3201608010385", "3201702011871", "3201712015454", "11091000000", "141299000100",
        "3201910019449", "3202103023232", "3201908019022", "3201601007250", "3201806016381",
        "3201706012478", "3201810017070", "3201812017585", "3202009021808", "3202006020934",
        "121299000089", "3201910019513", "3201502001386", "3201910019354", "3201901017768",
        "3201907018746", "3201612011418", "3201611011210", "3201606009840", "3202012022421",
        "3202011022131", "3201603008746", "3201706014250", "3201703012029", "3201607009918",
        "3202103023185", "3201711015226", "111399002034", "3201602007756", "3201704012212",
        "3201906018642", "3201908018988", "3201510005981", "3201506002963", "3201903018045",
        "3201902017887", "111399002220", "3201704012124", "3202102022877", "3201606009798",
        "3201806016432", "3201807016555", "111012010001", "3201705012365", "3201809016952",
        "3201707014448", "3201803015836", "3201810017104", "3201911019625", "111199000385",
        // Package IDs, for apps only known by those
        "org.tizen.browser", "NRi6kdBYJ0.AirPlayWebApp", "vYmY3ACVaa.emby", "Ahw07WXIjx.Dailymotion",
        "JtPoChZbf4.Vimeo", "QBA3qXl8rv.Kick", "ABor2M9vjb.acc", "4bjaTLNMia.curzon",
    ]

    /// Apps that are installed on every Samsung TV and rarely opened on purpose.
    public static let quietByDefault: Set<String> = ["Samsung Promotion", "Security Center", "Apple AirPlay", "Samsung TV Plus"]

    /// Asks the TV about every candidate (plus `extraIDs`) and returns the installed apps, one per name.
    public static func scan(host: String, extraIDs: [String] = []) async -> [TVApp] {
        let ids = extraIDs + candidateIDs.filter { !extraIDs.contains($0) }
        var statuses = [String: AppStatus]()
        for batch in stride(from: 0, to: ids.count, by: 16).map({ Array(ids[$0..<min($0 + 16, ids.count)]) }) {
            await withTaskGroup(of: (String, AppStatus?).self) { group in
                for id in batch {
                    group.addTask { (id, try? await TVRest.appStatus(host: host, appID: id)) }
                }
                for await (id, status) in group { statuses[id] = status }
            }
        }
        var seen = Set<String>()
        return ids.compactMap { id in
            guard let status = statuses[id], seen.insert(status.name).inserted else { return nil }
            return TVApp(id: id, name: status.name)
        }
    }

    /// Display order: well-known apps in catalog order, everything else alphabetically after them.
    public static func rank(of app: TVApp) -> Int {
        brandIndex(for: app.name) ?? (brands.count + (candidateIDs.firstIndex(of: app.id) ?? candidateIDs.count))
    }

    public static func brand(for name: String) -> AppBrand? {
        brandIndex(for: name).map { brands[$0] }
    }

    static func brandIndex(for name: String) -> Int? {
        let lower = name.lowercased()
        return brands.firstIndex { brand in brand.matches.contains { lower.hasPrefix($0) } }
    }

    static let brands: [AppBrand] = [
        AppBrand(["youtube kids"], icon: "youtube-kids", color: 0xFFFFFF),
        AppBrand(["youtube tv"], icon: "youtube", color: 0xFFFFFF),
        AppBrand(["youtube"], icon: "youtube", color: 0xFFFFFF),
        AppBrand(["netflix"], icon: "netflix", color: 0x000000),
        AppBrand(["prime video"], icon: "prime-video", color: 0x1A98FF),
        AppBrand(["disney+"], icon: "disney-plus", color: 0x0E1B4D),
        AppBrand(["hbo max", "max"], icon: "hbo-max", color: 0x000000),
        AppBrand(["hbo"], icon: "hbo", color: 0x000000),
        AppBrand(["nrk"], icon: "nrk-tv", color: 0x1B3A8A),
        AppBrand(["tv 2"], icon: "tv-2-play", color: 0x5A1FFF),
        AppBrand(["rikstv"], icon: "rikstv", color: 0xC8102E),
        AppBrand(["strim"], icon: "strim", color: 0xF7E98E),
        AppBrand(["viaplay"], icon: "viaplay", color: 0x1C1336),
        AppBrand(["skyshowtime"], icon: "skyshowtime", color: 0x5B2B8C),
        AppBrand(["discovery+"], icon: "discovery-plus", color: 0x0B2DE3),
        AppBrand(["allente"], icon: "allente", color: 0xF26B21),
        AppBrand(["telia play"], icon: "telia-play", color: 0x1F0A2E),
        AppBrand(["apple tv"], icon: "apple-tv", color: 0x000000),
        AppBrand(["apple music"], icon: "apple-music", color: 0xFA2D48),
        AppBrand(["spotify"], icon: "spotify", color: 0x121212),
        AppBrand(["plex"], icon: "plex", color: 0x1F1F1F),
        AppBrand(["twitch"], icon: "twitch", color: 0x9146FF),
        AppBrand(["xbox"], icon: "xbox", color: 0x107C10),
        AppBrand(["pluto tv"], icon: "pluto-tv", color: 0xFFF200),
        AppBrand(["rakuten"], icon: "rakuten-tv", color: 0xBF0000),
        AppBrand(["tiktok"], icon: "tiktok", color: 0x000000),
        AppBrand(["dazn"], icon: "dazn", color: 0x0C161C),
        AppBrand(["tidal"], icon: "tidal", color: 0x000000),
        AppBrand(["deezer"], icon: "deezer", color: 0x000000),
        AppBrand(["crunchyroll"], icon: "crunchyroll", color: 0xF47521),
        AppBrand(["google meet"], icon: "google-meet", color: 0xFFFFFF),
        AppBrand(["nebula"], icon: "nebula", color: 0xFFFFFF),
        AppBrand(["browser", "internet"], icon: "browser", color: 0x2F6FDF),
        AppBrand(["gallery"], icon: "gallery", color: 0xE0457B),
        AppBrand(["e-manual"], icon: "e-manual", color: 0xF08A4B),
        AppBrand(["smartthings"], symbol: "house", color: 0x15BEF0),
        AppBrand(["samsung health"], symbol: "heart.fill", color: 0x00A3A0),
        AppBrand(["samsung tv plus"], symbol: "play.tv", color: 0x1428A0),
        AppBrand(["apple airplay"], symbol: "airplayvideo", color: 0x3A3A3C),
        AppBrand(["security center"], icon: "security-center", color: 0x2A5BD7),
        AppBrand(["samsung promotion"], icon: "samsung-promotion", color: 0x4BA3D9),
    ]
}

/// How to draw an app's tile: a bundled icon (see `scripts/fetch-icons.sh`) or an SF Symbol, on a background colour.
public struct AppBrand: Sendable {
    public let matches: [String]
    /// File name (without `.png`) in `Resources/AppIcons`.
    public let icon: String?
    public let symbol: String?
    /// 0xRRGGBB
    public let color: UInt32

    init(_ matches: [String], icon: String? = nil, symbol: String? = nil, color: UInt32) {
        self.matches = matches
        self.icon = icon
        self.symbol = symbol
        self.color = color
    }
}

/// App icons for known apps, bundled with TVKit. The TV itself no longer hands them out.
public enum AppIcons {
    /// `Resources/AppIcons` inside TVKit's resource bundle, wherever the host put it: next to the
    /// executable (`swift run`) or in an app's `Contents/Resources` (see `scripts/build-app.sh`).
    public static let directory: URL? = {
        // Not `Bundle.module`: it crashes when the bundle isn't where SwiftPM expects, and inside a
        // signed .app it can't sit where SwiftPM expects.
        let bases = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ].compactMap { $0 } + Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        for base in bases {
            let items = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for item in items where item.lastPathComponent.hasSuffix("_TVKit.bundle") {
                if let url = Bundle(url: item)?.url(forResource: "AppIcons", withExtension: nil) { return url }
            }
        }
        return nil
    }()

    /// The bundled PNG for an app name, if TVKit knows the app.
    public static func png(forAppNamed name: String) -> Data? {
        guard let slug = AppCatalog.brand(for: name)?.icon,
              let url = directory?.appendingPathComponent("\(slug).png")
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
