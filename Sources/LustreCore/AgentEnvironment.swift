import Foundation
import Security

public enum AgentPaths {
    public static let applicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "LustreStudioAgent", directoryHint: .isDirectory)
    }()

    public static let database = applicationSupport.appending(path: "jobs.sqlite3")
    public static let endpoint = applicationSupport.appending(path: "endpoint.json")
    public static let remoteDestinations = applicationSupport.appending(path: "remote-destinations.json")
    public static let googleDriveDestinations = applicationSupport.appending(path: "google-drive-destinations.json")
    public static let localDownloadConfiguration = applicationSupport.appending(path: "local-download-folder.json")
    public static let loopbackPort: UInt16 = 63406
    public static let downloads: URL = {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Lustre", directoryHint: .isDirectory)
    }()

    public static func prepare() throws {
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    }
}

public struct AgentEndpoint: Codable, Sendable {
    public let port: UInt16

    public init(port: UInt16) {
        self.port = port
    }
}

public enum KeychainTokenStore {
    private static let service = "com.pmvdl.lustre-agent"
    private static let account = "local-api-token"

    public static func token() throws -> String {
        if let token = try read() { return token }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TokenError.unavailable
        }
        let token = Data(bytes).base64EncodedString()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw TokenError.unavailable
        }
        return token
    }

    private static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw TokenError.unavailable
        }
        return token
    }

    public enum TokenError: Error, LocalizedError {
        case unavailable
        public var errorDescription: String? { "The local API token could not be read from Keychain." }
    }
}
