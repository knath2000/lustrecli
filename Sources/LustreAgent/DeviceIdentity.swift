import Foundation
import Security
import CryptoKit
import LustreCore

public final class DeviceIdentity: @unchecked Sendable {
    private let tag: Data
    public init(tag: Data = Data("com.pmvdl.lustre-agent.cloud-device-p256-v1".utf8)) { self.tag = tag }

    private func privateKey() throws -> SecKey {
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag, kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var existing: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &existing)
        if status == errSecSuccess, let key = existing as! SecKey? { return key }
        guard status == errSecItemNotFound else { throw CloudDeviceError.keychainFailure }
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256, kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw CloudDeviceError.keychainFailure }
        return key
    }

    public func publicKey() throws -> Data {
        let privateKey = try privateKey()
        guard let key = SecKeyCopyPublicKey(privateKey) else { throw CloudDeviceError.keychainFailure }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw CloudDeviceError.keychainFailure }
        guard data.count == 65, data.first == 4 else { throw CloudDeviceError.invalidResponse }; return data
    }
    public func thumbprint() throws -> String { Data(SHA256.hash(data: try publicKey())).base64URLEncodedString() }
    public func sign(_ envelope: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(try privateKey(), .ecdsaSignatureMessageX962SHA256, envelope as CFData, &error) as Data? else { throw CloudDeviceError.keychainFailure }
        return signature
    }

    func deleteForTesting() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag, kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudDeviceError.keychainFailure }
    }
}

private extension Data {
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
