import AppKit
import SwiftUI

extension View {
    /// Liquid Glass on macOS 26; on earlier systems a translucent fill with a light rim, same shape.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background {
                shape.fill(.background.opacity(0.55))
                    .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            }
        }
    }
}

/// Round glass button used across the popover.
struct GlassCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 30
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.4, weight: .semibold))
            .foregroundStyle(tint ?? .primary)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .glassSurface(in: Circle(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Reports the hosting window and whether it is on screen, so the model only polls while the popover is open.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (NSWindow?, Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow?, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return report() }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        self?.report()
                    })
            }
            report()
        }

        private func report() {
            let window = window
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            DispatchQueue.main.async { self.onChange?(window, visible) }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Lets the user move the window by dragging this area (the remote window's header).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
