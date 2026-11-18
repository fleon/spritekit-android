#if canImport(Security)
import Foundation
import PlatformShim
import Security
import Testing

/// PKCS #1 v1.5 encryption to a public key, checked by decrypting with
/// Security's private key: what the shim writes, iOS reads.
@Suite struct RSAPublicKeyTests {
    private static func keyPair(bits: Int) throws -> (SecKey, Data) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)
        return (key, der)
    }

    private static func decrypt(_ ciphertext: Data, with key: SecKey) -> Data? {
        SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, ciphertext as CFData, nil) as Data?
    }

    @Test(arguments: [1024, 2048])
    func securityDecryptsWhatItEncrypts(bits: Int) throws {
        let (privateKey, der) = try Self.keyPair(bits: bits)
        let key = try #require(RSAPublicKey(pkcs1: der))
        #expect(key.blockSize == bits / 8)
        for message in [Data(), Data("{\"displayName\":\"Ünïcode ✓\",\"uid\":\"G:123\"}".utf8), Data(repeating: 0xff, count: bits / 8 - 11)] {
            let ciphertext = try #require(key.encryptPKCS1(message))
            #expect(ciphertext.count == bits / 8)
            #expect(Self.decrypt(ciphertext, with: privateKey) == message)
        }
    }

    @Test func paddingIsTwoNonZeroRandomAndAZero() throws {
        let (privateKey, der) = try Self.keyPair(bits: 1024)
        let key = try #require(RSAPublicKey(pkcs1: der))
        // A generator that gives zeros first: each must be redrawn.
        var draws = 0
        let ciphertext = try #require(key.encryptPKCS1(Data("hi".utf8)) { bytes in
            for index in bytes.indices {
                draws += 1
                bytes[index] = draws % 3 == 0 ? 0 : UInt8(truncatingIfNeeded: draws)
            }
        })
        let block = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionRaw, ciphertext as CFData, nil) as Data?)
        let bytes = [UInt8](block)
        #expect(bytes.count == 128)
        #expect(bytes[0] == 0 && bytes[1] == 2)
        #expect(bytes[2 ..< 125].allSatisfy { $0 != 0 })
        #expect(bytes[125] == 0 && Array(bytes[126...]) == Array("hi".utf8))
    }

    @Test func tooLongAMessageIsRefused() throws {
        let (_, der) = try Self.keyPair(bits: 1024)
        let key = try #require(RSAPublicKey(pkcs1: der))
        #expect(key.encryptPKCS1(Data(count: 118)) == nil)
    }

    @Test func onlyAPKCS1PublicKeyIsTaken() throws {
        let (_, der) = try Self.keyPair(bits: 1024)
        // The same key as a SubjectPublicKeyInfo: Security wants PKCS #1 here.
        let header: [UInt8] = [0x30, 0x81, 0x9f, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x81, 0x8d, 0x00]
        #expect(RSAPublicKey(pkcs1: Data(header) + der) == nil)
        #expect(RSAPublicKey(pkcs1: Data()) == nil)
        #expect(RSAPublicKey(pkcs1: der.dropLast()) == nil)
    }
}
#endif
