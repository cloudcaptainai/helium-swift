import Foundation

/// Executes an async operation with a timeout, returning nil if the timeout is exceeded
func withTimeoutOrNil<T>(milliseconds: UInt64, operation: @escaping () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            return nil
        }
        let result = await group.next()
        group.cancelAll()
        return result ?? nil
    }
}

func withTimeoutAbandoningOperation<T: Sendable>(milliseconds: UInt64, operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let resumeGuard = ResumeGuard()
        let timer = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            if resumeGuard.tryResume() {
                continuation.resume(returning: nil)
            }
        }
        Task.detached(priority: .userInitiated) {
            let result = await operation()
            if resumeGuard.tryResume() {
                timer.cancel()
                continuation.resume(returning: result)
            }
        }
    }
}

/// One-shot resume guard for `withCheckedContinuation` races.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
