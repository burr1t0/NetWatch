import Foundation
import NetWatchCore

setvbuf(stdout, nil, _IOLBF, 0)

func usage() -> Never {
    print("""
    netwatchd — диагностика домашней сети

      netwatchd run [--base N] [--fast N]   фоновый сбор замеров (по умолчанию 30 с / 3 с при проблемах)
      netwatchd once [--context]            один замер; --context добавляет серию до роутера и список «кто грузит сеть»
      netwatchd report [--hours N]          отчёт за последние N часов (по умолчанию 24)

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
    print(Report.text(samples: store.load(since: since), since: since))

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
