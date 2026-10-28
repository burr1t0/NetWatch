import Foundation

/// Append-only JSON Lines log, one file per day. Cheap to write, trivial to read from anywhere (including a widget).
public final class SampleStore {
    public let dir: URL
    private let queue = DispatchQueue(label: "netwatch.store")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Built from the real home directory: inside a sandboxed widget, FileManager's Application Support points into its container.
    public static var defaultDir: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/NetWatch", isDirectory: true)
    }

    public init(dir: URL = SampleStore.defaultDir) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func file(for d: Date) -> URL {
        dir.appendingPathComponent("samples-\(Self.dayString(d)).jsonl")
    }

    public func append(_ s: Sample) {
        queue.sync {
            guard var line = try? encoder.encode(s) else { return }
            line.append(0x0a)
            let url = file(for: s.t)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    public func load(since: Date, until: Date = Date()) -> [Sample] {
        queue.sync {
            var result: [Sample] = []
            var day = Calendar.current.startOfDay(for: since)
            while day <= until {
                if let text = try? String(contentsOf: file(for: day), encoding: .utf8) {
                    for line in text.split(separator: "\n") {
                        if var s = try? decoder.decode(Sample.self, from: Data(line.utf8)), s.t >= since, s.t <= until {
                            // Raw measurements are the source of truth, so rule fixes also apply to old data.
                            s.verdict = Diagnosis.verdict(for: s)
                            result.append(s)
                        }
                    }
                }
                day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
            }
            return result.sorted { $0.t < $1.t }
        }
    }

    public func prune(keepDays: Int) {
        queue.sync {
            let cutoff = Self.dayString(Date().addingTimeInterval(-Double(keepDays) * 86_400))
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in files where name.hasPrefix("samples-") && name.hasSuffix(".jsonl") {
                let day = String(name.dropFirst("samples-".count).dropLast(".jsonl".count))
                if day < cutoff { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
            }
        }
    }
}
