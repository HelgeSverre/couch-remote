import SwiftUI
import TVKit

/// The menu bar popover: status, apps, remote, volume, then typing and inputs.
struct PopoverView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            HeaderView()
            StatusBanner()
            AppsSection()
            RemoteSection()
            VolumeRow()
            FooterRow()
        }
        .padding(14)
        .frame(width: 340)
        .background(
            WindowVisibilityReader { window, visible in
                model.setPopover(window: window, visible: visible)
            })
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tv")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .glassSurface(in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Menu {
                Button("Refresh Apps") { Task { await model.rescanApps() } }
                Button("Pair Again") { model.pairAgain() }
                Divider()
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Button("Quit Couch Remote") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(GlassCircleButtonStyle(diameter: 30))
            .fixedSize()
            .help("More")

            Button(action: model.togglePower) {
                Image(systemName: "power")
            }
            .buttonStyle(GlassCircleButtonStyle(diameter: 30, tint: .red))
            .help(model.power == .on ? "Turn off" : "Turn on")
        }
        .background(WindowDragArea())
    }

    private var statusText: String {
        switch model.link {
        case .noTV: return "No TV selected"
        case .searching: return "Looking for TVs…"
        case .waitingForApproval: return "Waiting for Allow on the TV"
        case .connecting where model.power == .on: return "Connecting…"
        case .failed: return "Not connected"
        default: break
        }
        switch model.power {
        case .on: return ["On", model.frontAppName].compactMap { $0 }.joined(separator: " · ")
        case .standby: return "Standby"
        case .offline: return "Off or unreachable"
        case .unknown: return "Checking…"
        }
    }

    private var statusColor: Color {
        switch model.link {
        case .waitingForApproval, .connecting, .searching: return .orange
        case .failed: return .red
        default: break
        }
        return model.power == .on ? .green : .secondary.opacity(0.5)
    }
}

// MARK: - Banner

private struct StatusBanner: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        switch model.link {
        case .waitingForApproval:
            banner(
                symbol: "hand.tap", title: "Press Allow on your TV",
                detail: "The TV is asking whether Couch Remote may control it.")
        case .failed(let message):
            banner(
                symbol: "exclamationmark.triangle", title: "Can't control the TV", detail: message,
                action: ("Pair Again", model.pairAgain))
        case .noTV:
            banner(
                symbol: "magnifyingglass", title: "No TV found",
                detail: "Turn the TV on and make sure it's on the same Wi-Fi as this Mac.",
                action: ("Search Again", { Task { await model.discover(autoSelect: true) } }))
        default:
            EmptyView()
        }
    }

    private func banner(symbol: String, title: String, detail: String, action: (String, () -> Void)? = nil) -> some View
    {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1)
                        .controlSize(.small)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Apps

