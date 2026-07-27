import Darwin
import Foundation
import Security

public enum AllPornStreamVerificationError: Error, LocalizedError, Sendable {
    case helperUnavailable
    case helperFailed
    case verificationRequired
    case invalidResponse
    case storageUnavailable
    case timeout

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable: "The AllPornStream verification helper is unavailable."
        case .helperFailed: "AllPornStream verification did not complete."
        case .verificationRequired: "AllPornStream requires local verification on this Mac."
        case .invalidResponse: "AllPornStream returned an invalid rendered page."
        case .storageUnavailable: "AllPornStream clearance cookies could not be stored in Keychain."
        case .timeout: "AllPornStream verification timed out."
        }
    }
}

public enum AllPornStreamPolicy {
    public static let maximumCookies = 8
    public static let maximumCookieBytes = 16 * 1024
    public static let maximumRenderedHTMLBytes = 2 * 1024 * 1024
    private static let cookieNames = Set(["cf_clearance", "__cf_bm"])

    public static func isTrusted(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased()
        else { return false }
        return host == "allpornstream.com" || host == "www.allpornstream.com"
    }

    public static func sanitize(_ cookies: [PornHubCookieRecord], now: Date = .now) throws -> [PornHubCookieRecord] {
        guard cookies.count <= 512 else { throw AllPornStreamVerificationError.invalidResponse }
        var total = 0
        var identities = Set<String>()
        let result = try cookies.compactMap { cookie -> PornHubCookieRecord? in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard cookieNames.contains(cookie.name), cookie.secure,
                  domain == "allpornstream.com" || domain.hasSuffix(".allpornstream.com"),
                  cookie.expiresAt.map({ $0 > now }) ?? true,
                  cookie.path.hasPrefix("/"),
                  !cookie.value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ";" || $0 == "\0" })
            else { return nil }
            total += cookie.name.utf8.count + cookie.value.utf8.count + domain.utf8.count + cookie.path.utf8.count
            guard total <= maximumCookieBytes,
                  identities.insert("\(cookie.name)|\(domain)|\(cookie.path)").inserted
            else { throw AllPornStreamVerificationError.invalidResponse }
            return PornHubCookieRecord(name: cookie.name, value: cookie.value, domain: domain, path: cookie.path, expiresAt: cookie.expiresAt, secure: true, hostOnly: cookie.hostOnly)
        }
        guard result.count <= maximumCookies else { throw AllPornStreamVerificationError.invalidResponse }
        return result
    }
}

public final class AllPornStreamCookieStore: @unchecked Sendable {
    private static let service = "com.pmvdl.lustre-agent"
    private static let account = "allpornstream.clearance.v1"

    public init() {}

    public func load() throws -> [PornHubCookieRecord] {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: Self.account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else { throw AllPornStreamVerificationError.storageUnavailable }
        return try AllPornStreamPolicy.sanitize(JSONDecoder().decode([PornHubCookieRecord].self, from: data))
    }

    public func save(_ cookies: [PornHubCookieRecord]) throws {
        let data = try JSONEncoder().encode(AllPornStreamPolicy.sanitize(cookies))
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: Self.account]
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AllPornStreamVerificationError.storageUnavailable }
        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AllPornStreamVerificationError.storageUnavailable }
    }
}

public struct AllPornStreamWebKitHelper: Sendable {
    private let executableURL: URL?

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    public func verify() async throws {
        let output = try await run(arguments: ["allpornstream-verify"], timeout: 15 * 60, outputCap: 64)
        guard String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "verified" else {
            throw AllPornStreamVerificationError.helperFailed
        }
    }

    public func render(url: URL) async throws -> String {
        guard AllPornStreamPolicy.isTrusted(url) else { throw AllPornStreamVerificationError.invalidResponse }
        let encodedURL = Data(url.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let output = try await run(arguments: ["allpornstream-render", encodedURL], timeout: 45, outputCap: ((AllPornStreamPolicy.maximumRenderedHTMLBytes + 2) / 3) * 4 + 16)
        let token = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if token == "verification-required" { throw AllPornStreamVerificationError.verificationRequired }
        guard let data = Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").paddingBase64),
              data.count <= AllPornStreamPolicy.maximumRenderedHTMLBytes,
              let html = String(data: data, encoding: .utf8)
        else { throw AllPornStreamVerificationError.invalidResponse }
        return html
    }

    private func run(arguments: [String], timeout: TimeInterval, outputCap: Int) async throws -> Data {
        let current = executableURL ?? Bundle.main.executableURL
        guard let current else { throw AllPornStreamVerificationError.helperUnavailable }
        let executable = try PornHubAuthHelper.validatedExecutable(runningAgent: current)
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                defer { try? stdout.fileHandleForReading.close() }
                var data = Data()
                while true {
                    let next = try stdout.fileHandleForReading.read(upToCount: min(64 * 1024, outputCap - data.count + 1)) ?? Data()
                    if next.isEmpty { break }
                    data.append(next)
                    if data.count > outputCap { throw AllPornStreamVerificationError.invalidResponse }
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw AllPornStreamVerificationError.helperFailed }
                return data
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AllPornStreamVerificationError.timeout
            }
            defer {
                group.cancelAll()
                if process.isRunning { process.terminate() }
            }
            guard let result = try await group.next() else { throw AllPornStreamVerificationError.helperFailed }
            return result
        }
    }
}

private extension String {
    var paddingBase64: String {
        padding(toLength: count + (4 - count % 4) % 4, withPad: "=", startingAt: 0)
    }
}
