import AppKit
import SwiftUI

@MainActor
enum Z1Launch {
    static var delegate: AppDelegate?
}

@main
struct Z1MenuBarApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            Z1Launch.delegate = delegate
            app.delegate = delegate
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var viewModel: TreadmillViewModel?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if TreadmillViewModel.isPreview {
            showPreviewWindow()
            return
        }
        // LSUIElement is true, so we start as an agent. The status item has
        // to be created while we are still an accessory. Switching to a Dock
        // app first parks it on the upper display, which has no menu bar.
        NSApp.setActivationPolicy(.accessory)
        let viewModel = TreadmillViewModel()
        self.viewModel = viewModel
        let bar = StatusBarController(viewModel: viewModel)
        statusBar = bar
        let wantsDock = UserDefaults.standard.object(forKey: TreadmillViewModel.dockKey) as? Bool ?? true
        if wantsDock {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async { bar.reassert() }
        }
        LocalReleaseServer.shared.ensureRunning()
    }

    /// UI harness: the panel in an ordinary window, no status item, no BLE.
    /// `Z1_PREVIEW=1 Z1MenuBar -z1.hasSeenIntro 1` then `screencapture -l`.
    private var previewWindow: NSWindow?
    private func showPreviewWindow() {
        NSApp.setActivationPolicy(.regular)
        let viewModel = TreadmillViewModel()
        self.viewModel = viewModel
        let host = NSHostingController(rootView: PanelView(viewModel: viewModel))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(PanelView.size)
        window.setFrameOrigin(NSPoint(x: 80, y: 120))
        window.orderFrontRegardless()
        previewWindow = window
        print("Z1_PREVIEW_WINDOW \(window.windowNumber)")
        fflush(stdout)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalReleaseServer.shared.stopIfOwned()
    }
}
