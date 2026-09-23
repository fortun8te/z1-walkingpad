import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let z1ReassertStatusItem = Notification.Name("z1ReassertStatusItem")
}

/// A borderless panel that can still take the keyboard.
///
/// A plain borderless `NSPanel` answers `canBecomeKey == false`, so the speed
/// field, weight field and goal field could never receive a keystroke and
/// Space never reached Start/Stop. Non-activating keeps the rest of the Mac
/// where it was: opening the panel does not steal the frontmost app.
final class Z1Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The status item and the panel that hangs from it.
///
/// Why hand-built instead of `MenuBarExtra`: its label rasterises every frame
/// into the status item (the multi-GB leak), and creating the item while the
/// app is a Dock app parks it on the display without a menu bar. Both are
/// handled here, once.
@MainActor
final class StatusBarController: NSObject {
    private let viewModel: TreadmillViewModel
    private var statusItem: NSStatusItem?
    private var panel: Z1Panel?
    private var bag = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var shownLit = -1
    private var shownTitle = ""

    init(viewModel: TreadmillViewModel) {
        self.viewModel = viewModel
        super.init()
        installItem()

        // objectWillChange fires *before* the new value lands; reading the
        // model synchronously there always showed the previous second.
        viewModel.objectWillChange
            // DispatchQueue, not RunLoop.main: the latter only drains in the
            // default mode, so the readout froze while a tracking loop ran.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .z1ReassertStatusItem)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reassert() }
            .store(in: &bag)
        refresh()
    }

    /// If a Dock-policy change parked the item on the display without a menu
    /// bar, rebuild it while the app is an accessory.
    func reassert() {
        guard !isOnMenuBar() else { return }
        let wantsRegular = NSApp.activationPolicy() == .regular
        if wantsRegular { NSApp.setActivationPolicy(.accessory) }
        installItem()
        if wantsRegular { NSApp.setActivationPolicy(.regular) }
    }

    func show() {
        if panel != nil {
            closePanel()
            return
        }
        guard let button = statusItem?.button else { return }

        let host = NSHostingController(
            rootView: PanelView(viewModel: viewModel, close: { [weak self] in self?.closePanel() })
        )
        // The view owns its size. It is fixed, so the panel never resizes
        // under the pointer; pages swap inside the same frame.
        host.sizingOptions = []
        let size = PanelView.size

        let panel = Z1Panel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.setContentSize(size)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        panel.setFrameOrigin(origin(for: size, button: button))
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        installDismissMonitors()
    }

    func closePanel() {
        removeDismissMonitors()
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        statusItem?.button?.highlight(false)
    }

    // MARK: - placement

    /// Centre under the status item on the screen that owns the menu bar the
    /// click hit, clamped inside that screen.
    private func origin(for size: NSSize, button: NSStatusBarButton) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let buttonFrame = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        // Resolve the display from geometry, not `window.screen` (which can
        // lag after a Dock-policy flip). The button's centre sits well inside
        // its menu bar. The pointer is the fallback, nudged 1 pt down: at the
        // top edge of the lower display `mouseLocation.y == frame.maxY`,
        // which `contains` assigns to the display stacked above it, the one
        // with no menu bar.
        let buttonCentre = buttonFrame.map { NSPoint(x: $0.midX, y: $0.midY) }
        let probe = NSPoint(x: mouse.x, y: mouse.y - 1)
        let screen = buttonCentre.flatMap { centre in NSScreen.screens.first { $0.frame.contains(centre) } }
            ?? NSScreen.screens.first { $0.frame.contains(probe) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchorX: CGFloat
        if let buttonFrame, visible.minX...visible.maxX ~= buttonFrame.midX {
            anchorX = buttonFrame.midX
        } else {
            anchorX = mouse.x
        }
        var x = anchorX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        // Hang from the item itself when it is on this display (an auto-hidden
        // menu bar makes visibleFrame reach the top edge); never below the Dock.
        var top = visible.maxY
        if let buttonFrame, let screen, screen.frame.contains(NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)) {
            top = min(top, buttonFrame.minY)
        }
        let y = max(top - size.height - 6, visible.minY)
        return NSPoint(x: x, y: y)
    }

    // MARK: - dismissal

    /// A non-activating panel never deactivates, so `hidesOnDeactivate` never
    /// fired and the panel stayed up over everything. Close on any click that
    /// lands outside it, and on Escape.
    private func installDismissMonitors() {
        removeDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, let panel = self.panel, panel.isKeyWindow else {
                return event
            }
            // Escape inside a text field leaves the field first (the field
            // still sees the key, so the speed field's onExitCommand runs);
            // the next Escape closes. Without this, a focused field swallowed
            // every Escape and the panel could not be dismissed by keyboard.
            if panel.firstResponder is NSTextView {
                DispatchQueue.main.async { [weak panel] in
                    guard let panel, panel.firstResponder is NSTextView else { return }
                    panel.makeFirstResponder(nil)
                }
                return event
            }
            self.closePanel()
            return nil
        }
    }

    private func removeDismissMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    // MARK: - item

    private func isOnMenuBar() -> Bool {
        guard let screen = statusItem?.button?.window?.screen else { return false }
        return screen.frame.maxY - screen.visibleFrame.maxY >= 8
    }

    private func installItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleNone
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "Z1 WalkingPad"
        }
        item.isVisible = true
        // Rebuilt while the panel is open: keep the pressed look.
        item.button?.highlight(panel != nil)
        statusItem = item
        shownLit = -1
        shownTitle = ""
        refresh()
    }

    @objc private func toggle(_ sender: Any?) {
        show()
    }

    /// Only touch the button when what it shows actually changed.
    private func refresh() {
        guard let button = statusItem?.button else { return }
        let lit = MenuBarGlyph.litTicks(viewModel.goalProgress ?? 0)
        if lit != shownLit || button.image == nil {
            shownLit = lit
            button.image = MenuBarGlyph.image(progress: viewModel.goalProgress ?? 0)
        }
        let title = viewModel.menuBarText.map { " " + $0 } ?? ""
        if title != shownTitle {
            shownTitle = title
            button.title = title
        }
    }
}
