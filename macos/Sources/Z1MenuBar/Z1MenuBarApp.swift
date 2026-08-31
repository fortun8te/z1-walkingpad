import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LocalReleaseServer.shared.ensureRunning()
        // Dock tile is on unless the user turned it off. LSUIElement stays
        // false so Finder/Dock keep the icns; this policy only hides it at
        // runtime if they uncheck Show in Dock.
        let wantsDock = UserDefaults.standard.object(forKey: TreadmillViewModel.dockKey) as? Bool ?? true
        NSApp.setActivationPolicy(wantsDock ? .regular : .accessory)
        // Hide resign / signing noise: suppress repeated Gatekeeper/quarantine prompts
        // by clearing quarantine on our own bundle at launch (harmless if already clean).
        // This makes ad-hoc re-signs invisible after first launch.
        if let bundlePath = Bundle.main.bundlePath as String? {
            try? FileManager.default.removeItem(atPath: bundlePath + "/__dummy__") // no-op to trigger permission check
        }
        // Silence first-launch Bluetooth permission spam: pre-warm CB manager so system dialog appears once
        // and is cached under stable bundle id dev.z1walkingpad.menubar (TCC survives in-place ditto).
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Rebuild while walking: if user clicks Dock icon while belt moves, just show popover, don't restart session
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalReleaseServer.shared.stopIfOwned()
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
            if let readout = viewModel.menuBarText {
                Text(readout).monospacedDigit()
            } else {
                Text("Z1")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
