import Foundation

enum ConversionError: LocalizedError {
    case message(String), cancelled
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "Cancelled"
        }
    }
}

/// One runner per export batch. Cancellation stays set until a new batch creates a runner.
final class ProcessRunner: @unchecked Sendable {
    private final class ProgressReader: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func drain(_ handle: FileHandle, duration: Double, progress: @escaping (Double) -> Void) {
            var remainder = Data()
            while true {
                let chunk = handle.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                remainder.append(chunk)
                while let newline = remainder.firstIndex(of: 10) {
                    let line = String(decoding: remainder[..<newline], as: UTF8.self)
                    remainder.removeSubrange(...newline)
                    if line == "progress=end" { lock.lock(); finished = true; lock.unlock() }
                    if line.hasPrefix("out_time_us="), let time = Double(line.dropFirst(12)), duration > 0 {
                        progress(min(0.99, max(0, time / 1_000_000 / duration)))
                    }
                }
                if remainder.count > 4096 { remainder.removeAll(keepingCapacity: true) }
            }
        }
        func completed() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }
    private final class ErrorTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func drain(_ handle: FileHandle) {
            while true {
                let chunk = handle.readData(ofLength: 16_384)
                if chunk.isEmpty { break }
                lock.lock()
                data.append(chunk)
                if data.count > 8000 { data.removeFirst(data.count - 8000) }
                lock.unlock()
            }
        }
        func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        lock.unlock()
        if let active, active.isRunning { active.terminate() }
    }

    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw ConversionError.cancelled }
    }

    func run(executable: URL, arguments: [String], duration: Double,
             progress: @escaping (Double) -> Void) throws {
        try checkCancellation()
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        let stdout = Pipe(), outputProgress = ProgressReader()
        task.standardOutput = stdout
        // Drain errors concurrently, retaining a bounded tail without disk growth.
        let stderr = Pipe(), errors = ErrorTail(), streams = DispatchGroup()
        task.standardError = stderr
        defer {
            lock.lock(); process = nil; lock.unlock()
        }
        lock.lock()
        if cancelled { lock.unlock(); throw ConversionError.cancelled }
        process = task
        do { try task.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        streams.enter()
        DispatchQueue.global(qos: .utility).async { errors.drain(stderr.fileHandleForReading); streams.leave() }
        streams.enter()
        DispatchQueue.global(qos: .utility).async { outputProgress.drain(stdout.fileHandleForReading, duration: duration, progress: progress); streams.leave() }
        task.waitUntilExit()
        streams.wait()
        try checkCancellation()
        // FFmpeg can refuse an existing -n destination while returning status zero.
        // A successful media job must also emit its terminal progress record.
        guard task.terminationStatus == 0 && outputProgress.completed() else {
            let tail = errors.text()
            throw ConversionError.message(tail.isEmpty
                ? "The conversion did not finish successfully (code \(task.terminationStatus))."
                : tail)
        }
        progress(1)
    }
}
