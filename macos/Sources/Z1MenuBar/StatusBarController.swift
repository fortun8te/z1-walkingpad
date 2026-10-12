import AppKit
import Combine
import SwiftUI

/// The status item and the popover that hangs from it.
///
/// A real `NSPopover` (transient): AppKit owns placement on the right display,
/// outside-click and Escape dismissal, and key focus — the things the old
/// hand-built panel re-implemented with global event monitors.
///
/// Two laws from earlier builds still hold here:
/// - No `MenuBarExtra`: its label rasterises every frame into the status item
///   (the multi-GB leak).
/// - The status item is created while the app is an accessory. The app never
///   becomes a Dock app any more, so it cannot be parked on the display that
///   has no menu bar.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let viewModel: TreadmillViewModel
    private var host: NSHostingController<PanelHost>?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()
    private var escapeMonitor: Any?
    private var lastClosedAt = Date.distantPast
    private var shownLit = -1
    private var shownTitle = ""
    private let hotKey = GlobalHotKey()

    init(viewModel: TreadmillViewModel) {
        self.viewModel = viewModel
        super.init()
        installItem()
        configurePopover()

        // objectWillChange fires *before* the new value lands; hop once so the
        // readout reads the new value. DispatchQueue, not RunLoop.main: the
        // latter only drains in the default mode and froze during tracking.
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)

        viewModel.$globalShortcutEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.setHotKey(enabled) }
            .store(in: &bag)
        refresh()
    }

    // MARK: - popover

    private func configurePopover() {
        let host = NSHostingController(rootView: panelRoot(open: false))
        // Fixed size, owned here. Pages swap inside it; nothing resizes.
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: PanelView.size)
        self.host = host
        popover.contentViewController = host
        popover.contentSize = PanelView.size
        popover.behavior = .transient
        // Opens at once: the content is already sized and the view tree is
        // small, so there is nothing for an entrance animation to cover.
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
    }

    /// The panel's SwiftUI tree exists only while the popover is on screen:
    /// closed, nothing observes the model, nothing renders, and no timeline
    /// ticks in a window nobody can see. Each open also starts fresh on
    /// Now / Today (a glance opens on today).
    private func panelRoot(open: Bool) -> PanelHost {
        PanelHost(open: open, viewModel: viewModel) { [weak self] in self?.close() }
    }

    func toggle() {
        if popover.isShown {
            close()
            return
        }
        // A transient popover closes on the mouse-down that lands on the
        // status item, before this action runs. Without this guard that same
        // click would reopen it.
        guard Date().timeIntervalSince(lastClosedAt) > 0.3 else { return }
        show()
    }

    func show() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        host?.rootView = panelRoot(open: true)
        viewModel.panelDidOpen()
        SkyHook.setVisible(true)
        // An accessory app has to be active for its popover to take the
        // keyboard (Space, arrows, Escape, the speed field).
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        PopoverGround.install(in: popover)
        button.highlight(true)
        installEscapeMonitor()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        lastClosedAt = Date()
        removeEscapeMonitor()
        statusItem?.button?.highlight(false)
        host?.rootView = panelRoot(open: false)
        SkyHook.setVisible(false)
    }

    /// Escape inside the speed or weight field leaves the field first; the
    /// next Escape closes. NSPopover's own Escape handling never sees a key
    /// that a focused field editor swallows.
    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self,
                  let window = self.popover.contentViewController?.view.window,
                  event.window === window
            else { return event }
            if window.firstResponder is NSTextView {
                DispatchQueue.main.async { [weak window] in
                    guard let window, window.firstResponder is NSTextView else { return }
                    window.makeFirstResponder(nil)
                }
                return event
            }
            self.close()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: - global shortcut

    private func setHotKey(_ enabled: Bool) {
        if enabled {
            hotKey.register { [weak self] in
                guard let self else { return }
                if self.viewModel.isConnected {
                    self.viewModel.startStopTapped()
                } else {
                    NSSound.beep()
                }
            }
        } else {
            hotKey.unregister()
        }
    }

    // MARK: - item

    private func installItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleNone
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(itemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "Z1 WalkingPad"
            button.setAccessibilityLabel("Z1 WalkingPad")
        }
        item.isVisible = true
        statusItem = item
        shownLit = -1
        shownTitle = ""
        refresh()
    }

    @objc private func itemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        if wantsMenu {
            showContextMenu()
        } else {
            toggle()
        }
    }

    /// Right-click: the three things you might want without opening the panel.
    private func showContextMenu() {
        close()
        let menu = NSMenu()
        let running = viewModel.status.beltRunning
        let walk = NSMenuItem(
            title: running ? "Stop Walk" : "Start Walk",
            action: viewModel.isConnected ? #selector(menuStartStop) : nil,
            keyEquivalent: "w"
        )
        walk.keyEquivalentModifierMask = [.control, .option]
        walk.target = self
        menu.addItem(walk)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Z1 WalkingPad", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuStartStop() { viewModel.startStopTapped() }
    @objc private func menuQuit() { viewModel.quit() }

    /// Only touch the button when what it shows actually changed. The image
    /// is one of eight cached templates and is never animated.
    private func refresh() {
        guard let button = statusItem?.button else { return }
        let progress = viewModel.goalProgress ?? 0
        let lit = MenuBarGlyph.litTicks(progress)
        if lit != shownLit || button.image == nil {
            shownLit = lit
            button.image = MenuBarGlyph.image(progress: progress)
        }
        let title = viewModel.menuBarText.map { " " + $0 } ?? ""
        if title != shownTitle {
            shownTitle = title
            button.title = title
        }
    }
}

/// The popover's root: the panel while open, bare ground while closed.
struct PanelHost: View {
    let open: Bool
    let viewModel: TreadmillViewModel
    var close: () -> Void

    var body: some View {
        Group {
            if open {
                PanelView(viewModel: viewModel, close: close)
            } else {
                Theme.ink
            }
        }
        .frame(width: PanelView.size.width, height: PanelView.size.height)
    }
}

/// Paints the popover's frame (arrow included) in the panel's ground colour,
/// so the arrow does not show the system material against a black panel.
enum PopoverGround {
    private final class GroundView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0x0B / 255, green: 0x0C / 255, blue: 0x0E / 255, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }

    @MainActor
    static func install(in popover: NSPopover) {
        guard let content = popover.contentViewController?.view.window?.contentView,
              let frame = content.superview,
              !frame.subviews.contains(where: { $0 is GroundView })
        else { return }
        let ground = GroundView(frame: frame.bounds)
        ground.autoresizingMask = [.width, .height]
        frame.addSubview(ground, positioned: .below, relativeTo: content)
    }
}

/// The one place the sky learns whether anyone can see it.
enum SkyHook {
    @MainActor
    static func setVisible(_ visible: Bool) {
        SkyEngine.shared.setVisible(visible)
    }
}
