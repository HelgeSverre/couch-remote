import AppKit
import Observation
import TVKit

/// UI state for the popover and settings. TV access goes through TVKit's `SamsungTV`.
@MainActor @Observable
final class RemoteModel {
    enum Link: Equatable {
        case noTV
        case searching
        case connecting
        case waitingForApproval
        case connected
        case offline
        case failed(String)
    }

    enum Power { case unknown, on, standby, offline }

    private(set) var config: TVConfig
    private(set) var link: Link = .noTV
    private(set) var power: Power = .unknown
    private(set) var device: DeviceInfo?
    private(set) var icons: [String: AppIcon] = [:]
    private(set) var runningApps: Set<String> = []
    private(set) var frontAppID: String?
    private(set) var volume: Double = 0
    private(set) var muted = false
    private(set) var tvKeyboardOpen = false
    private(set) var flashedKey: RemoteKey?
    /// Keys currently held down from the UI or keyboard.
    private(set) var heldKeys: Set<RemoteKey> = []
    private(set) var scanningApps = false
    private(set) var discovered: [DiscoveredTV] = []
    var showAllApps = false
    /// The D-pad is replaced by a trackpad that drives the TV's pointer.
    var pointerMode = false
    /// The trackpad holds the Mac cursor; typed characters go to the TV's focused text field.
    private(set) var pointerCaptured = false
    /// What has been typed into the TV's field since the last click or confirm (the TV field shows exactly this).
    private(set) var typedText = ""

    @ObservationIgnored private var tv: SamsungTV?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var remapTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var lastVolumeEdit = Date.distantPast
    @ObservationIgnored private var flashCount = 0
    @ObservationIgnored private var keyMonitor: Any?
    /// Window number → on screen, for every window showing the remote (menu bar popover, floating window).
    @ObservationIgnored private var remoteWindows: [Int: Bool] = [:]
    @ObservationIgnored private var popoverVisible = false
    @ObservationIgnored private var playing = true
    /// Mac key code → TV key, for keyboard keys currently held.
    @ObservationIgnored private var heldKeyCodes: [UInt16: RemoteKey] = [:]
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    init() {
        config = ConfigStore.load()
        if let host = config.host { makeTV(host: host) }
    }

    // MARK: Derived state

    /// Visible apps in the user's order, then the rest in catalog order.
    var apps: [TVApp] {
        orderedApps.filter { !config.hiddenApps.contains($0.id) }
    }

