import Foundation

/// One-shot timers for BLE operations, keyed by operation.
///
/// CoreBluetooth never times anything out by itself, so every pending
/// operation (connect, discover, read, write, notify) races a timer. A bare
/// `asyncAfter` cannot be cancelled once the operation it guards has finished,
/// and a timer left behind by an earlier operation would then fail a later one
/// that reuses the same slot: a connect that succeeded could cancel the next
/// connect attempt, an old write timer could fail a newer write on the same
/// characteristic.
///
/// Every timer therefore carries a token. Scheduling under a key replaces and
/// cancels whatever was there, `cancel` retires the key when the operation
/// completes, and a timer that fires after being replaced or cancelled sees
/// that its token is no longer current and does nothing.
public final class OperationTimeouts: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var tokens: [String: UUID] = [:]
    private var items: [String: DispatchWorkItem] = [:]

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Run `fire` on the queue after `seconds`, unless the key is cancelled or
    /// rescheduled first. `fire` runs at most once and only for the newest
    /// timer scheduled under `key`.
    public func schedule(
        after seconds: TimeInterval,
        key: String,
        _ fire: @escaping @Sendable () -> Void
    ) {
        let token = UUID()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let current = self.lock.withLock { () -> Bool in
                guard self.tokens[key] == token else { return false }
                self.tokens[key] = nil
                self.items[key] = nil
                return true
            }
            if current { fire() }
        }
        let replaced = lock.withLock { () -> DispatchWorkItem? in
            let old = items[key]
            tokens[key] = token
            items[key] = item
            return old
        }
        replaced?.cancel()
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Retire the timer under `key` (the operation finished).
    public func cancel(_ key: String) {
        let item = lock.withLock { () -> DispatchWorkItem? in
            tokens[key] = nil
            return items.removeValue(forKey: key)
        }
        item?.cancel()
    }

    public func cancel(keysWithPrefix prefix: String) {
        let doomed = lock.withLock { tokens.keys.filter { $0.hasPrefix(prefix) } }
        for key in doomed { cancel(key) }
    }

    public func cancelAll() {
        let doomed = lock.withLock { Array(tokens.keys) }
        for key in doomed { cancel(key) }
    }

    /// Keys that currently have a live timer. For tests and diagnostics.
    public var pendingKeys: [String] {
        lock.withLock { tokens.keys.sorted() }
    }
}
