import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifier = ProblemNotifier()
    private lazy var refresher = WidgetRefresher(notifier: notifier)
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        refresher.start()
        notifier.requestAuthorization()

        // First launch: enable start-at-login (the widget only stays live while this app runs) and show the window once.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "onboarded") {
            defaults.set(true, forKey: "onboarded")
            try? SMAppService.mainApp.register()
            showWindow()
        }
    }

    /// A tap on the widget arrives as netwatch://open. Launching a background app that is already running does not
    /// raise its window by itself, so the widget asks for it explicitly.
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "netwatch" }) { showWindow() }
    }

    /// Opening the app again (Spotlight, Finder) while it runs in the background brings up the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        if window == nil {
            let makeView = { SettingsView(refresher: self.refresher, notifier: self.notifier) }
            // Let SwiftUI size the window and AppKit can end up in a layout loop ("needs another Update Constraints pass"),
            // which aborts the app the moment the window opens. So: measure the content once, off-window, and fix the size.
            let size = NSHostingView(rootView: makeView()).fittingSize
            let host = NSHostingController(rootView: makeView())
            host.sizingOptions = []

            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.contentViewController = host
            w.setContentSize(size)
            w.title = "NetWatch"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
