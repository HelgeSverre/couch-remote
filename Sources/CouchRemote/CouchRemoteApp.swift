import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct CouchRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(delegate.model)
        } label: {
            Image(systemName: delegate.model.power == .on ? "tv.fill" : "tv")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = RemoteModel()
    @MainActor private var remoteWindow: RemoteWindow?
    private var hotKey: HotKey?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        // ⌃⌥T: the menu bar icon can end up hidden behind the notch when the menu bar is full.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.toggleRemoteWindow() }
        }
        // --light / --dark force an appearance, for README screenshots of both.
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--window") || CommandLine.arguments.contains("--preview-window") {
            showRemoteWindow()
        }
    }

    /// Never leave the Mac cursor frozen if the app quits while the trackpad has it.
    func applicationWillTerminate(_ notification: Notification) {
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Opening the app again (Finder, Spotlight, Raycast) while it runs shows the remote.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRemoteWindow()
        return false
    }

    @MainActor
    func toggleRemoteWindow() {
        if let remoteWindow, remoteWindow.isVisible, remoteWindow.isKeyWindow {
            remoteWindow.orderOut(nil)
        } else {
            showRemoteWindow()
        }
    }

    @MainActor
    func showRemoteWindow() {
        let window = remoteWindow ?? makeRemoteWindow()
        remoteWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        print("remote window \(window.windowNumber)")
        fflush(stdout)
    }

    /// The popover content in a floating window: no title bar buttons, Esc closes, drag the header to move.
    @MainActor
    private func makeRemoteWindow() -> RemoteWindow {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        let hosting = NSHostingView(rootView: PopoverView().environment(model))
        hosting.safeAreaRegions = [] // the hidden title bar shouldn't push content down
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let window = RemoteWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // Not movable by background: that would swallow drags meant for rearranging app tiles.
        // The header carries a WindowDragArea instead.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = effect
        window.setFrameAutosaveName("CouchRemoteWindow")
        if !window.setFrameUsingName("CouchRemoteWindow") { window.center() }
        return window
    }
}

/// Esc hides the remote, like a popover.
final class RemoteWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey (needs no Accessibility permission).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, context, &handlerRef)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4352_4D54), id: 1), // "CRMT"
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
