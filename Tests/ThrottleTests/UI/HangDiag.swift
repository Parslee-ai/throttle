import Foundation

// Temporary diagnostics for hosted tests that hang on the CI runner.
enum HangDiag {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = Date()
    nonisolated(unsafe) private static var label = ""
    nonisolated(unsafe) private static var sampledLabel = ""
    nonisolated(unsafe) private static var started = false

    static func step(_ name: String) {
        lock.lock()
        last = Date()
        label = name + " @" + String(Date().timeIntervalSince1970)
        let first = !started
        started = true
        lock.unlock()
        let thread = Thread.isMainThread ? "main" : "bg"
        FileHandle.standardError.write(Data("[hang-diag] \(Date()) [\(thread)] \(name)\n".utf8))
        if first { startWatchdog() }
    }

    private static func startWatchdog() {
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                lock.lock()
                let stale = Date().timeIntervalSince(last) > 15 && sampledLabel != label
                let current = label
                if stale { sampledLabel = label }
                lock.unlock()
                if stale { dump(current) }
            }
        }
        thread.start()
    }

    private static func dump(_ current: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        FileHandle.standardError.write(Data("[hang-diag] STUCK 15s after: \(current); sampling pid \(pid)\n".utf8))
        for (tool, args) in [("/usr/bin/sample", ["\(pid)", "2"]),
                             ("/usr/bin/sudo", ["-n", "/usr/sbin/spindump", "\(pid)", "2", "-stdout"])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(1500) {
                    FileHandle.standardError.write(Data("[hang-diag] \(line)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("[hang-diag] \(tool) failed: \(error)\n".utf8))
            }
        }
    }
}
