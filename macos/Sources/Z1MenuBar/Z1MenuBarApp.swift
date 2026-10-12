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
        if TreadmillViewModel.isPreview, ProcessInfo.processInfo.environment["Z1_PREVIEW_POPOVER"] != "1" {
            showPreviewWindow()
            return
        }
        // A menu-bar app, only. LSUIElement starts us as an agent, and the
        // status item must be created while we are one: switching to a Dock
        // app first parks it on the upper display, which has no menu bar.
        NSApp.setActivationPolicy(.accessory)
        let viewModel = TreadmillViewModel()
        self.viewModel = viewModel
        let bar = StatusBarController(viewModel: viewModel)
        statusBar = bar
        if TreadmillViewModel.isPreview {
            // Harness: open the real popover so its frame can be captured.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                bar.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let number = NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") }?.windowNumber ?? -1
                    print("Z1_PREVIEW_WINDOW \(number)")
                    fflush(stdout)
                }
            }
            return
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
        let host = NSHostingController(rootView: PanelView(viewModel: viewModel).clipShape(.rect(cornerRadius: 12, style: .continuous)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(PanelView.size)
        window.setFrameOrigin(NSPoint(x: 80, y: 120))
        window.orderFrontRegardless()
        SkyHook.setVisible(true)
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