private struct AppsSection: View {
    @Environment(RemoteModel.self) private var model
    /// App being dragged, so tiles can reorder live as it passes over them.
    @State private var dragging: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        let apps = model.apps
        let shown = model.showAllApps ? apps : Array(apps.prefix(10))

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if model.scanningApps {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if apps.count > 10 {
                    Button(model.showAllApps ? "Fewer" : "All \(apps.count)") {
                        withAnimation(.snappy) { model.showAllApps.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 2)

            if model.showAllApps && apps.count > 10 {
                Text("Drag apps to rearrange. The first ten show when the list is collapsed.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }

            if apps.isEmpty {
                Text(model.scanningApps ? "Looking for apps on the TV…" : "Apps show up here once the TV is on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(shown) { app in
                        AppTile(app: app, isDragging: dragging == app.id)
                            .onDrag {
                                dragging = app.id
                                return NSItemProvider(object: app.id as NSString)
                            } preview: {
                                AppIconView(app: app, icon: model.icons[app.id]).frame(width: 46, height: 46)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: ReorderDropDelegate(target: app.id, model: model, dragging: $dragging))
                    }
                }
                // Dropping between tiles still ends the drag.
                .onDrop(of: [.text], delegate: ReorderDropDelegate(target: nil, model: model, dragging: $dragging))
            }
        }
    }
}

/// Moves the dragged app into the hovered tile's place as soon as it enters, so the grid reorders live.
private struct ReorderDropDelegate: DropDelegate {
    let target: String?
    let model: RemoteModel
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging, let target, dragging != target else { return }
        withAnimation(.snappy(duration: 0.2)) { model.move(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct AppTile: View {
    @Environment(RemoteModel.self) private var model
    let app: TVApp
    let isDragging: Bool
    @State private var hovering = false

    var body: some View {
        // A tap gesture rather than a Button: buttons swallow the mouse-down that starts a drag.
        VStack(spacing: 3) {
            AppIconView(app: app, icon: model.icons[app.id])
                .frame(width: 46, height: 46)
                .scaleEffect(hovering && !isDragging ? 1.06 : 1)
            Circle()
                .fill(.primary.opacity(model.runningApps.contains(app.id) ? 0.65 : 0))
                .frame(width: 4, height: 4)
            Text(shortName)
                .font(.system(size: 10))
                .foregroundStyle(model.frontAppID == app.id ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.35 : 1)
        .onTapGesture { model.launch(app) }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help("\(app.name). Drag to rearrange.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.launch(app) }
        .contextMenu {
            Button("Move to Front") { withAnimation(.snappy) { model.moveToFront(app) } }
            Button("Move to End") { withAnimation(.snappy) { model.moveToEnd(app) } }
            Divider()
            Button("Hide") { withAnimation(.snappy) { model.hide(app) } }
        }
    }

    /// "Spotify - Music and Podcasts" → "Spotify", "Pluto TV: Free Movies & Shows" → "Pluto TV".
    private var shortName: String {
        String(app.name.split(whereSeparator: { $0 == ":" || $0 == "-" }).first ?? Substring(app.name))
            .trimmingCharacters(in: .whitespaces)
    }
}

struct AppIconView: View {
    let app: TVApp
    let icon: AppIcon?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let brand = AppCatalog.brand(for: app.name)
        let background = brand.map { Color(hex: $0.color) } ?? fallbackColor

        ZStack {
            shape.fill(background.gradient)
            if let icon {
                Image(nsImage: icon.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: icon.fillsTile ? .fill : .fit)
                    .padding(icon.fillsTile ? 0 : 9)
            } else if let symbol = brand?.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Text(String(app.name.prefix(1)))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
    }

    /// Stable colour per name (String.hashValue changes between launches).
    private var fallbackColor: Color {
        let hash = app.name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.7)
    }
}

// MARK: - Remote

private struct RemoteSection: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack {
            VStack(spacing: 14) {
                HoldCircle(key: .back, diameter: 40) { Image(systemName: "arrow.uturn.backward") }
                    .help("Back (⌫). Hold to leave the app.")
                Button {
                    model.press(.home)
                } label: {
                    Image(systemName: "house")
                }
                .help("Home (H)")
                // Opens the TV's own input list. KEY_HDMI1 and KEY_HDMI2 did nothing on this TV (tested); KEY_SOURCE works.
                Button {
                    model.press(.source)
                } label: {
                    Image(systemName: "cable.connector.horizontal")
                }
                .help("Source: show the TV's input list, then pick with the arrows and OK")
            }
            Spacer()
            if model.pointerMode {
                TrackpadView(size: 168)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                DPad()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            Spacer()
            VStack(spacing: 14) {
                Button(action: model.playPause) { Image(systemName: "playpause.fill") }
                    .help("Play / Pause (space)")
                Button {
                    model.press(.info)
                } label: {
                    Image(systemName: "info")
                }
                .help("Info (I)")
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.pointerMode.toggle() }
                } label: {
                    Image(systemName: model.pointerMode ? "dpad" : "cursorarrow.rays")
                }
                .help(
                    model.pointerMode ? "Back to arrow buttons" : "Trackpad: steer the TV's cursor, e.g. in the browser"
                )
            }
        }
        .buttonStyle(GlassCircleButtonStyle(diameter: 40))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

private struct DPad: View {
    @Environment(RemoteModel.self) private var model
    private let size: CGFloat = 168

    var body: some View {
        ZStack {
            Color.clear.glassSurface(in: Circle())
            arrow(.up, "chevron.up").offset(y: -size / 2 + 26)
            arrow(.down, "chevron.down").offset(y: size / 2 - 26)
            arrow(.left, "chevron.left").offset(x: -size / 2 + 26)
            arrow(.right, "chevron.right").offset(x: size / 2 - 26)
            HoldCircle(key: .enter, diameter: 76) {
                Text("OK").font(.system(size: 13, weight: .semibold))
            }
            .help("OK (↩)")
        }
        .frame(width: size, height: size)
    }

    /// Arrows are held, not clicked: keep the mouse down to keep moving (cursor, scrolling, seeking).
    private func arrow(_ key: RemoteKey, _ symbol: String) -> some View {
        let lit = model.isLit(key)
        return Image(systemName: symbol)
            .font(.system(size: 15, weight: .bold))
            .frame(width: 44, height: 44)
            .foregroundStyle(lit ? Color.accentColor : .secondary)
            .background(Circle().fill(Color.accentColor.opacity(lit ? 0.16 : 0)).padding(4))
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: lit)
            .holdsKey(key)
    }
}

/// A round glass control that holds its key while the mouse is down, like a physical remote button.
private struct HoldCircle<Label: View>: View {
    @Environment(RemoteModel.self) private var model
    let key: RemoteKey
    let diameter: CGFloat
    @ViewBuilder let label: Label

    var body: some View {
        let lit = model.isLit(key)
        label
            .font(.system(size: diameter * 0.4, weight: .semibold))
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .glassSurface(in: Circle(), interactive: true)
            .scaleEffect(lit ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: lit)
            .holdsKey(key)
    }
}

private struct HoldsKey: ViewModifier {
    @Environment(RemoteModel.self) private var model
    let key: RemoteKey
    @State private var down = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        model.hold(key)
                    }
                    .onEnded { _ in
                        down = false
                        model.release(key)
                    }
            )
            .onDisappear {
                if down { model.release(key) }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.press(key) }
    }
}

extension View {
    /// Mouse down sends Press, mouse up sends Release. A quick click is a single press on the TV.
    fileprivate func holdsKey(_ key: RemoteKey) -> some View {
        modifier(HoldsKey(key: key))
    }
}

// MARK: - Volume

private struct VolumeRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.toggleMute) {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(GlassCircleButtonStyle(diameter: 30))
            .help("Mute (M)")

