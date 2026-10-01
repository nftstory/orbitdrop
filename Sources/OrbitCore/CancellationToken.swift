import Foundation

/// Thread-safe cancellation flag shared by the GUI, CLI and engines.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let pending = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }

    /// Registers a handler that runs once on cancellation. Runs immediately if already cancelled.
    @discardableResult
    public func onCancel(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return id
        }
        handlers[id] = handler
        lock.unlock()
        return id
    }

    public func removeHandler(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    public func check() throws {
        if isCancelled { throw OrbitError.cancelled }
    }
}
