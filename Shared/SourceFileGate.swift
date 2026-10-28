import Foundation

/// Accepted I/O is enqueued before callers suspend. Closing drains that queue.
final class SourceFileGate: @unchecked Sendable {
    final class Operation<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<Value, Error>?
        private var waiters: [CheckedContinuation<Value, Error>] = []
        fileprivate func finish(_ result: Result<Value, Error>) {
            let waiting = lock.withLock {
                precondition(outcome == nil)
                outcome = result
                let waiting = waiters; waiters.removeAll()
                return waiting
            }
            for waiter in waiting { waiter.resume(with: result) }
        }
        func value() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Value, Error>? = lock.withLock {
                    if let outcome { return outcome }
                    waiters.append(continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "design.highgain.margined.document-edits")
    private var accepting = true
    func enqueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) -> Operation<Value> {
        let operation = Operation<Value>()
        let accepted = lock.withLock {
            guard accepting else { return false }
            queue.async { operation.finish(Result { try work() }) }
            return true
        }
        if !accepted { operation.finish(.failure(CancellationError())) }
        return operation
    }
    func close() -> Operation<Void> {
        let operation = Operation<Void>()
        lock.withLock {
            accepting = false
            queue.async { operation.finish(.success(())) }
        }
        return operation
    }
}
