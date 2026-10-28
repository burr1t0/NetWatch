import SwiftUI
import ServiceManagement
import NetWatchCore
import NetWatchUI

struct SettingsView: View {
    @ObservedObject var refresher: WidgetRefresher
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NetWatch")
                .font(.title2.bold())

            WidgetFrame { NetWatchLargeView(snapshot: refresher.snapshot) }
                .frame(width: WidgetSizes.large.width, height: WidgetSizes.large.height)

            agentStatus

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
        .onAppear { refresher.setWindowVisible(true) }
        .onDisappear { refresher.setWindowVisible(false) }
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
