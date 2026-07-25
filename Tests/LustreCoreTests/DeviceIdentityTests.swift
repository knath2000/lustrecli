import CryptoKit
import Security
import XCTest
@testable import LustreAgent
@testable import LustreCore

final class DeviceIdentityTests: XCTestCase {
    func testIsolatedKeychainIdentityExportsStablePublicKeyAndSignsDER() throws {
        let tag = Data("com.pmvdl.lustre-agent.tests.\(UUID().uuidString)".utf8)
        let identity = DeviceIdentity(tag: tag)
        defer { try? identity.deleteForTesting() }

        let firstPublicKey = try identity.publicKey()
        let secondPublicKey = try identity.publicKey()
        XCTAssertEqual(firstPublicKey, secondPublicKey)
        XCTAssertEqual(firstPublicKey.count, 65)
        XCTAssertEqual(firstPublicKey.first, 4)
        XCTAssertEqual(try identity.thumbprint(), try identity.thumbprint())

        let envelope = try CloudDeviceProtocol.envelope(purpose: "enrollment", audience: "https://app.example", subjectID: "device", nonce: Data(repeating: 7, count: 32).base64EncodedString(), thumbprint: try identity.thumbprint(), expiresAt: Date(timeIntervalSince1970: 1_700_000_000))
        let signature = try identity.sign(envelope)
        let publicAttributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 256]
        guard let publicKey = SecKeyCreateWithData(firstPublicKey as CFData, publicAttributes as CFDictionary, nil) else { return XCTFail("Unable to reconstruct the exported public key.") }
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, envelope as CFData, signature as CFData, nil))

        var changed = envelope
        changed[changed.startIndex] ^= 1
        XCTAssertFalse(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, changed as CFData, signature as CFData, nil))
    }
}
