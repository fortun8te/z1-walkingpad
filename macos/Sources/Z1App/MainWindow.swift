import AppKit
import SwiftUI

/// The one window: small, fixed, not resizable, with a transparent title bar
/// the content runs under, and a translucent body: the desktop shows through
/// a blur, with `Theme.ground` tinting it so dark mode stays deep.
///
/// Closing it only hides it; the app keeps running (and keeps recording a
/// walk) until Quit. While nobody can see it (closed, minimized, the app
/// hidden, or covered by other windows for half a minute) the SwiftUI tree is
/// gone, so nothing observes the model and nothing renders. Showing it again
/// builds a fresh tree, which is also why every reopen lands History on today.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private let model: TreadmillViewModel
    private let navigation: Navigation
    private(set) var window: NSWindow?
    private var occlusionTask: Task<Void, Never>?

    /// How long a window stays covered before its tree is dropped. Rebuilding
    /// resets view-local state (the History day), so a glance at another app
    /// must not cost it.
    private static let coveredGrace: Duration = .seconds(30)

    init(model: TreadmillViewModel, navigation: Navigation) {
        self.model = model
        self.navigation = navigation
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// On screen and not covered: what a person can actually see.
    var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && !NSApp.isHidden
            && window.occlusionState.contains(.visible)
    }

    func show() {
        let window = self.window ?? makeWindow()
        if window.contentView is NSVisualEffectView == false {
            install(in: window)
        }
        // The harness shows the window without taking focus, so typing in
        // another app never lands in it.
        if TreadmillViewModel.isPreview {
            window.orderFrontRegardless()
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
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
        window.isOpaque = false
        window.backgroundColor = .clear
        // A fixed-size remote: no zoom, no full screen, no tabs.
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        // The Window menu has its own "Z1 WalkingPad ⌘0" that also reopens it.
        window.isExcludedFromWindowsMenu = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self
        if let appearance = PreviewHarness.appearance { window.appearance = appearance }
        if TreadmillViewModel.isPreview {
            // The harness never reads or writes the real app's window frame.
            window.center()
        } else {
            window.setFrameAutosaveName("Z1MainWindow")
            if !window.setFrameUsingName("Z1MainWindow") { window.center() }
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
        host.autoresizingMask = [.width, .height]

        // Behind-window blur, always on: the look should not flip to flat
        // grey whenever another app is in front.
        let backdrop = NSVisualEffectView(frame: host.frame)
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.addSubview(host)
        window.contentView = backdrop
    }

    // MARK: rendering on and off

    /// Drops the SwiftUI tree: a window nobody sees should cost nothing.
    func suspendRendering() {
        occlusionTask?.cancel()
        occlusionTask = nil
        window?.contentView = NSView()
    }

    /// Builds the tree again if it was dropped and the window can be seen.
    func resumeRendering() {
        guard let window, window.isVisible, !window.isMiniaturized, !NSApp.isHidden,
              window.contentView is NSVisualEffectView == false else { return }
        install(in: window)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        suspendRendering()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        suspendRendering()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        resumeRendering()
        model.hurryReconnect()
    }

    /// Covered or uncovered. Covered drops the tree after a grace period;
    /// uncovered cancels that and brings the tree back.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if isOnScreen {
            occlusionTask?.cancel()
            occlusionTask = nil
            resumeRendering()
            model.hurryReconnect()
        } else {
            occlusionTask?.cancel()
            occlusionTask = Task { [weak self] in
                try? await Task.sleep(for: Self.coveredGrace, tolerance: .seconds(5))
                guard !Task.isCancelled, let self, !self.isOnScreen else { return }
                self.suspendRendering()
            }
        }
    }
}