    private var orderedApps: [TVApp] {
        let byID = Dictionary(config.knownApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let arranged = config.appOrder.compactMap { byID[$0] }
        let rest = config.knownApps
            .filter { !config.appOrder.contains($0.id) }
            .sorted { (AppCatalog.rank(of: $0), $0.name) < (AppCatalog.rank(of: $1), $1.name) }
        return arranged + rest
    }

    var hiddenApps: [TVApp] { config.knownApps.filter { config.hiddenApps.contains($0.id) } }

    var displayName: String { device?.name ?? config.name ?? "Samsung TV" }

    var frontAppName: String? {
        frontAppID.flatMap { id in config.knownApps.first { $0.id == id }?.name }
    }

    func name(ofApp id: String) -> String {
        config.knownApps.first { $0.id == id }?.name ?? id
    }

    // MARK: Lifecycle

    func start() {
        updateRemaps()
        Task {
            if config.host == nil { await discover(autoSelect: true) }
            guard config.host != nil else { return }
            await refreshStatus()
            await connect(allowPairing: true)
            if config.knownApps.isEmpty { await rescanApps() }
            await loadIcons()
        }
    }

    func setPopover(window: NSWindow?, visible: Bool) {
        guard let window else { return }
        remoteWindows[window.windowNumber] = visible
        // A key held while the window hides or loses focus would never see its mouse-up or key-up.
        if !visible || !window.isKeyWindow { releaseAllKeys() }
        let anyVisible = remoteWindows.values.contains(true)
        guard anyVisible != popoverVisible else { return }
        popoverVisible = anyVisible
        if anyVisible {
            installKeyMonitor()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refreshStatus()
                    await self.connect(allowPairing: false)
                    await self.refreshRunningApps()
                    try? await Task.sleep(for: .seconds(2.5))
                }
            }
        } else {
            removeKeyMonitor()
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: Connection

    private func makeTV(host: String) {
        eventsTask?.cancel()
        if let old = tv { Task { await old.disconnect() } }
        let tv = SamsungTV(host: host, token: config.token)
        self.tv = tv
        eventsTask = Task { [weak self] in
            for await event in tv.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: SamsungTV.Event) {
        switch event {
        case .awaitingApproval: link = .waitingForApproval
        case .connected: link = .connected
        case .disconnected: link = power == .on ? .connecting : .offline
        case .paired(let token):
            config.token = token
            persist()
        case .keyboardShown: tvKeyboardOpen = true
        case .keyboardHidden: tvKeyboardOpen = false
        case .commandFailed(let message):
            if link == .connected { link = .failed(message) }
        }
    }

    func connect(allowPairing: Bool) async {
        guard let tv, await !tv.isConnected else { return }
        guard power != .offline else {
            link = .offline
            return
        }
        if link != .waitingForApproval { link = .connecting }
        do {
            try await tv.connect(allowPairing: allowPairing)
        } catch SamsungTVError.notPaired {
            // Needs the Allow prompt, which only an explicit pairing may trigger.
            link = .failed("Couch Remote isn't paired with this TV. Choose Pair Again, then press Allow on the TV.")
        } catch RemoteChannelError.unauthorized {
            link = .failed("The TV declined. Choose Pair Again, then press Allow on the TV.")
        } catch {
            link =
                config.token == nil
                ? .failed("The TV didn't answer the pairing request. Choose Pair Again, then press Allow on the TV.")
                : .failed(error.localizedDescription)
        }
    }

    func pairAgain() {
        guard let tv else { return }
        Task {
            await tv.unpair()
            await connect(allowPairing: true)
        }
    }

    // MARK: Status

    func refreshStatus() async {
        guard let tv else { return }
        do {
            let info = try await tv.info()
            device = info
            power = info.isOn ? .on : .standby
            if config.wifiMAC != info.wifiMAC || config.name != info.name {
                config.wifiMAC = info.wifiMAC ?? config.wifiMAC
                config.name = info.name
                config.modelName = info.modelName
                persist()
            }
        } catch {
            power = .offline
            if link != .waitingForApproval { link = .offline }
            return
        }
        if link == .offline { link = .connecting }
        guard power == .on else { return }
        if Date().timeIntervalSince(lastVolumeEdit) > 2, let value = try? await tv.volume() {
            volume = Double(value)
        }
        if let value = try? await tv.isMuted() { muted = value }
    }

    func refreshRunningApps() async {
        guard let tv, power == .on else {
            runningApps = []
            frontAppID = nil
            return
        }
        let statuses = await tv.statuses(ofApps: config.knownApps.map(\.id))
        runningApps = Set(statuses.filter(\.running).map(\.id))
        frontAppID = statuses.first(where: \.visible)?.id
    }

    // MARK: Apps

    func rescanApps() async {
        guard let tv, !scanningApps else { return }
        scanningApps = true
        defer { scanningApps = false }
        let found = await tv.installedApps(extraIDs: config.customAppIDs)
        guard !found.isEmpty else { return }
        let firstScan = config.knownApps.isEmpty
        config.knownApps = found
        if firstScan {
            config.hiddenApps = found.filter { AppCatalog.quietByDefault.contains($0.name) }.map(\.id)
        }
        persist()
        await loadIcons()
    }

    func addApp(id: String) async -> String? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tv, !id.isEmpty else { return "Enter an app ID." }
        guard let status = try? await tv.status(ofApp: id) else {
            return "The TV doesn't have an app with ID \(id)."
        }
        if !config.customAppIDs.contains(id) { config.customAppIDs.append(id) }
        if !config.knownApps.contains(where: { $0.id == id }) {
            config.knownApps.append(TVApp(id: id, name: status.name))
        }
        config.hiddenApps.removeAll { $0 == id }
        persist()
        await loadIcons()
        return nil
    }

    private func loadIcons() async {
        for app in config.knownApps where icons[app.id] == nil {
            guard let png = AppIcons.png(forAppNamed: app.name), let icon = AppIcon(png: png) else { continue }
            icons[app.id] = icon
        }
    }

    func launch(_ app: TVApp) {
        launch(appID: app.id)
    }

    func launch(appID: String) {
        guard let tv else { return }
        frontAppID = appID
        runningApps.insert(appID)
        Task { try? await tv.launch(appID: appID) }
    }

    /// Moves `appID` to sit where `targetID` is now. Saves the full order so it survives rescans.
    func move(_ appID: String, to targetID: String) {
        guard appID != targetID else { return }
        var order = orderedApps.map(\.id)
        guard let from = order.firstIndex(of: appID), let to = order.firstIndex(of: targetID) else { return }
        order.remove(at: from)
        order.insert(appID, at: to)
        config.appOrder = order
        persist()
    }

    func moveToFront(_ app: TVApp) {
        config.appOrder = [app.id] + orderedApps.map(\.id).filter { $0 != app.id }
        persist()
    }

    func moveToEnd(_ app: TVApp) {
        config.appOrder = orderedApps.map(\.id).filter { $0 != app.id } + [app.id]
        persist()
    }

    func resetOrder() {
        config.appOrder = []
        persist()
    }

    func hide(_ app: TVApp) {
        config.hiddenApps.append(app.id)
        persist()
    }

    func unhide(_ app: TVApp) {
        config.hiddenApps.removeAll { $0 == app.id }
        persist()
    }

    // MARK: Remote

    func press(_ key: RemoteKey) {
        flash(key)
        tv?.press(key)
    }

    /// Starts holding a key; the TV repeats it until `release(_:)`.
    func hold(_ key: RemoteKey) {
        guard heldKeys.insert(key).inserted else { return }
        tv?.hold(key)
    }

    func release(_ key: RemoteKey) {
        guard heldKeys.remove(key) != nil else { return }
        tv?.release(key)
    }

    func releaseAllKeys() {
        guard !heldKeys.isEmpty else { return }
        heldKeys = []
        heldKeyCodes = [:]
        tv?.releaseAll()
    }

    func movePointer(dx: Int, dy: Int) {
        tv?.movePointer(dx: dx, dy: dy)
    }

    func clickPointer(_ button: PointerButton) {
        typedText = ""  // a click may focus a different field
        tv?.click(button)
    }

    func setPointerCaptured(_ captured: Bool) {
        pointerCaptured = captured
        typedText = ""
    }

    /// Live typing: the TV field always shows `text`.
    func setTypedText(_ text: String) {
        typedText = text
        tv?.setText(text)
    }

    func submitTypedText() {
        typedText = ""
        tv?.submitText()
    }

    func isLit(_ key: RemoteKey) -> Bool {
        flashedKey == key || heldKeys.contains(key)
    }

    /// Samsung has separate play and pause keys; alternate between them.
    func playPause() {
        press(playing ? .pause : .play)
        playing.toggle()
    }

    func togglePower() {
        switch power {
        case .on:
            press(.power)
            power = .standby
        case .standby:
            wake()
            Task {
                if await tv?.isConnected == true { press(.power) }
            }
        case .offline, .unknown:
            wake()
        }
    }

    private func wake() {
        guard let mac = config.wifiMAC else { return }
        try? SamsungTV.wake(mac: mac, near: config.host)
        Task {
            try? await Task.sleep(for: .seconds(4))
            await refreshStatus()
            await connect(allowPairing: false)
        }
    }

    func setVolume(_ value: Double) {
        guard let tv else { return }
        volume = value.rounded()
        lastVolumeEdit = Date()
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            try? await tv.setVolume(Int(value.rounded()))
        }
    }

