import SwiftUI
import ServiceManagement
import UserNotifications
import NetWatchCore
import NetWatchUI

struct SettingsView: View {
    @ObservedObject var refresher: WidgetRefresher
    @ObservedObject var notifier: ProblemNotifier
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(ProblemNotifier.enabledKey) private var notify = true
    @State private var networkName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NetWatch")
                .font(.title2.bold())

            // The medium preview keeps the window short enough for a small laptop screen; the large one is a widget-only size.
            // The same period switch as on the widget, here a plain button, so the choice can be tried without leaving the window.
            WidgetFrame {
                NetWatchMediumView(snapshot: refresher.snapshot, rangeButton: { range, label in
                    AnyView(Button { refresher.setRange(range) } label: { label }.buttonStyle(.plain))
                })
            }
                .frame(width: WidgetSizes.medium.width, height: WidgetSizes.medium.height)

            agentStatus

            HStack {
                Text("Эта сеть:")
                TextField("Название сети", text: $networkName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { refresher.renameCurrentNetwork(to: networkName) }
                    .disabled(refresher.snapshot.networkID == nil)
            }
            Text("Для каждой сети данные считаются отдельно. Назовите её, например, «Корпус А», и нажмите Return.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            ))
            Text("Пока приложение запущено, оно обновляет виджет при каждом изменении состояния сети.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Уведомлять о проблемах, которые длятся дольше минуты", isOn: $notify)
            Button("Проверить уведомление") { notifier.sendTest() }
                .disabled(!notify)
            permissionRow
                .frame(height: 36, alignment: .leading) // fixed height: the window is sized once, so this row must not change it

            HStack {
                Button("Обновить виджет") { refresher.reloadNow() }
                Spacer()
                Button("Выйти из NetWatch") { NSApp.terminate(nil) }
            }

            Text("Добавить виджет: правый клик по рабочему столу → «Изменить виджеты» → NetWatch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: WidgetSizes.large.width + 40)
        .preferredColorScheme(.dark)
        .onAppear {
            refresher.setWindowVisible(true)
            notifier.refreshStatus()
        }
        .onDisappear { refresher.setWindowVisible(false) }
        // Follow the current network (also when the Mac moves to another one while the window is open), but never overwrite typing.
        .onReceive(refresher.$snapshot) { snap in
            if let name = snap.networkName, !NSApp.isActive || networkName.isEmpty { networkName = name }
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch notifier.authorization {
        case .denied:
            HStack(spacing: 10) {
                Label("Система не разрешает NetWatch показывать уведомления", systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
                Spacer(minLength: 0)
                Button("Открыть настройки") { notifier.openSystemSettings() }
            }
        case .notDetermined:
            HStack(spacing: 10) {
                Text("Разрешение на уведомления ещё не запрошено.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Разрешить") {
                    NSApp.activate(ignoringOtherApps: true) // the system prompt appears only for the active app
                    notifier.requestAuthorization()
                }
            }
        default:
            Color.clear
        }
    }

    @ViewBuilder
    private var agentStatus: some View {
        let s = refresher.snapshot
        if let last = s.latest, !s.isStale {
            Label("Агент netwatchd работает, последний замер \(Int(s.generatedAt.timeIntervalSince(last.t))) с назад",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.ok)
                .font(.footnote)
        } else {
            Label("Агент netwatchd не пишет данные. Установите его: scripts/install.sh",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
                .font(.footnote)
        }
    }
}
