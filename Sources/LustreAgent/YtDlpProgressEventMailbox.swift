import Foundation

enum YtDlpProgressEventMailboxError: Error, Equatable { case capacityExceeded, closed, cancelled, failed, multipleConsumers }

actor YtDlpProgressEventMailbox {
    private enum State { case open, closed, failed, cancelled }
    private var buffer: YtDlpProgressEventBuffer
    private var state: State = .open
    private var waiter: CheckedContinuation<YtDlpProgressSample?, Error>?

    init(capacity: Int) { buffer = YtDlpProgressEventBuffer(capacity: capacity) }

    func offer(_ sample: YtDlpProgressSample) throws {
        switch state {
        case .closed: throw YtDlpProgressEventMailboxError.closed
        case .failed: throw YtDlpProgressEventMailboxError.failed
        case .cancelled: throw YtDlpProgressEventMailboxError.cancelled
        case .open: break
        }
        do { try buffer.offer(sample) }
        catch { throw YtDlpProgressEventMailboxError.capacityExceeded }
        resumeWaiterIfPossible()
    }

    func next() async throws -> YtDlpProgressSample? {
        if let sample = buffer.popFirst() { return sample }
        switch state {
        case .closed: return nil
        case .failed: throw YtDlpProgressEventMailboxError.failed
        case .cancelled: throw YtDlpProgressEventMailboxError.cancelled
        case .open: break
        }
        guard waiter == nil else { throw YtDlpProgressEventMailboxError.multipleConsumers }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() { guard case .open = state else { return }; state = .closed; resumeWaiterIfPossible() }
    func fail() { terminal(.failed, error: .failed) }
    func cancel() { terminal(.cancelled, error: .cancelled) }

    private func terminal(_ newState: State, error: YtDlpProgressEventMailboxError) {
        guard case .open = state else { return }
        state = newState
        buffer.removeAll()
        let continuation = waiter; waiter = nil
        continuation?.resume(throwing: error)
    }

    private func resumeWaiterIfPossible() {
        guard let continuation = waiter else { return }
        if let sample = buffer.popFirst() { waiter = nil; continuation.resume(returning: sample) }
        else if case .closed = state { waiter = nil; continuation.resume(returning: nil) }
    }
}
