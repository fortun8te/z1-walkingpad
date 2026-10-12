import AppKit
import SwiftUI

/// The compact remote, plus independent resizable History and Settings windows.
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
    private var secondaryWindows: [Page: NSWindow] = [:]

    init(model: TreadmillViewModel, navigation: Navigation) {
        self.model = model
        self.navigation = navigation
        super.init()
        navigation.openSecondary = { [weak self] page in self?.showSecondary(page) }
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
            if let page = PreviewHarness.page, page != .now { showSecondary(page) }
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
        if TreadmillViewModel.isPreview {
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
        window.contentView = host
    }

    /// Secondary work gets its own resizable window; the remote never changes size.
    private func showSecondary(_ page: Page) {
        let key: Page = page == .records ? .history : page
        let window: NSWindow
        if let existing = secondaryWindows[key] {
            window = existing
        } else {
            let size = key == .settings ? CGSize(width: 500, height: 650) : CGSize(width: 560, height: 700)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            window.title = key == .settings ? "WalkingPad Settings" : "Walking History"
            window.minSize = NSSize(width: 480, height: 600)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.tabbingMode = .disallowed
            window.backgroundColor = Theme.nsGround
            if let appearance = PreviewHarness.appearance { window.appearance = appearance }
            window.center()
            secondaryWindows[key] = window
        }
        window.contentView = NSHostingView(rootView: SecondaryPage(model: model, initialPage: page))
        if TreadmillViewModel.isPreview { window.orderFrontRegardless() }
        else { window.makeKeyAndOrderFront(nil); NSApp.activate() }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI tree: a closed window should cost nothing.
        guard let closing = notification.object as? NSWindow else { return }
        closing.contentView = NSView()
    }
}

/// A normal macOS content area with native window chrome and room to scroll.
private struct SecondaryPage: View {
    let model: TreadmillViewModel
    @State private var page: Page

    init(model: TreadmillViewModel, initialPage: Page) {
        self.model = model
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if page == .records {
                HStack {
                    Button { page = .history } label: { Label("History", systemImage: "chevron.left") }
                    Spacer()
                    Text("Records").font(Theme.emphasis)
                }
            }
            switch page {
            case .settings: SettingsPage(model: model)
            case .records: RecordsPage(model: model)
            default: HistoryPage(model: model, onShowRecords: { page = .records })
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
        .tint(Theme.ink)
    }
}
