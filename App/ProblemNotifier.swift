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
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in self?.refreshStatus() }
    }

    func refreshStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.authorization = settings.authorizationStatus }
        }
    }

    func evaluate(_ samples: [Sample]) {
        guard enabled, let alert = Alerts.next(samples: samples, state: &state) else { return }
        let d = UserDefaults.standard
        d.set(state.notifiedSince, forKey: Self.sinceKey)
        d.set(state.lastProblemAlert, forKey: Self.lastKey)
        post(alert)
    }

    func sendTest() {
        post(Alert(kind: .problem, title: "NetWatch · проверка уведомлений",
                   body: "Так будет выглядеть уведомление, если проблема с сетью продлится дольше минуты."))
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
