import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }

    /// The end of stderr, trimmed, for error messages.
    public var stderrTail: String {
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 600 ? String(text.suffix(600)) : text
    }
}

/// Continuously drains one pipe so the child can never block on a full buffer.
private final class PipeCollector {
    private let lock = NSLock()
    private var data = Data()
    private var lineBuffer = Data()
    private let limit: Int
    private let onLine: ((String) -> Void)?
    let finished = DispatchSemaphore(value: 0)

    init(handle: FileHandle, limit: Int, onLine: ((String) -> Void)?) {
        self.limit = limit
        self.onLine = onLine
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.finished.signal()
            } else {
                self.append(chunk)
            }
        }
    }

    private func append(_ chunk: Data) {
        var lines: [String] = []
        lock.lock()
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
        if onLine != nil {
            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self))
                lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            }
        }
        lock.unlock()
        if let onLine { lines.forEach(onLine) }
    }

    var collected: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Runs helper executables with argument arrays (never a shell), a minimal
/// environment, no stdin, drained pipes and cooperative cancellation that
/// terminates only the process started here.
public enum ProcessRunner {
    static let baseEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL": "en_US.UTF-8",
        "HOME": NSHomeDirectory(),
        "TMPDIR": NSTemporaryDirectory(),
    ]

    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        environment: [String: String] = [:],
        token: CancellationToken? = nil,
        onStdoutLine: ((String) -> Void)? = nil
    ) throws -> ProcessResult {
        try token?.check()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = baseEnvironment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let errorPipe = Pipe()
        process.standardError = errorPipe
        let errorCollector = PipeCollector(handle: errorPipe.fileHandleForReading, limit: 1 << 20, onLine: nil)

        var outputCollector: PipeCollector?
        var outputPipe: Pipe?
        var outputHandle: FileHandle?
        if let stdoutFile {
            guard FileManager.default.createFile(atPath: stdoutFile.path, contents: nil) else {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                throw OrbitError.outputNotWritable("Cannot create \(stdoutFile.lastPathComponent).")
            }
            let handle = try FileHandle(forWritingTo: stdoutFile)
            process.standardOutput = handle
            outputHandle = handle
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            outputPipe = pipe
            outputCollector = PipeCollector(handle: pipe.fileHandleForReading, limit: 16 << 20, onLine: onStdoutLine)
        }

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            try? outputHandle?.close()
            throw OrbitError.missingTool("Could not start \(executable.path): \(error.localizedDescription)")
        }

        let handlerID = token?.onCancel { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        process.waitUntilExit()
        if let handlerID { token?.removeHandler(handlerID) }
        try? outputHandle?.close()

        // The collectors signal at EOF; the timeout only guards against a
        // descendant that keeps the pipe open after the child exits.
        _ = errorCollector.finished.wait(timeout: .now() + 5)
        if let outputCollector { _ = outputCollector.finished.wait(timeout: .now() + 5) }
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        if token?.isCancelled == true { throw OrbitError.cancelled }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: outputCollector?.collected ?? Data(),
            stderr: errorCollector.collected)
    }
}
