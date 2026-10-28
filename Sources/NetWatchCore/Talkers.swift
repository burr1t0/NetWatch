import Foundation

/// Which processes were moving the most data a moment ago. `nettop` needs no privileges but is heavy
/// (about 5 s and over a second of CPU), so callers use it only during a problem and not often.
enum Talkers {
    /// Names that only relay other apps' traffic and would hide the real source.
    private static let relays: Set<String> = ["Tunnel", "mDNSResponder", "netwatchd", "NetWatch", "nettop", "launchd", "kernel_task"]

    static func top(_ count: Int = 3, minBytesPerSecond: Double = 20_000) -> [String]? {
        guard let out = run("/usr/bin/nettop", ["-P", "-d", "-L", "2", "-s", "1", "-x", "-J", "bytes_in,bytes_out"], timeout: 15) else { return nil }
        return parse(out, count: count, minBytesPerSecond: minBytesPerSecond)
    }

    /// nettop prints two blocks, each starting with a header line. The first is cumulative since boot,
    /// the second is the one-second delta, which is what we want.
    static func parse(_ output: String, count: Int, minBytesPerSecond: Double) -> [String]? {
        let blocks = output.components(separatedBy: ",bytes_in,bytes_out,\n")
        guard blocks.count >= 3 else { return nil }

        var rows: [(name: String, bytes: Double)] = []
        for line in blocks[2].split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let rx = Double(f[1]), let tx = Double(f[2]) else { continue }
            // "Telegram.13754" -> "Telegram": the pid is the last dot-separated part.
            let name = f[0].split(separator: ".").dropLast().joined(separator: ".")
            guard !name.isEmpty, !relays.contains(name) else { continue }
            rows.append((name, rx + tx))
        }
        let top = rows.filter { $0.bytes >= minBytesPerSecond }.sorted { $0.bytes > $1.bytes }.prefix(count)
        return top.map { $0.bytes >= 1e6 ? String(format: "%@ %.1f МБ/с", $0.name, $0.bytes / 1e6) : String(format: "%@ %.0f КБ/с", $0.name, $0.bytes / 1e3) }
    }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Drain the pipe on another thread so a chatty child cannot block on a full buffer.
        var data = Data()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
