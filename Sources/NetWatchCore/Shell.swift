import Foundation

enum Shell {
    /// Runs a command and returns its stdout, or nil if it could not start or ran longer than `timeout`.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
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
