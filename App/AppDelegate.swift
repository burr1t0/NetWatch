import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let refresher = WidgetRefresher()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        refresher.start()

        // First launch: enable start-at-login (the widget only stays live while this app runs) and show the window once.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "onboarded") {
            defaults.set(true, forKey: "onboarded")
            try? SMAppService.mainApp.register()
            showWindow()
        }
    }

    /// Opening the app again (Spotlight, Finder) while it runs in the background brings up the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(refresher: refresher)))
            w.title = "NetWatch"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
