import AppKit
import SwiftUI

@main
enum Z1App {
    /// NSApplication holds its delegate weakly.
    @MainActor private static var delegate: AppDelegate?

    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            Self.delegate = delegate
            app.delegate = delegate
            app.run()
        }
    }
}

/// A regular app: one small window, a Dock icon, a normal menu bar.
///
/// Closing the window leaves the app running, so a walk keeps being recorded
/// and ⌃⌥W keeps working. Quit (⌘Q, the Dock, logout) goes through
/// `applicationShouldTerminate`, which asks before leaving a moving belt.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var model: TreadmillViewModel!
    private let navigation = Navigation()
    private var mainWindow: MainWindow!
    private var walkItem: NSMenuItem?
    private var connectItem: NSMenuItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let appearance = PreviewHarness.appearance { NSApp.appearance = appearance }
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = TreadmillViewModel()
        mainWindow = MainWindow(model: model, navigation: navigation)
        mainWindow.show()
        if TreadmillViewModel.isPreview, let window = mainWindow.window {
            print("Z1_PREVIEW_WINDOW \(window.windowNumber)")
            fflush(stdout)
        }
    }

    /// A Dock click with the window closed brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !mainWindow.isVisible { mainWindow.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: quitting

    /// Every quit lands here. A moving belt gets a question; everything else
    /// disconnects cleanly (capped at 3 s) and exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let mode: TreadmillViewModel.QuitMode
        if let requested = model.requestedQuit {
            mode = requested
        } else if model.live.beltRunning, model.isConnected {
            guard let choice = askAboutMovingBelt() else {
                model.quitCancelled()
                return .terminateCancel
            }
            mode = choice
        } else {
            mode = .leaveBelt
        }
        Task {
            await model.shutdown(mode)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func askAboutMovingBelt() -> TreadmillViewModel.QuitMode? {
        mainWindow.show()
        let alert = NSAlert()
        alert.messageText = "The belt is still moving"
        alert.informativeText = "Stop it before quitting? If you leave it running, the app stops recording this walk until you open it again."
        alert.addButton(withTitle: "Stop Belt and Quit")
        alert.addButton(withTitle: "Quit, Keep Walking")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .stopBelt
        case .alertSecondButtonReturn: return .leaveBelt
        default: return nil
        }
    }

    // MARK: menu actions

    @objc private func showMainWindow(_ sender: Any?) {
        mainWindow.show()
    }

    @objc private func showPage(_ sender: NSMenuItem) {
        guard let page = sender.representedObject as? Page.RawValue, let target = Page(rawValue: page) else { return }
        navigation.show(target, model: model)
        mainWindow.show()
    }

    @objc private func showSettings(_ sender: Any?) {
        navigation.show(.settings, model: model)
        mainWindow.show()
    }

    @objc private func toggleWalk(_ sender: Any?) {
        model.startStopTapped()
    }

    @objc private func toggleConnection(_ sender: Any?) {
        model.connectTapped()
    }

    @objc private func stopPadAndQuit(_ sender: Any?) {
        model.stopBeltAndQuit()
    }

    // MARK: menu

    /// The Walk menu's titles follow the pad when it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        walkItem?.title = model.live.beltRunning ? "Stop Walk" : "Start Walk"
        connectItem?.title = model.isConnected ? "Disconnect" : "Connect"
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model else { return false }
        switch item.action {
        case #selector(toggleWalk(_:)): return model.isConnected && !model.busy
        case #selector(toggleConnection(_:)): return !model.busy && !model.isConnecting
        case #selector(showPage(_:)):
            item.state = (item.representedObject as? String) == navigation.page.rawValue ? .on : .off
            return true
        default: return true
        }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let name = "Z1 WalkingPad"

        let app = submenu(name, in: main)
        app.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showSettings(_:)), ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu("Edit", in: main)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let walk = submenu("Walk", in: main)
        walk.delegate = self
        let start = item("Start Walk", #selector(toggleWalk(_:)), "w")
        start.keyEquivalentModifierMask = [.control, .option]
        walk.addItem(start)
        walkItem = start
        let connect = item("Connect", #selector(toggleConnection(_:)), "")
        walk.addItem(connect)
        connectItem = connect
        walk.addItem(.separator())
        walk.addItem(item("Stop Pad and Quit", #selector(stopPadAndQuit(_:)), ""))

        let view = submenu("View", in: main)
        for page in Page.allCases {
            let entry = item(page.title, #selector(showPage(_:)), page.shortcut)
            entry.representedObject = page.rawValue
            view.addItem(entry)
        }

        let window = submenu("Window", in: main)
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(item(name, #selector(showMainWindow(_:)), "0"))
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
