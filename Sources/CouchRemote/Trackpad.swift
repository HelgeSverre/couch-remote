import AppKit
import SwiftUI
import TVKit

/// Drives the TV's pointer from the Mac's mouse or trackpad.
///
/// Click the pad to take control: the Mac cursor is frozen in place and hidden, and every movement is sent
/// to the TV instead. Clicks click on the TV (right-click sends a right click). Esc, or the window losing
/// focus, gives the cursor back. While captured, typing fills the TV's focused text field (see RemoteModel).
struct TrackpadView: View {
    @Environment(RemoteModel.self) private var model
    @State private var captured = false
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        ZStack {
            Color.clear.glassSurface(in: shape)
            VStack(spacing: 6) {
                Image(systemName: captured ? "cursorarrow.motionlines" : "cursorarrow.rays")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(captured ? Color.accentColor : .secondary)
                Text(captured ? "Moving the TV cursor" : "Click to control\nthe TV cursor")
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                Text(captured ? "Click to click · type to fill a field\nEsc to stop" : "Esc gives your cursor back")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if captured && !model.typedText.isEmpty {
                    Text(model.typedText)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
            }
            .padding(12)
            .allowsHitTesting(false)
            PointerCaptureView(captured: $captured, move: model.movePointer, click: model.clickPointer)
        }
        .frame(width: size, height: size)
        .overlay(shape.stroke(Color.accentColor.opacity(captured ? 0.8 : 0), lineWidth: 2))
        .animation(.easeOut(duration: 0.15), value: captured)
        .onChange(of: captured) { _, value in model.setPointerCaptured(value) }
    }
}

/// The AppKit side: cursor capture, raw mouse deltas, and a 60 Hz send loop that batches movement.
private struct PointerCaptureView: NSViewRepresentable {
    @Binding var captured: Bool
    let move: (Int, Int) -> Void
    let click: (PointerButton) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        update(view)
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        update(view)
    }

    private func update(_ view: CaptureView) {
        view.onCaptureChange = { captured = $0 }
        view.move = move
        view.click = click
    }

    final class CaptureView: NSView {
        var onCaptureChange: ((Bool) -> Void)?
        var move: ((Int, Int) -> Void)?
        var click: ((PointerButton) -> Void)?

        /// Mac points → TV pointer units. The TV moves about one unit per pixel of a 1920-wide screen.
        private let speed: CGFloat = 2.2
        private var isCaptured = false
        private var pendingX: CGFloat = 0
        private var pendingY: CGFloat = 0
        private var timer: Timer?
        private var observers: [NSObjectProtocol] = []

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if isCaptured { click?(.left) } else { capture() }
        }

        override func rightMouseDown(with event: NSEvent) {
            if isCaptured { click?(.right) }
        }

        override func mouseMoved(with event: NSEvent) { accumulate(event) }
        override func mouseDragged(with event: NSEvent) { accumulate(event) }
        override func rightMouseDragged(with event: NSEvent) { accumulate(event) }

        override func keyDown(with event: NSEvent) {
            if isCaptured, event.keyCode == 53 { release() } else { super.keyDown(with: event) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { release() }
        }

        private func accumulate(_ event: NSEvent) {
            guard isCaptured else { return }
            pendingX += event.deltaX * speed
            pendingY += event.deltaY * speed
        }

        private func capture() {
            guard let window, !isCaptured else { return }
            isCaptured = true
            window.acceptsMouseMovedEvents = true
            window.makeFirstResponder(self)
            CGAssociateMouseAndMouseCursorPosition(0)  // cursor stays put; deltas keep coming
            NSCursor.hide()
            pendingX = 0
            pendingY = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
            // Give the cursor back whenever the window or app stops being in front.
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.release() }
                },
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.release() }
                },
            ]
            onCaptureChange?(true)
        }

        func release() {
            guard isCaptured else { return }
            isCaptured = false
            timer?.invalidate()
            timer = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            onCaptureChange?(false)
        }

        /// Sends whole units and keeps the remainder, so slow movements still add up.
        private func flush() {
            let dx = pendingX.rounded(.towardZero)
            let dy = pendingY.rounded(.towardZero)
            guard dx != 0 || dy != 0 else { return }
            pendingX -= dx
            pendingY -= dy
            move?(Int(dx), Int(dy))
        }
    }
}
