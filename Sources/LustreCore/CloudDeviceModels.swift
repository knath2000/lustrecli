import Foundation

public enum CloudDeviceProtocol {
    public static let version = 1
    public static let audienceEnvironment = "LUSTRE_CLOUD_ORIGIN"

    public static func normalizePairingCode(_ raw: String) throws -> String {
        let code = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard code.count == 20, code.unicodeScalars.allSatisfy(allowed.contains) else { throw CloudDeviceError.invalidPairingCode }
        return code
    }

    public static func envelope(purpose: String, audience: String, subjectID: String, nonce: String, thumbprint: String, expiresAt: Date) throws -> Data {
        guard let nonceData = Data(base64Encoded: nonce) else { throw CloudDeviceError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fields: [Data] = ["LUSTRE-CLOUD-DEVICE-V1", "1", purpose, audience, subjectID].map { Data($0.utf8) } + [nonceData, Data(thumbprint.utf8), Data(formatter.string(from: expiresAt).utf8)]
        return fields.reduce(into: Data()) { result, value in
            var length = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(value)
        }
    }
}

public enum CloudDeviceError: Error, LocalizedError, Sendable {
    case invalidPairingCode, invalidResponse, invalidOrigin, requestFailed, keychainFailure, challengeConsumed, deviceRevoked, server(code: String)
    public var errorDescription: String? {
        switch self {
        case .invalidPairingCode: "The pairing code is invalid."
        case .invalidResponse: "Lustre Cloud returned an invalid response."
        case .invalidOrigin: "The configured Lustre Cloud origin is invalid."
        case .requestFailed: "The Lustre Cloud request failed."
        case .keychainFailure: "The permanent Lustre device key could not be accessed in Keychain."
        case .challengeConsumed: "The pairing challenge was already used or expired."
        case .deviceRevoked: "This device has been revoked in Lustre Cloud."
        case let .server(code): "Lustre Cloud rejected the request (\(code))."
        }
    }
}

public struct CloudErrorResponse: Decodable, Sendable {
    public struct Detail: Decodable, Sendable { public let code: String }
    public let error: Detail
}

public struct CloudEnrollmentChallenge: Codable, Sendable { public let protocolVersion: Int; public let enrollmentID: UUID; public let nonce: String; public let expiresAt: Date; public init(protocolVersion: Int, enrollmentID: UUID, nonce: String, expiresAt: Date) { self.protocolVersion = protocolVersion; self.enrollmentID = enrollmentID; self.nonce = nonce; self.expiresAt = expiresAt } }
public struct CloudEnrollmentCompletion: Codable, Sendable { public let protocolVersion: Int; public let deviceID: UUID; public let cloudOrigin: String; public let enrolledAt: Date; public init(protocolVersion: Int, deviceID: UUID, cloudOrigin: String, enrolledAt: Date) { self.protocolVersion = protocolVersion; self.deviceID = deviceID; self.cloudOrigin = cloudOrigin; self.enrolledAt = enrolledAt } }
public struct CloudSessionChallenge: Codable, Sendable { public let protocolVersion: Int; public let challengeID: UUID; public let nonce: String; public let expiresAt: Date; public init(protocolVersion: Int, challengeID: UUID, nonce: String, expiresAt: Date) { self.protocolVersion = protocolVersion; self.challengeID = challengeID; self.nonce = nonce; self.expiresAt = expiresAt } }
public struct CloudSessionCompletion: Codable, Sendable { public let protocolVersion: Int; public let accessToken: String; public let expiresInSeconds: Int; public let gatewayOrigin: String?; public init(protocolVersion: Int, accessToken: String, expiresInSeconds: Int, gatewayOrigin: String? = nil) { self.protocolVersion = protocolVersion; self.accessToken = accessToken; self.expiresInSeconds = expiresInSeconds; self.gatewayOrigin = gatewayOrigin } }
public struct CloudEnrollmentMetadata: Codable, Sendable { public let cloudOrigin: String; public let deviceID: UUID; public let deviceName: String; public let enrolledAt: Date; public init(cloudOrigin: String, deviceID: UUID, deviceName: String, enrolledAt: Date) { self.cloudOrigin = cloudOrigin; self.deviceID = deviceID; self.deviceName = deviceName; self.enrolledAt = enrolledAt } }
