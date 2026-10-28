import AppKit
import Foundation
import UserNotifications
import NetWatchCore

/// Posts a macOS notification when a network problem has lasted more than a minute, and once more when it is over.
final class ProblemNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notifyProblems"
    private static let sinceKey = "alertNotifiedSince"
    private static let lastKey = "alertLastProblem"

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()
    // Only touched from the refresher's queue.
    private var state: AlertState

    override init() {
        let d = UserDefaults.standard
        state = AlertState(notifiedSince: d.object(forKey: Self.sinceKey) as? Date,
                           lastProblemAlert: d.object(forKey: Self.lastKey) as? Date)
        super.init()
        center.delegate = self
        // The permission is changed in System Settings, outside this app: look again whenever the user comes back to it.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in self?.refreshStatus() }
    }

    /// macOS asks only once. After a refusal the only way back is the Notifications pane of System Settings.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.authorization = settings.authorizationStatus }
        }
    }

    func evaluate(_ samples: [Sample], networks: [KnownNetwork]) {
        guard enabled, let alert = Alerts.next(samples: samples, state: &state, networks: networks) else { return }
        let d = UserDefaults.standard
        d.set(state.notifiedSince, forKey: Self.sinceKey)
        d.set(state.lastProblemAlert, forKey: Self.lastKey)
        post(alert)
    }

    func sendTest() {
        // Ask the system now: the cached status may predate a change made in System Settings.
        // A refused permission would swallow the test silently, which looks like a broken button, so send the user there instead.
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            DispatchQueue.main.async { self.authorization = settings.authorizationStatus }
            switch settings.authorizationStatus {
            case .denied:
                DispatchQueue.main.async { self.openSystemSettings() }
            case .notDetermined:
                self.requestAuthorization()
            default:
                self.post(Alert(kind: .problem, title: "NetWatch · проверка уведомлений",
                                body: "Так будет выглядеть уведомление, если проблема с сетью продлится дольше минуты."))
            }
        }
    }

    private func post(_ alert: Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.kind == .problem ? .default : nil
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show the banner even while the app is frontmost (its settings window is open).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
