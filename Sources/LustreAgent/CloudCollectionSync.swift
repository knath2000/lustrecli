import Foundation
import LustreCore

public actor CloudCollectionSync {
    private let service: AgentService
    public let store: CloudCollectionStore
    private let identity: DeviceIdentity
    private let session: URLSession
    private var task: Task<Void, Never>?

    public init(service: AgentService, store: CloudCollectionStore, identity: DeviceIdentity = DeviceIdentity(), session: URLSession? = nil) {
        self.service = service
        self.store = store
        self.identity = identity
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                await synchronizeOnce()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func synchronizeOnce() async {
        do {
            try await refreshLocalProjection()
            guard let enrollment = try DeviceEnrollmentStore.load() else { return }
            let origin = try cloudOrigin(enrollment.cloudOrigin)
            let token = try await sessionToken(enrollment: enrollment, origin: origin)
            var hasMore = true
            while hasMore {
                let snapshot = try await store.snapshot()
                let pending = try await store.pendingMutations()
                var request = URLRequest(url: origin.appending(path: "api/cloud/v1/collections/sync"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONEncoder.cloud.encode(SyncRequest(cursor: snapshot.cursor, mutations: pending))
                let (data, response) = try await session.data(for: request)
                guard data.count <= 1_048_576, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw SyncError.invalidResponse }
                let result = try JSONDecoder.cloud.decode(SyncResponse.self, from: data)
                var changes = try result.changes.map {
                    CloudCollectionChange(
                        sequence: $0.sequence,
                        entityType: $0.entityType,
                        entityID: $0.entityID,
                        operation: $0.operation,
                        payload: try JSONEncoder.cloud.encode($0.payload)
                    )
                }
                if let bootstrap = result.bootstrap {
                    changes.insert(contentsOf: try bootstrap.watchlist.map {
                        CloudCollectionChange(sequence: 0, entityType: "watchlist", entityID: $0.id, operation: "upsert", payload: try JSONEncoder.cloud.encode($0))
                    }, at: 0)
                    changes.insert(contentsOf: try bootstrap.library.map {
                        CloudCollectionChange(sequence: 0, entityType: "library", entityID: $0.id, operation: "upsert", payload: try JSONEncoder.cloud.encode($0))
                    }, at: 0)
                }
                try await store.apply(changes: changes, acknowledgedMutationIDs: result.acknowledgedMutationIDs, cursor: result.cursor)
                hasMore = result.hasMore
            }
        } catch let error as DecodingError {
            fputs("Lustre Cloud collections: \(error.diagnosticDescription)\n", stderr)
        } catch {
            fputs("Lustre Cloud collections: \(error.localizedDescription)\n", stderr)
        }
    }

    public func refreshLocalProjection() async throws {
        let existing = try await store.snapshot()
        var known = Set(existing.library.map { $0.sourcePageURL.absoluteString })
        for job in try await service.allJobs() where job.status == .completed && job.destination == "local" {
            guard !known.contains(job.sourcePageURL.absoluteString) else { continue }
            let host = job.sourcePageURL.host?.replacingOccurrences(of: "www.", with: "") ?? "direct"
            let item = LustreCore.CloudLibraryItem(
                id: UUID(), sourcePageURL: job.sourcePageURL,
                title: job.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? job.completionArtifact?.filename ?? job.sourcePageURL.lastPathComponent,
                provider: host, thumbnailURL: nil, mediaKind: "video", completedAt: job.updatedAt,
                tags: [], collection: nil, favorite: false, createdAt: job.updatedAt, updatedAt: job.updatedAt
            )
            try await store.saveLibrary(item, jobID: job.id, displayFilename: job.completionArtifact?.filename, byteCount: job.totalBytes)
            known.insert(job.sourcePageURL.absoluteString)
        }
    }

    private func sessionToken(enrollment: CloudEnrollmentMetadata, origin: URL) async throws -> String {
        let client = try CloudEnrollmentClient(origin: origin)
        let challenge = try await client.deviceSessionChallenge(deviceID: enrollment.deviceID)
        let envelope = try CloudDeviceProtocol.envelope(
            purpose: "session", audience: enrollment.cloudOrigin,
            subjectID: enrollment.deviceID.uuidString.lowercased(), nonce: challenge.nonce,
            thumbprint: try identity.thumbprint(), expiresAt: challenge.expiresAt
        )
        return try await client.completeDeviceSession(
            deviceID: enrollment.deviceID, challengeID: challenge.challengeID,
            signature: try identity.sign(envelope)
        ).accessToken
    }

    private func cloudOrigin(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https" || (url.scheme == "http" && url.host == "localhost"), url.host != nil, url.user == nil, url.password == nil else { throw SyncError.invalidResponse }
        return url
    }

    private struct SyncRequest: Encodable {
        let cursor: Int64
        let mutations: [CloudCollectionMutation]
    }

    private struct SyncResponse: Decodable {
        struct Change: Decodable {
            let sequence: Int64
            let entityType: String
            let entityID: UUID
            let operation: String
            let payload: [String: JSONValue]
        }
        let cursor: Int64
        let hasMore: Bool
        let acknowledgedMutationIDs: [UUID]
        let changes: [Change]
        let bootstrap: Bootstrap?

        struct Bootstrap: Decodable {
            let watchlist: [LustreCore.CloudWatchlistItem]
            let library: [LustreCore.CloudLibraryItem]
        }
    }

    private enum SyncError: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "Cloud collection synchronization returned an invalid response." }
    }
}

private extension DecodingError {
    var diagnosticDescription: String {
        switch self {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "Unable to decode the cloud response at \(path.isEmpty ? "<root>" : path): \(context.debugDescription)"
        @unknown default:
            return localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
