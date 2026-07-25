import Foundation
import LustreCore

public final class CloudEnrollmentClient: NSObject, @unchecked Sendable {
    private let origin: URL
    private let session: URLSession
    public init(origin: URL, session: URLSession? = nil) throws {
        guard origin.scheme == "https" || (origin.scheme == "http" && origin.host == "localhost"), origin.user == nil, origin.password == nil, origin.host != nil else { throw CloudDeviceError.invalidOrigin }
        self.origin = origin
        if let session { self.session = session } else { let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.httpCookieStorage = nil; self.session = URLSession(configuration: config, delegate: RedirectBlocker(origin: origin), delegateQueue: nil) }
    }
    public func beginEnrollment(code: String, publicKey: Data, name: String, version: String) async throws -> CloudEnrollmentChallenge {
        try await request("device-enrollments/challenge", body: ["protocolVersion": 1, "pairingCode": try CloudDeviceProtocol.normalizePairingCode(code), "publicKey": publicKey.base64EncodedString(), "displayName": name, "platform": "macos", "agentVersion": version])
    }
    public func completeEnrollment(id: UUID, signature: Data) async throws -> CloudEnrollmentCompletion { try await request("device-enrollments/complete", body: ["protocolVersion": 1, "enrollmentID": id.uuidString, "signature": signature.base64EncodedString()]) }
    public func deviceSessionChallenge(deviceID: UUID) async throws -> CloudSessionChallenge { try await request("device-sessions/challenge", body: ["protocolVersion": 1, "deviceID": deviceID.uuidString.lowercased()]) }
    public func completeDeviceSession(deviceID: UUID, challengeID: UUID, signature: Data) async throws -> CloudSessionCompletion { try await request("device-sessions/complete", body: ["protocolVersion": 1, "deviceID": deviceID.uuidString.lowercased(), "challengeID": challengeID.uuidString.lowercased(), "signature": signature.base64EncodedString()]) }
    private func request<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: "api/cloud/v1/\(path)", relativeTo: origin) else { throw CloudDeviceError.invalidOrigin }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body); guard request.httpBody!.count <= 16_384 else { throw CloudDeviceError.requestFailed }
        let (data, response) = try await session.data(for: request); guard data.count <= 16_384, let http = response as? HTTPURLResponse else { throw CloudDeviceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(CloudErrorResponse.self, from: data) {
                if error.error.code == "challenge_consumed" || error.error.code == "challenge_expired" { throw CloudDeviceError.challengeConsumed }
                if error.error.code == "device_revoked" { throw CloudDeviceError.deviceRevoked }
                throw CloudDeviceError.server(code: error.error.code)
            }
            throw CloudDeviceError.requestFailed
        }
        return try JSONDecoder.cloud.decode(T.self, from: data)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate { let origin: URL; init(origin: URL) { self.origin = origin }; func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) } }
