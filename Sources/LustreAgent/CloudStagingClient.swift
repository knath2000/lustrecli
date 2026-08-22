import CryptoKit
import Foundation
import LustreCore

public struct CloudStagingClient: Sendable {
    public struct StageStatus: Decodable, Sendable {
        public let stageID: UUID
        public let status: String
        public let progressBytes: Int64
        public let totalBytes: Int64?
        public let failureCode: String?
    }

    private struct Ticket: Decodable {
        let filename: String
        let totalBytes: Int64
        let sha256: String
        let downloadURL: URL
    }

    private let identity: DeviceIdentity
    private let session: URLSession

    public init(identity: DeviceIdentity = DeviceIdentity(), session: URLSession? = nil) {
        self.identity = identity
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func transfer(
        existingStageID: UUID?,
        stagingToken: String,
        directory: URL,
        onStageID: @escaping @Sendable (UUID?) async -> Void,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        let stageID: UUID
        if let existingStageID {
            stageID = existingStageID
        } else {
            let created: StageStatus = try await cloud(path: "api/cloud/v1/stages", method: "POST", body: ["stagingToken": stagingToken])
            stageID = created.stageID
            await onStageID(stageID)
        }
        do {
            var status: StageStatus = try await cloud(path: "api/cloud/v1/stages/\(stageID.uuidString.lowercased())")
            while ["pending", "staging"].contains(status.status) {
                try Task.checkCancellation()
                await onProgress(DownloadProgress(bytesWritten: status.progressBytes, totalBytes: status.totalBytes, phase: .cloudStaging))
                try await Task.sleep(for: .seconds(2))
                status = try await cloud(path: "api/cloud/v1/stages/\(stageID.uuidString.lowercased())")
            }
            guard status.status == "ready" else { throw CloudStagingError.stageFailed(status.failureCode ?? status.status) }
            let output = try await download(stageID: stageID, directory: directory, onProgress: onProgress)
            try await complete(stageID)
            await onStageID(nil)
            return output
        } catch is CancellationError {
            try? await cancel(stageID)
            await onStageID(nil)
            throw CancellationError()
        } catch {
            try? await cancel(stageID)
            await onStageID(nil)
            throw error
        }
    }

    public func cancel(_ stageID: UUID) async throws {
        let _: EmptyResponse = try await cloud(path: "api/cloud/v1/stages/\(stageID.uuidString.lowercased())", method: "DELETE")
    }

    private func complete(_ stageID: UUID) async throws {
        let _: EmptyResponse = try await cloud(path: "api/cloud/v1/stages/\(stageID.uuidString.lowercased())/complete", method: "POST")
    }

    private func download(stageID: UUID, directory: URL, onProgress: @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ticket: Ticket = try await cloud(path: "api/cloud/v1/stages/\(stageID.uuidString.lowercased())/ticket", method: "POST")
        let destination = uniqueDestination(directory: directory, filename: ticket.filename)
        let partial = destination.appendingPathExtension("part")
        defer {
            if !FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.removeItem(at: partial) }
        }
        for attempt in 0..<3 {
            do {
                try await append(ticket: ticket, partial: partial, onProgress: onProgress)
                let size = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
                guard size?.int64Value == ticket.totalBytes, try sha256(partial) == ticket.sha256.lowercased() else { throw CloudStagingError.checksumMismatch }
                try FileManager.default.moveItem(at: partial, to: destination)
                return destination
            } catch {
                if error is CancellationError { throw error }
                guard attempt < 2 else { throw error }
                ticket = try await cloud(path: "api/cloud/v1/stages/\(stageID.uuidString.lowercased())/ticket", method: "POST")
            }
        }
        throw CloudStagingError.deliveryFailed
    }

    private func append(ticket: Ticket, partial: URL, onProgress: @escaping @Sendable (DownloadProgress) async -> Void) async throws {
        var existing = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        if existing > ticket.totalBytes {
            try? FileManager.default.removeItem(at: partial)
            existing = 0
        }
        var request = URLRequest(url: ticket.downloadURL)
        request.timeoutInterval = 60
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw CloudStagingError.deliveryFailed }
        if existing > 0 && http.statusCode == 206 {
            guard http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(existing)-") == true else {
                throw CloudStagingError.deliveryFailed
            }
        }
        if existing > 0 && http.statusCode != 206 { try? FileManager.default.removeItem(at: partial) }
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = try handle.offset()
        var buffer = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await onProgress(DownloadProgress(bytesWritten: Int64(written), totalBytes: ticket.totalBytes, phase: .downloading))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += UInt64(buffer.count)
            await onProgress(DownloadProgress(bytesWritten: Int64(written), totalBytes: ticket.totalBytes, phase: .downloading))
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func uniqueDestination(directory: URL, filename: String) -> URL {
        let clean = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        let base = directory.appending(path: clean.isEmpty ? "Lustre Video.mp4" : clean)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        for index in 2...999 {
            let candidate = directory.appending(path: "\(stem) \(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appending(path: "\(stem) \(UUID().uuidString).\(ext)")
    }

    private func cloud<T: Decodable>(path: String, method: String = "GET", body: [String: String]? = nil) async throws -> T {
        guard let enrollment = try DeviceEnrollmentStore.load(), let origin = URL(string: enrollment.cloudOrigin) else { throw CloudStagingError.notEnrolled }
        let enrollmentClient = try CloudEnrollmentClient(origin: origin)
        let challenge = try await enrollmentClient.deviceSessionChallenge(deviceID: enrollment.deviceID)
        let envelope = try CloudDeviceProtocol.envelope(purpose: "session", audience: enrollment.cloudOrigin, subjectID: enrollment.deviceID.uuidString.lowercased(), nonce: challenge.nonce, thumbprint: try identity.thumbprint(), expiresAt: challenge.expiresAt)
        let completion = try await enrollmentClient.completeDeviceSession(deviceID: enrollment.deviceID, challengeID: challenge.challengeID, signature: try identity.sign(envelope))
        var request = URLRequest(url: origin.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(completion.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw CloudStagingError.requestFailed }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct EmptyResponse: Decodable {}
}

public enum CloudStagingError: Error, LocalizedError, Sendable {
    case notEnrolled, requestFailed, deliveryFailed, checksumMismatch
    case stageFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notEnrolled: "Lustre Cloud is not paired."
        case .requestFailed: "Cloud staging is unavailable."
        case .deliveryFailed: "The staged MP4 could not be delivered."
        case .checksumMismatch: "The staged MP4 failed checksum verification."
        case .stageFailed(let code): "Cloud staging failed (\(code))."
        }
    }
}
