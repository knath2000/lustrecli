import Foundation

enum CloudWebSocketMessage: Sendable {
    case data(Data)
    case text(String)
    case localCommandCompletion

    var data: Data {
        switch self {
        case let .data(data): data
        case let .text(text): Data(text.utf8)
        case .localCommandCompletion: Data(#"{"version":1,"type":"command-available"}"#.utf8)
        }
    }

    var isLocalCommandCompletion: Bool {
        if case .localCommandCompletion = self { return true }
        return false
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
    private var remoteWakePending = false
    private var localWakePending = false

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    func offer(_ message: CloudWebSocketMessage) {
        if message.isCommandAvailable {
            if message.isLocalCommandCompletion {
                guard !localWakePending else { return }
                localWakePending = true
            } else {
                guard !remoteWakePending else { return }
                remoteWakePending = true
            }
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

    func consumeWake(allowRemote: Bool = true) -> Bool {
        let consumed = localWakePending || (allowRemote && remoteWakePending)
        if localWakePending {
            localWakePending = false
            buffered.removeAll(where: \.isLocalCommandCompletion)
        }
        if allowRemote, remoteWakePending {
            remoteWakePending = false
            buffered.removeAll { $0.isCommandAvailable && !$0.isLocalCommandCompletion }
        }
        return consumed
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
