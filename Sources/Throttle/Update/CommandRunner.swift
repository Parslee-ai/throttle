import Foundation

/// What a finished subprocess left behind.
struct CommandResult: Equatable, Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String

    /// Both streams, stdout first. `spctl` reports on stderr and `pkgutil` on
    /// stdout, so the parsers read the two together.
    var combinedOutput: String {
        standardError.isEmpty ? standardOutput : standardOutput + "\n" + standardError
    }
}

/// Runs a system tool. A protocol so tests can script the output of `pkgutil`,
/// `spctl`, and `osascript` without ever launching them.
protocol CommandRunning: Sendable {
    /// Runs `executable` with `arguments` as an argument vector. Never through
    /// a shell: nothing in `arguments` is ever parsed as shell syntax here.
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult
}

/// Production runner built on `Process`.
struct ProcessCommandRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            // `Process` blocks while it waits, so it runs off the cooperative
            // pool; the administrator prompt can hold it for minutes.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.runBlocking(executable, arguments))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Drain stderr on another thread while this one drains stdout, so a
        // chatty tool can never fill one pipe and deadlock against the other.
        let errorData = DataBox()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.set(err.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData.get(), as: UTF8.self)
        )
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
        func get() -> Data { lock.withLock { data } }
    }
}