            Slider(value: Binding(get: { model.volume }, set: model.setVolume), in: 0...100)
                .controlSize(.small)
                .help("Volume (+ / −)")

            Text("\(Int(model.volume))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            HStack(spacing: 0) {
                Button {
                    model.press(.channelDown)
                } label: {
                    Image(systemName: "chevron.down").frame(width: 26, height: 28)
                }
                .help("Channel down")
                Text("CH").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Button {
                    model.press(.channelUp)
                } label: {
                    Image(systemName: "chevron.up").frame(width: 26, height: 28)
                }
                .help("Channel up")
            }
            .font(.system(size: 11, weight: .bold))
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .glassSurface(in: Capsule(), interactive: true)
        }
    }
}

// MARK: - Footer

private struct FooterRow: View {
    @Environment(RemoteModel.self) private var model
    @State private var text = ""
    @State private var clearingAfterSubmit = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                TextField(model.tvKeyboardOpen ? "TV keyboard is open, type here" : "Type on TV…", text: $text)
                    .textFieldStyle(.plain)
                    // Live: the TV's field mirrors this one as you type; Return confirms it.
                    .onChange(of: text) { _, value in
                        // Clearing after Return must not send "" and wipe the field just confirmed.
                        if clearingAfterSubmit {
                            clearingAfterSubmit = false
                        } else {
                            model.setTypedText(value)
                        }
                    }
                    .onSubmit {
                        model.submitTypedText()
                        clearingAfterSubmit = true
                        text = ""
                    }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
            .help("Types live into the TV's focused text field. Open a search field on the TV first; Return confirms.")

        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider() }
    }
}
