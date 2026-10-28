import Foundation
import NetWatchCore

setvbuf(stdout, nil, _IOLBF, 0)

func usage() -> Never {
    print("""
    netwatchd — диагностика домашней сети

      netwatchd run [--base N] [--fast N]   фоновый сбор замеров (по умолчанию 30 с / 3 с при проблемах)
      netwatchd once [--context]            один замер; --context добавляет серию до роутера и список «кто грузит сеть»
      netwatchd report [--hours N] [--network ИМЯ]   отчёт за последние N часов (по умолчанию 24), по каждой сети отдельно
      netwatchd networks                    сети, в которых бывал Mac
      netwatchd router                      что сейчас сообщает роутер (если это Tenda): трафик, устройства, соединение с провайдером
      netwatchd name <id|current> <имя>     назвать сеть, например: netwatchd name current Корпус А

    Лог: \(SampleStore.defaultDir.path)
    """)
    exit(64)
}

func option(_ name: String, in args: [String]) -> Double? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

let args = Array(CommandLine.arguments.dropFirst())
let store = SampleStore()

switch args.first ?? "run" {
case "once":
    let prober = Prober()
    prober.forceContext = args.contains("--context")
    if prober.forceContext { _ = await prober.sample() } // the first round only primes the traffic counters
    let s = await prober.sample()
    store.append(s)
    print(s.summaryLine)
    if prober.forceContext {
        if let l = s.link {
            print(String(format: "трафик: ↓%.2f ↑%.2f МБ/с, AWDL %d байт, ошибки %d/%d", l.rxBps / 1e6, l.txBps / 1e6, l.awdlBytes, l.rxErrors, l.txErrors))
        }
        if let y = s.system {
            print(String(format: "система: load %.1f из %d ядер, thermal %d, low power %@, батарея %@", y.load1, y.cores, y.thermal, y.lowPower ? "да" : "нет", y.onBattery ? "да" : "нет"))
        }
        print("серия до роутера (мс, -1 = потеря): \(s.gwBurst.map(String.init(describing:)) ?? "—")")
        print("кто грузил сеть: \(s.talkers.map { $0.isEmpty ? "никто заметный" : $0.joined(separator: "; ") } ?? "—")")
        print("причины: \(Causes.causes(for: s).map(\.title))")
    }

case "report":
    let hours = option("--hours", in: args) ?? 24
    let since = Date().addingTimeInterval(-hours * 3600)
    let only = args.firstIndex(of: "--network").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    print(Report.text(samples: store.load(since: since), since: since, networks: NetworkRegistry().all(), only: only))

case "networks":
    let known = NetworkRegistry().all()
    let since = Date().addingTimeInterval(-7 * 86_400)
    let groups = Networks.partition(store.load(since: since), known: known)
    if groups.isEmpty { print("За последние 7 дней замеров нет.") }
    let f = DateFormatter()
    f.dateFormat = "dd.MM HH:mm"
    for g in groups {
        let gw = Networks.gateway(for: g.id, known: known, samples: g.samples) ?? "—"
        let flags = known.first { $0.id == g.id }.map { k -> String in
            [k.gatewayIcmpFiltered == true ? "ICMP до роутера закрыт" : nil, k.externalIcmpFiltered == true ? "ICMP наружу закрыт" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        } ?? ""
        print("\(g.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(Networks.name(for: g.id, known: known).padding(toLength: 22, withPad: " ", startingAt: 0)) роутер \(gw.padding(toLength: 15, withPad: " ", startingAt: 0)) замеров \(g.samples.count), последний \(f.string(from: g.samples.last?.t ?? Date()))\(flags.isEmpty ? "" : "  [\(flags)]")")
    }

case "router":
    // One full round, so it goes through the same detection and reading as the agent does.
    let s = await Prober().sample()
    guard let r = s.router else {
        print("Роутер не отдаёт данные: это не Tenda или он сейчас не ответил.")
        exit(1)
    }
    func fmt(_ kbps: Double?) -> String { kbps.map { String(format: "%.2f МБ/с (%.0f КБ/с)", $0 / 1024, $0) } ?? "—" }
    print("трафик через роутер:  ↓ \(fmt(r.wanDownKBps))   ↑ \(fmt(r.wanUpKBps))")
    print("устройств в сети:     \(r.clients.map(String.init) ?? "—")")
    print("соединение с провайдером держится: \(r.wanUptime.map { "\($0 / 3600) ч \($0 % 3600 / 60) мин" } ?? "—")  (код статуса \(r.wanStatus ?? "—"))")

case "name":
    guard args.count >= 3 else { usage() }
    let registry = NetworkRegistry()
    let known = registry.all()
    var id = args[1]
    if id == "current" {
        let recent = store.load(since: Date().addingTimeInterval(-3600))
        id = Networks.currentOnly(recent, known: known).id ?? ""
    }
    guard known.contains(where: { $0.id == id }) else {
        print("Такой сети нет в списке. Посмотрите: netwatchd networks")
        exit(1)
    }
    registry.rename(id: id, to: args.dropFirst(2).joined(separator: " "))
    print("Готово: \(id) → \(args.dropFirst(2).joined(separator: " "))")

case "run":
    let monitor = Monitor(
        store: store,
        baseInterval: option("--base", in: args) ?? 30,
        fastInterval: option("--fast", in: args) ?? 3
    )
    // Under launchd stdout goes to a file; per-sample lines would grow it forever, and the JSONL log already has them.
    if isatty(STDOUT_FILENO) != 0 {
        monitor.onSample = { s, next in
            print("\(s.summaryLine)   → след. через \(Int(next))с")
        }
    }
    monitor.start()
    print("netwatchd запущен, лог: \(store.dir.path)")
    dispatchMain()

default:
    usage()
}
