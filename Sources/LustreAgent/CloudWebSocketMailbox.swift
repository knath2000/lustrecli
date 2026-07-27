import Foundation

enum CloudWebSocketMessage: Sendable {
    case data(Data)
    case text(String)

    var data: Data {
        switch self {
        case let .data(data): data
        case let .text(text): Data(text.utf8)
        }
    }

    var isCommandAvailable: Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["version"] as? Int == 1 && object["type"] as? String == "command-available"
    }
}

private enum CloudWebSocketMailboxError: Error {
    case cancelled
}

actor CloudWebSocketMailbox {
    private let capacity: Int
    private var buffered: [CloudWebSocketMessage] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<CloudWebSocketMessage, Error>)?
    private var terminalError: Error?
    private var wakePending = false

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    func offer(_ message: CloudWebSocketMessage) {
        if message.isCommandAvailable {
            guard !wakePending else { return }
            wakePending = true
        }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: message)
            return
        }
        guard terminalError == nil else { return }
        if buffered.count == capacity { buffered.removeFirst() }
        buffered.append(message)
    }

    func consumeWake() -> Bool {
        guard wakePending else { return false }
        wakePending = false
        buffered.removeAll(where: \.isCommandAvailable)
        return true
    }

    func next() async throws -> CloudWebSocketMessage {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if let terminalError { throw terminalError }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = (id, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func finish(_ error: Error) {
        terminalError = error
        buffered.removeAll(keepingCapacity: false)
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(throwing: error)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard waiter?.id == id else { return }
        let continuation = waiter?.continuation
        waiter = nil
        continuation?.resume(throwing: CloudWebSocketMailboxError.cancelled)
    }
}
