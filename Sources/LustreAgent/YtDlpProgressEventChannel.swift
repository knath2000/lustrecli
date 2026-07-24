import Foundation

enum YtDlpProgressEventChannelError: Error, Equatable { case capacityExceeded, closed, cancelled, multipleConsumers }

actor YtDlpProgressEventChannel {
    private enum State { case open, finished, cancelled }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<YtDlpProgressSample?, Error>
    }

    private var buffer: YtDlpProgressEventBuffer
    private var state: State = .open
    private var waiter: Waiter?
    private var waiterRegistrationObserver: CheckedContinuation<Bool, Never>?

    init(capacity: Int) { buffer = YtDlpProgressEventBuffer(capacity: capacity) }

    func offer(_ sample: YtDlpProgressSample) throws {
        switch state {
        case .open:
            break
        case .finished:
            throw YtDlpProgressEventChannelError.closed
        case .cancelled:
            throw YtDlpProgressEventChannelError.cancelled
        }
        if buffer.isEmpty, let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: sample)
            return
        }
        do { try buffer.offer(sample) }
        catch YtDlpProgressEventBufferError.capacityExceeded { throw YtDlpProgressEventChannelError.capacityExceeded }
    }

    func next() async throws -> YtDlpProgressSample? {
        if Task.isCancelled { throw YtDlpProgressEventChannelError.cancelled }
        if let sample = buffer.popFirst() { return sample }
        switch state {
        case .finished:
            return nil
        case .cancelled:
            throw YtDlpProgressEventChannelError.cancelled
        case .open:
            break
        }
        guard waiter == nil else { throw YtDlpProgressEventChannelError.multipleConsumers }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { registerWaiter(id: id, continuation: $0) }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func finish() {
        guard case .open = state else { return }
        state = .finished
        completeWaiterRegistrationObserver(false)
        guard buffer.isEmpty, let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }

    func cancel() {
        guard case .open = state else { return }
        state = .cancelled
        completeWaiterRegistrationObserver(false)
        buffer.removeAll()
        let waiter = self.waiter
        self.waiter = nil
        waiter?.continuation.resume(throwing: YtDlpProgressEventChannelError.cancelled)
    }

    func waitForWaiterRegistrationForTesting() async -> Bool {
        if waiter != nil { return true }
        guard case .open = state else { return false }
        precondition(waiterRegistrationObserver == nil)
        return await withCheckedContinuation { waiterRegistrationObserver = $0 }
    }

    private func registerWaiter(id: UUID, continuation: CheckedContinuation<YtDlpProgressSample?, Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: YtDlpProgressEventChannelError.cancelled)
            return
        }
        if let sample = buffer.popFirst() {
            continuation.resume(returning: sample)
            return
        }
        switch state {
        case .finished:
            continuation.resume(returning: nil)
            return
        case .cancelled:
            continuation.resume(throwing: YtDlpProgressEventChannelError.cancelled)
            return
        case .open:
            break
        }
        guard waiter == nil else {
            continuation.resume(throwing: YtDlpProgressEventChannelError.multipleConsumers)
            return
        }
        waiter = Waiter(id: id, continuation: continuation)
        completeWaiterRegistrationObserver(true)
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: YtDlpProgressEventChannelError.cancelled)
    }

    private func completeWaiterRegistrationObserver(_ result: Bool) {
        let observer = waiterRegistrationObserver
        waiterRegistrationObserver = nil
        observer?.resume(returning: result)
    }
}
