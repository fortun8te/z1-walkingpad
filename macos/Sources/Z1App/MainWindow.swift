import AppKit
import SwiftUI

/// The one window: small, fixed, not resizable, with a transparent title bar
/// the content runs under.
///
/// Closing it only hides it; the app keeps running (and keeps recording a
/// walk) until Quit. While it is closed the SwiftUI tree is gone, so nothing
/// observes the model and nothing renders. Reopening builds a fresh tree,
/// which is also why every reopen lands the almanac on today.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private let model: TreadmillViewModel
    private let navigation: Navigation
    private(set) var window: NSWindow?

    init(model: TreadmillViewModel, navigation: Navigation) {
        self.model = model
        self.navigation = navigation
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        if window.contentView is NSHostingView<RootView> == false {
            install(in: window)
        }
        // The harness shows the window without taking focus, so typing in
        // another app never lands in it.
        if TreadmillViewModel.isPreview {
            window.orderFrontRegardless()
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: RootView.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Z1 WalkingPad"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.nsGround
        // A fixed-size remote: no zoom, no full screen, no tabs.
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        // The Window menu has its own "Z1 WalkingPad ⌘0" that also reopens it.
        window.isExcludedFromWindowsMenu = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self
        if let appearance = PreviewHarness.appearance { window.appearance = appearance }
        window.setFrameAutosaveName("Z1MainWindow")
        if !window.setFrameUsingName("Z1MainWindow") {
            window.center()
        }
        // The saved frame carries a size from an older build, perhaps; the
        // size is the window's, not the user's.
        window.setContentSize(RootView.size)
        self.window = window
        return window
    }

    private func install(in window: NSWindow) {
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        let lightsEnd = window.standardWindowButton(.zoomButton)?.frame.maxX ?? 70
        let root = RootView(
            model: model,
            navigation: navigation,
            titlebarHeight: max(28, titlebarHeight),
            titlebarLeading: lightsEnd + 14
        )
        let host = NSHostingView(rootView: root)
        // The window owns its size. The content never asks for another one.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: RootView.size)
        window.contentView = host
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI tree: a closed window should cost nothing.
        window?.contentView = NSView()
    }
}
