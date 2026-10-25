import Foundation

struct ProcessError: LocalizedError {
    let command: String
    let status: Int32
    let tail: String
    var errorDescription: String? {
        "\((command as NSString).lastPathComponent) exited with code \(status)\(tail.isEmpty ? "" : ": \(tail)")"
    }
}

/// Runs external tools (makemkvcon, HandBrakeCLI, ffmpeg …), streams their output line by
/// line (splitting on both \n and \r so progress updates arrive live) and supports cancellation.
final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let p = process, p.isRunning {
            p.interrupt()
            // Force-kill only if this very process is still running; its PID may be reused otherwise.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    @discardableResult
    func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], log: JobLogger? = nil,
             onLine: ((String) -> Void)? = nil) async throws -> String {
        if cancelled { throw CancellationError() }
        log?.write("$ \(executable) \(arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Tools.searchPath
        env.merge(environment) { _, new in new }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        // A cancel that arrives before the process exists must still stop it, so this is checked under the lock.
        let alreadyCancelled = lock.withLock { () -> Bool in
            process = p
            return cancelled
        }
        if alreadyCancelled { throw CancellationError() }

        let collector = OutputCollector(onLine: onLine, log: log)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.feed(data) }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                p.terminationHandler = { _ in cont.resume() }
                do {
                    try p.run()
                    // cancel() skips a process that was not running yet.
                    if lock.withLock({ cancelled }) { p.interrupt() }
                } catch {
                    p.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: { self.cancel() }

        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collector.feed(rest) }
        collector.flush()

        if cancelled || Task.isCancelled { throw CancellationError() }
        guard p.terminationStatus == 0 else {
            throw ProcessError(command: executable, status: p.terminationStatus,
                               tail: collector.lastLines.suffix(3).joined(separator: " | "))
        }
        return collector.output
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var output = ""
    private(set) var lastLines: [String] = []
    let onLine: ((String) -> Void)?
    let log: JobLogger?

    init(onLine: ((String) -> Void)?, log: JobLogger?) {
        self.onLine = onLine
        self.log = log
    }

    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            emit(String(decoding: lineData, as: UTF8.self))
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
    }

    private func emit(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        lastLines.append(trimmed)
        if lastLines.count > 20 { lastLines.removeFirst() }
        // Progress lines arrive many times per second during long encodes; keep them out of memory and logs.
        if !Self.isProgressNoise(trimmed) {
            output += trimmed + "\n"
            log?.write(trimmed)
        }
        onLine?(trimmed)
    }

    /// Progress lines would flood the job log, so they are only passed to the callback.
    static func isProgressNoise(_ line: String) -> Bool {
        line.hasPrefix("PRGV:") || line.hasPrefix("Encoding: task") || line.hasPrefix("out_time")
            || line.hasPrefix("frame=") || line.hasPrefix("progress=")
    }
}

/// Simple per-job log file, viewable in the app (ARM: "View logs").
final class JobLogger: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle?
    private let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(url: URL) {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "[\(Self.formatter.string(from: Date()))] \(message)\n"
        handle?.write(Data(line.utf8))
    }
}
