import Foundation
import Security

public struct WebDAVDestinationProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let username: String
    public let remotePath: String
    public let allowInvalidCertificate: Bool

    public init(id: UUID = UUID(), name: String, baseURL: URL, username: String, remotePath: String, allowInvalidCertificate: Bool = false) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !normalizedUsername.isEmpty else {
            throw RemoteDestinationError.invalidConfiguration
        }
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host?.isEmpty == false,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil else {
            throw RemoteDestinationError.invalidConfiguration
        }
        let normalizedPath = try Self.normalizedRemotePath(remotePath)
        self.id = id
        self.name = normalizedName
        self.baseURL = baseURL
        self.username = normalizedUsername
        self.remotePath = normalizedPath
        self.allowInvalidCertificate = allowInvalidCertificate
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, username, remotePath, allowInvalidCertificate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            baseURL: container.decode(URL.self, forKey: .baseURL),
            username: container.decode(String.self, forKey: .username),
            remotePath: container.decode(String.self, forKey: .remotePath),
            allowInvalidCertificate: try container.decodeIfPresent(Bool.self, forKey: .allowInvalidCertificate) ?? false
        )
    }

    private static func normalizedRemotePath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? "/" : trimmed
        guard path.hasPrefix("/") else { throw RemoteDestinationError.invalidConfiguration }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".") && !components.contains("..") else {
            throw RemoteDestinationError.invalidConfiguration
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}

public struct WebDAVDestinationRequest: Codable, Sendable {
    public let name: String
    public let baseURL: URL
    public let username: String
    public let password: String
    public let remotePath: String
    public let allowInvalidCertificate: Bool

    public init(name: String, baseURL: URL, username: String, password: String, remotePath: String, allowInvalidCertificate: Bool = false) {
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.remotePath = remotePath
        self.allowInvalidCertificate = allowInvalidCertificate
    }
}

public struct RemoteDestinationTestResult: Codable, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum RemoteDestination {
    private static let webDAVPrefix = "webdav:"

    public static func webDAV(_ id: UUID) -> String {
        webDAVPrefix + id.uuidString.lowercased()
    }

    public static func webDAVProfileID(from destination: String) -> UUID? {
        guard destination.lowercased().hasPrefix(webDAVPrefix) else { return nil }
        return UUID(uuidString: String(destination.dropFirst(webDAVPrefix.count)))
    }
}

public enum RemoteDestinationError: Error, LocalizedError {
    case invalidConfiguration
    case missingCredentials
    case notFound
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "WebDAV destinations require an HTTPS URL, username, and an absolute remote path without traversal."
        case .missingCredentials: "The saved WebDAV password is unavailable. Update the destination settings."
        case .notFound: "The selected remote destination no longer exists."
        case .unavailable: "The remote destination settings could not be stored securely."
        }
    }
}

public actor RemoteDestinationProfileStore {
    private let fileURL: URL
    private var profiles: [UUID: WebDAVDestinationProfile]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([WebDAVDestinationProfile].self, from: data)
            self.profiles = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            self.profiles = [:]
        }
    }

    public func all() -> [WebDAVDestinationProfile] {
        profiles.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func profile(id: UUID) -> WebDAVDestinationProfile? {
        profiles[id]
    }

    public func save(_ request: WebDAVDestinationRequest, id: UUID = UUID()) throws -> WebDAVDestinationProfile {
        let profile = try WebDAVDestinationProfile(
            id: id,
            name: request.name,
            baseURL: request.baseURL,
            username: request.username,
            remotePath: request.remotePath,
            allowInvalidCertificate: request.allowInvalidCertificate
        )
        profiles[id] = profile
        try persist()
        return profile
    }

    public func remove(id: UUID) throws {
        guard profiles.removeValue(forKey: id) != nil else { throw RemoteDestinationError.notFound }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(all()).write(to: fileURL, options: .atomic)
    }
}

public protocol RemoteDestinationSecretStore: Sendable {
    func password(for profileID: UUID) throws -> String?
    func save(password: String, for profileID: UUID) throws
    func remove(profileID: UUID) throws
}

public final class KeychainRemoteDestinationSecretStore: RemoteDestinationSecretStore, @unchecked Sendable {
    private let service = "com.pmvdl.lustre-agent.remote-destinations"

    public init() {}

    public func password(for profileID: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw RemoteDestinationError.unavailable
        }
        return password
    }

    public func save(password: String, for profileID: UUID) throws {
        guard !password.isEmpty else { throw RemoteDestinationError.invalidConfiguration }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var create = query
            attributes.forEach { create[$0.key] = $0.value }
            guard SecItemAdd(create as CFDictionary, nil) == errSecSuccess else {
                throw RemoteDestinationError.unavailable
            }
        } else if status != errSecSuccess {
            throw RemoteDestinationError.unavailable
        }
    }

    public func remove(profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteDestinationError.unavailable
        }
    }
}
