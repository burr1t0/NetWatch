import Foundation

public enum Report {
    private static func clock(_ d: Date, date: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = date ? "dd.MM HH:mm:ss" : "HH:mm:ss"
        return f.string(from: d)
    }

    private static func dur(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)с" }
        if s < 3600 { return "\(s / 60)м \(s % 60)с" }
        return "\(s / 3600)ч \(s % 3600 / 60)м"
    }

    private static func pct(_ v: [Double], _ q: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
    }

    private static func stats(_ title: String, _ v: [Double]) -> String? {
        guard let p50 = pct(v, 0.5), let p95 = pct(v, 0.95), let mx = v.max() else { return nil }
        return String(format: "  %@ p50 %.0f   p95 %.0f   max %.0f мс", title.padding(toLength: 26, withPad: " ", startingAt: 0), p50, p95, mx)
    }

    /// Seconds of observation each sample stands for. Long gaps (sleep, agent stopped) are capped, not counted as uptime.
    static func weights(_ s: [Sample]) -> [Double] {
        zip(s, s.dropFirst()).map { min($1.t.timeIntervalSince($0.t), 120) } + [30]
    }

    private static func tally(_ s: [Sample]) -> (spikes: [Sample], withContext: [Sample], counts: [SpikeCause: Int]) {
        let spikes = s.filter(Causes.isLocalSpike)
        let withContext = spikes.filter { $0.link != nil || $0.system != nil }
        var counts: [SpikeCause: Int] = [:]
        for x in withContext { for c in Causes.causes(for: x) { counts[c, default: 0] += 1 } }
        return (spikes, withContext, counts)
    }

    private static func topSpikeCause(_ s: [Sample]) -> (SpikeCause, Int, Int)? {
        let t = tally(s)
        guard let top = t.counts.max(by: { $0.value < $1.value }) else { return nil }
        return (top.key, top.value, t.withContext.count)
    }

    /// What the router itself reported: reconnects to the provider, how many devices were online, and how busy the
    /// internet port was, compared between the moments the router answered slowly and the rest of the time.
    private static func routerSection(_ s: [Sample]) -> [String] {
        let withRouter = s.filter { $0.router != nil }
        guard !withRouter.isEmpty else { return [] }
        func mbps(_ kbps: [Double]) -> Double { kbps.isEmpty ? 0 : kbps.reduce(0, +) / Double(kbps.count) / 1024 }
        func down(_ list: [Sample]) -> [Double] { list.compactMap { $0.router?.wanDownKBps } }

        var lines = ["\nРоутер (данные его страницы состояния):"]
        let reconnects = withRouter.filter { $0.router?.reconnected == true }
        let when = reconnects.prefix(5).map { clock($0.t, date: true) }.joined(separator: ", ")
        lines.append("  Заново подключался к провайдеру: \(reconnects.count)" + (reconnects.isEmpty ? "" : " (\(when))"))
        if let uptime = withRouter.last?.router?.wanUptime { lines.append("  Соединение с провайдером держится: \(dur(Double(uptime)))") }
        let clients = withRouter.compactMap { $0.router?.clients }
        if let lo = clients.min(), let hi = clients.max() { lines.append("  Устройств в сети: \(lo == hi ? "\(lo)" : "\(lo)–\(hi)")") }

        let all = down(withRouter)
        lines.append(String(format: "  Трафик через роутер: в среднем ↓%.2f МБ/с, пик ↓%.1f МБ/с", mbps(all), (all.max() ?? 0) / 1024))
        let spikes = withRouter.filter(Causes.isLocalSpike)
        if !spikes.isEmpty {
            let calm = withRouter.filter { !Causes.isLocalSpike($0) }
            lines.append(String(format: "  Во время скачков задержки до роутера: ↓%.2f МБ/с, в остальное время: ↓%.2f МБ/с",
                                mbps(down(spikes)), mbps(down(calm))))
        }
        return lines
    }

    /// Slow answers from the router itself: what else was going on at that moment?
    private static func spikeSection(_ s: [Sample]) -> [String] {
        let t = tally(s)
        guard !t.spikes.isEmpty else { return ["\nСкачки задержки до роутера (>30 мс): не было"] }
        var lines = ["\nСкачки задержки до роутера (>30 мс): \(t.spikes.count) замеров"]
        guard !t.withContext.isEmpty else {
            lines.append("  Данных о контексте нет: агент пишет их, начиная с этой версии.")
            return lines
        }
        for (cause, n) in t.counts.sorted(by: { $0.value > $1.value }) {
            lines.append("  \(cause.title.padding(toLength: 62, withPad: " ", startingAt: 0)) \(n) из \(t.withContext.count)")
        }
        var seen: [String] = []
        for x in t.spikes.reversed() { for line in x.talkers ?? [] where !seen.contains(line) { seen.append(line) } }
        if !seen.isEmpty { lines.append("  Что грузило сеть в эти моменты: " + seen.prefix(4).joined(separator: "; ")) }
        return lines
    }

    /// One report per network, most recently used first. `only` narrows it to a network by id or part of its name.
    /// Networks are never mixed: a hotspot and a campus network have nothing to say about each other.
    public static func text(samples: [Sample], since: Date, now: Date = Date(), networks: [KnownNetwork] = [], only: String? = nil) -> String {
        var groups = Networks.partition(samples, known: networks)
        if let only = only?.lowercased(), !only.isEmpty {
            groups = groups.filter { $0.id.lowercased() == only || Networks.name(for: $0.id, known: networks).lowercased().contains(only) }
        }
        guard !groups.isEmpty else {
            return only == nil ? "Нет данных за выбранный период. Запустите: netwatchd run" : "Нет данных по этой сети. Список сетей: netwatchd networks"
        }
        let sections = groups.map { group -> String in
            var title = "NetWatch — отчёт · сеть «\(Networks.name(for: group.id, known: networks))»"
            if let gw = Networks.gateway(for: group.id, known: networks, samples: group.samples) { title += " (роутер \(gw))" }
            return section(samples: group.samples, since: since, now: now, title: title)
        }
        return sections.joined(separator: "\n\n" + String(repeating: "━", count: 48) + "\n\n")
    }

    private static func section(samples: [Sample], since: Date, now: Date, title: String) -> String {
        guard !samples.isEmpty else { return "Нет данных за выбранный период. Запустите: netwatchd run" }
        let s = samples.sorted { $0.t < $1.t }
        let w = weights(s)
        let observed = w.reduce(0, +)
        var out: [String] = []

        out.append(title)
        out.append("Период: \(clock(since, date: true)) — \(clock(now, date: true)), замеров: \(s.count), наблюдали \(dur(observed)) (\(Int(observed / max(1, now.timeIntervalSince(since)) * 100))% периода)")

        var byVerdict: [Verdict: Double] = [:]
        for (x, wt) in zip(s, w) { byVerdict[x.verdict, default: 0] += wt }
        out.append("\nСостояние:")
        for v in Verdict.allCases.sorted(by: { $0.severity < $1.severity }) {
            guard let t = byVerdict[v] else { continue }
            out.append("  \(v.title.padding(toLength: 14, withPad: " ", startingAt: 0)) \(dur(t).padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(format: "%.1f", t / observed * 100))%")
        }

        out.append("\nЗадержки:")
        let lines = [
            stats("роутер (ICMP)", s.compactMap { $0.gw?.avgMs }),
            stats("интернет напрямую", s.compactMap { $0.directRttMs }),
            stats("DNS", s.compactMap { $0.dnsMs }),
            stats("HTTPS (как у приложений)", s.compactMap { $0.httpMs }),
        ].compactMap { $0 }
        out.append(contentsOf: lines.isEmpty ? ["  нет данных"] : lines)

        let incidents = Diagnosis.incidents(from: s)
        let changes = Diagnosis.channelChanges(s)
        out.append("\nИнциденты: \(incidents.count)")
        var dfsHits = 0
        for i in incidents.suffix(20) {
            var line = "  \(clock(i.start, date: true)) · \(dur(i.duration).padding(toLength: 8, withPad: " ", startingAt: 0)) · \(i.verdict.title) (\(i.samples) зам.)"
            if let c = changes.first(where: { $0.at >= i.start.addingTimeInterval(-60) && $0.at <= i.end.addingTimeInterval(60) }) {
                line += "  ← смена канала \(c.from)→\(c.to)\(c.involvesDFS ? " (DFS)" : "")"
                if c.involvesDFS { dfsHits += 1 }
            }
            out.append(line)
            let found = Set(s.filter { $0.t >= i.start && $0.t <= i.end && Causes.isLocalSpike($0) }.flatMap { Causes.causes(for: $0) })
            let ordered = SpikeCause.allCases.filter { found.contains($0) }
            if !ordered.isEmpty { out.append("      причины: " + ordered.map(\.title).joined(separator: "; ")) }
        }

        out.append(contentsOf: spikeSection(s))
        out.append(contentsOf: routerSection(s))

        let wifi = s.compactMap { $0.wifi }
        if !wifi.isEmpty {
            let channels = Dictionary(grouping: wifi, by: { "\($0.band) ch\($0.channel)\($0.isDFS ? " DFS" : "")" })
            out.append("\nWi-Fi:")
            for (k, v) in channels.sorted(by: { $0.value.count > $1.value.count }) {
                out.append("  \(k.padding(toLength: 18, withPad: " ", startingAt: 0)) \(Int(Double(v.count) / Double(wifi.count) * 100))% времени")
            }
            let rssi = wifi.map { Double($0.rssi) }
            out.append(String(format: "  сигнал: средний %.0f dBm, худший %.0f dBm", rssi.reduce(0, +) / Double(rssi.count), rssi.min() ?? 0))
            out.append("  смен канала: \(changes.count)" + (changes.isEmpty ? "" : ", из них с DFS: \(changes.filter { $0.involvesDFS }.count)"))
        }

        let vpnShare = Double(s.filter { $0.vpn }.count) / Double(s.count)
        out.append("\nVPN включён: \(Int(vpnShare * 100))% замеров")

        out.append("\nВывод:")
        if incidents.isEmpty {
            out.append("  За период проблем не зафиксировано.")
        } else {
            var perLayer: [Verdict: Double] = [:]
            for i in incidents { perLayer[i.verdict, default: 0] += max(i.duration, 3) }
            if let top = perLayer.max(by: { $0.value < $1.value }) {
                out.append("  Больше всего проблемного времени приходится на: \(top.key.title) (\(dur(top.value))).")
            }
            if dfsHits > 0 {
                out.append("  \(dfsHits) из \(incidents.count) инцидентов совпали со сменой DFS-канала — стоит перевести роутер на канал 36–48 или 149–165.")
            }
            if let (cause, n, of) = topSpikeCause(s) {
                out.append("  Скачки задержки до роутера чаще всего связаны с причиной «\(cause.title)» (\(n) из \(of) замеров с контекстом).")
            }
        }
        return out.joined(separator: "\n")
    }
}
