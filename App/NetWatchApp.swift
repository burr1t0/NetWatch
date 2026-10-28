import SwiftUI

@main
struct NetWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // No scenes of its own: the app lives in the background and opens its window by hand (see AppDelegate).
    var body: some Scene {
        Settings { EmptyView() }
    }
}
