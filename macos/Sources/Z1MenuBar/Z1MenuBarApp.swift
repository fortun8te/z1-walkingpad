import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-first: no Dock icon and no app-switcher entry unless the
        // user asks for one (Settings → Show in Dock).
        let wantsDock = UserDefaults.standard.bool(forKey: TreadmillViewModel.dockKey)
        NSApp.setActivationPolicy(wantsDock ? .regular : .accessory)
    }
}

@main
struct Z1MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = TreadmillViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            // Never put TimelineView / Canvas / custom NSImage animation in
            // this label. SwiftUI rasterizes it into NSStatusItem.setImage
            // on every frame and the process climbs to multiple GB of RAM
            // while the extra never paints.
            Label {
                if let readout = viewModel.menuBarText {
                    Text(readout).monospacedDigit()
                } else {
                    Text("Z1")
                }
            } icon: {
                Image(systemName: viewModel.status.beltRunning
                      ? "figure.walk.motion"
                      : "figure.walk")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