    func stepVolume(_ delta: Int) {
        press(delta > 0 ? .volumeUp : .volumeDown)
        volume = min(100, max(0, volume + Double(delta)))
        lastVolumeEdit = Date()
    }

    func toggleMute() {
        press(.mute)
        muted.toggle()
    }

    private func flash(_ key: RemoteKey) {
        flashedKey = key
        flashCount += 1
        let count = flashCount
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            if flashCount == count { flashedKey = nil }
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAllKeys() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors run on the main thread.
            let key = KeyPress(event)
            let handled = MainActor.assumeIsolated { self?.handleKey(key) ?? false }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
        releaseAllKeys()
    }

    /// Mac keys that act like held remote buttons: down sends Press, up sends Release.
    private static let holdableKeys: [UInt16: RemoteKey] = [
        123: .left, 124: .right, 125: .down, 126: .up, 36: .enter, 76: .enter, 51: .back,
    ]

    /// Arrow keys steer, Return is OK, Delete is Back. Typing in a text field is left alone.
    private func handleKey(_ event: KeyPress) -> Bool {
        guard remoteWindows[event.windowNumber] == true,
            let window = NSApp.window(withWindowNumber: event.windowNumber),
            !(window.firstResponder is NSText),
            event.modifierFlags.isDisjoint(with: [.command, .control])
        else { return false }

        if pointerCaptured, event.isDown, handleTyping(event) { return true }
        guard event.modifierFlags.isDisjoint(with: .option) else { return false }

        if let key = Self.holdableKeys[event.keyCode] {
            if !event.isDown {
                heldKeyCodes[event.keyCode] = nil
                release(key)
            } else if !event.isRepeat {
                heldKeyCodes[event.keyCode] = key
                hold(key)
            }
            return true  // swallow auto-repeat: the TV repeats on its own while the key is held
        }
        guard event.isDown else { return false }

        switch event.keyCode {
        case 49: playPause()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "h": press(.home)
            case "i": press(.info)
            case "m": toggleMute()
            case "+", "=": stepVolume(1)
            case "-": stepVolume(-1)
            case let digit where digit.count == 1 && digit.first!.isWholeNumber:
                press(.digit(Int(digit)!))
            default: return false
            }
        }
        return true
    }

    /// While the trackpad holds the cursor, typing goes to the TV's focused text field.
    /// Returns false for keys that should keep their remote meaning (arrows, Return/Delete with nothing typed).
    private func handleTyping(_ event: KeyPress) -> Bool {
        switch event.keyCode {
        case 36, 76:
            guard !typedText.isEmpty else { return false }
            submitTypedText()
            return true
        case 51:
            guard !typedText.isEmpty else { return false }
            setTypedText(String(typedText.dropLast()))
            return true
        case 53, 123, 124, 125, 126:
            return false
        default:
            guard let characters = event.characters, !characters.isEmpty,
                characters.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
                })
            else { return false }
            setTypedText(typedText + characters)
            return true
        }
    }

    // MARK: Settings

    func discover(autoSelect: Bool) async {
        let previous = link
        link = .searching
        discovered = await Discovery.find()
        if autoSelect, config.host == nil, let first = discovered.first {
            useTV(host: first.host)
        } else {
            link = config.host == nil ? .noTV : previous
        }
    }

    func useTV(host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        if host != config.host {
            config.token = nil
            config.knownApps = []
            device = nil
        }
        config.host = host
        persist()
        makeTV(host: host)
        updateRemaps()
        Task {
            await refreshStatus()
            await connect(allowPairing: true)
            await rescanApps()
        }
    }

    func setWifiMAC(_ mac: String) {
        config.wifiMAC = mac.isEmpty ? nil : mac
        persist()
    }

    /// Adds a rule, starting from Prime Video → YouTube when both are installed, else the first two apps.
    func addRemap() {
        let apps = config.knownApps
        guard apps.count >= 2 else { return }
        let from = apps.first { $0.name == "Prime Video" } ?? apps[0]
        let to = apps.first { $0.name == "YouTube" && $0.id != from.id } ?? apps.first { $0.id != from.id }!
        config.remaps.append(AppRemap(fromAppID: from.id, toAppID: to.id))
        persist()
        updateRemaps()
    }

    func updateRemap(_ id: UUID, from: String? = nil, to: String? = nil) {
        guard let index = config.remaps.firstIndex(where: { $0.id == id }) else { return }
        if let from { config.remaps[index].fromAppID = from }
        if let to { config.remaps[index].toAppID = to }
        persist()
        updateRemaps()
    }

    func removeRemap(_ id: UUID) {
        config.remaps.removeAll { $0.id == id }
        persist()
        updateRemaps()
    }

    private func updateRemaps() {
        remapTask?.cancel()
        guard let tv, !config.remaps.isEmpty else { return }
        let remaps = config.remapTable
        remapTask = Task { await tv.runRemaps(remaps) }
    }

    private func persist() {
        try? ConfigStore.save(config)
    }
}

/// The parts of a key-down event the remote cares about, copied out so they can cross to the main actor.
struct KeyPress: Sendable {
    let keyCode: UInt16
    let characters: String?
    let charactersIgnoringModifiers: String?
    let modifierFlags: NSEvent.ModifierFlags
    let windowNumber: Int
    let isDown: Bool
    let isRepeat: Bool

    init(_ event: NSEvent) {
        isDown = event.type == .keyDown
        isRepeat = event.type == .keyDown && event.isARepeat
        keyCode = event.keyCode
        characters = event.characters
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        modifierFlags = event.modifierFlags
        windowNumber = event.windowNumber
    }
}

/// A fetched app icon. Opaque square icons fill the tile; icons with transparent corners sit on the brand colour.
struct AppIcon {
    let image: NSImage
    let fillsTile: Bool

    init?(png: Data) {
        guard let image = NSImage(data: png), let bitmap = NSBitmapImageRep(data: png) else { return nil }
        self.image = image
        let corners = [
            (1, 1), (bitmap.pixelsWide - 2, 1), (1, bitmap.pixelsHigh - 2),
            (bitmap.pixelsWide - 2, bitmap.pixelsHigh - 2),
        ]
        fillsTile = corners.allSatisfy { (bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.95 }
    }
}
