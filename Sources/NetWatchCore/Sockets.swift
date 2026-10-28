import Foundation
import Darwin

enum Clock {
    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// Low-level probes. Every socket can be pinned to an interface with IP_BOUND_IF so the
/// default route (and therefore a VPN tunnel) is ignored.
enum Sock {
    private static let boundIf: Int32 = 25 // IP_BOUND_IF

    static func make(_ type: Int32, _ proto: Int32, bound iface: String?) -> Int32? {
        let fd = socket(AF_INET, type, proto)
        guard fd >= 0 else { return nil }
        if let iface {
            var idx = if_nametoindex(iface)
            if idx == 0 || setsockopt(fd, IPPROTO_IP, boundIf, &idx, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
                close(fd)
                return nil
            }
        }
        return fd
    }

    static func addr(_ ip: String, port: UInt16 = 0) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        return inet_pton(AF_INET, ip, &a.sin_addr) == 1 ? a : nil
    }

    static func waitReadable(_ fd: Int32, until deadline: UInt64) -> Bool {
        let now = Clock.nowNs()
        guard now < deadline else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(max(1, (deadline - now) / 1_000_000))
        return poll(&p, 1, ms) > 0 && (p.revents & Int16(POLLIN)) != 0
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8], to dst: inout sockaddr_in) -> Int {
        bytes.withUnsafeBytes { p in
            withUnsafePointer(to: &dst) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, p.baseAddress, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func checksum(_ b: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < b.count {
            sum += UInt32(b[i]) << 8 | UInt32(b[i + 1])
            i += 2
        }
        if i < b.count { sum += UInt32(b[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    // MARK: ICMP

    static func icmpPing(host: String, iface: String?, count: Int, intervalMs: Int, timeoutMs: Int) -> Probe {
        let rtts = icmpSeries(host: host, iface: iface, count: count, intervalMs: intervalMs, timeoutMs: timeoutMs).compactMap { $0 }
        let sent = count
        guard !rtts.isEmpty else { return Probe(sent: sent, received: 0) }
        return Probe(sent: sent, received: rtts.count, avgMs: rtts.reduce(0, +) / Double(rtts.count), maxMs: rtts.max(), minMs: rtts.min())
    }

    /// One entry per echo, in order: the round-trip time in ms, or nil when no reply arrived in time.
    static func icmpSeries(host: String, iface: String?, count: Int, intervalMs: Int, timeoutMs: Int) -> [Double?] {
        guard var dst = addr(host), let fd = make(SOCK_DGRAM, IPPROTO_ICMP, bound: iface) else {
            return [Double?](repeating: nil, count: count)
        }
        defer { close(fd) }
        let ident = UInt16.random(in: 1...UInt16.max)
        var series: [Double?] = []

        for seq in 0..<count {
            var pkt = [UInt8](repeating: 0, count: 16)
            pkt[0] = 8 // echo request
            pkt[4] = UInt8(ident >> 8); pkt[5] = UInt8(ident & 0xff)
            pkt[6] = UInt8(UInt16(seq) >> 8); pkt[7] = UInt8(UInt16(seq) & 0xff)
            for i in 8..<16 { pkt[i] = UInt8(0x40 + i) }
            let ck = checksum(pkt)
            pkt[2] = UInt8(ck >> 8); pkt[3] = UInt8(ck & 0xff)

            let t0 = Clock.nowNs()
            var rtt: Double?
            if send(fd, pkt, to: &dst) > 0 {
                let deadline = t0 + UInt64(timeoutMs) * 1_000_000
                var buf = [UInt8](repeating: 0, count: 512)
                while waitReadable(fd, until: deadline) {
                    var from = sockaddr_in()
                    var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, &buf, buf.count, 0, $0, &fromLen)
                        }
                    }
                    if n <= 0 { break }
                    // ICMP sockets on macOS see replies meant for other sockets, so insist on the sender and our payload.
                    guard from.sin_addr.s_addr == dst.sin_addr.s_addr else { continue }
                    // macOS hands back the IP header on ICMP datagram sockets.
                    let off = buf[0] >> 4 == 4 ? Int(buf[0] & 0x0f) * 4 : 0
                    if n >= off + 16, buf[off] == 0, buf[off + 8] == pkt[8],
                       UInt16(buf[off + 6]) << 8 | UInt16(buf[off + 7]) == UInt16(seq) {
                        rtt = Double(Clock.nowNs() - t0) / 1_000_000
                        break
                    }
                }
            }
            series.append(rtt)
            if seq < count - 1 { usleep(UInt32(intervalMs) * 1000) }
        }
        return series
    }

    // MARK: DNS

    /// Asks `server` for a random, uncached name. NXDOMAIN counts as an answer: it proves the whole resolver path works.
    static func dnsQuery(server: String, iface: String?, timeoutMs: Int) -> Double? {
        guard var dst = addr(server, port: 53), let fd = make(SOCK_DGRAM, IPPROTO_UDP, bound: iface) else { return nil }
        defer { close(fd) }
        let tid = UInt16.random(in: 0...UInt16.max)
        var q: [UInt8] = [UInt8(tid >> 8), UInt8(tid & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in "\(UInt32.random(in: 0...999_999)).nw-probe.example.com".split(separator: ".") {
            q.append(UInt8(label.utf8.count))
            q.append(contentsOf: label.utf8)
        }
        q += [0, 0, 1, 0, 1]

        let t0 = Clock.nowNs()
        guard send(fd, q, to: &dst) > 0 else { return nil }
        let deadline = t0 + UInt64(timeoutMs) * 1_000_000
        var buf = [UInt8](repeating: 0, count: 512)
        while waitReadable(fd, until: deadline) {
            let n = recv(fd, &buf, buf.count, 0)
            if n < 12 { return nil }
            if UInt16(buf[0]) << 8 | UInt16(buf[1]) == tid, buf[2] & 0x80 != 0 {
                return Double(Clock.nowNs() - t0) / 1_000_000
            }
        }
        return nil
    }

    // MARK: TCP

    static func tcpConnect(host: String, port: UInt16, iface: String?, timeoutMs: Int) -> Double? {
        guard var dst = addr(host, port: port), let fd = make(SOCK_STREAM, IPPROTO_TCP, bound: iface) else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let t0 = Clock.nowNs()
        let r = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 && errno != EINPROGRESS { return nil }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, Int32(timeoutMs)) > 0 else { return nil }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0 ? Double(Clock.nowNs() - t0) / 1_000_000 : nil
    }
}
