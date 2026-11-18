// Stands in for Security on Android, as far as encrypting to an RSA public
// key goes: `SecKeyCreateWithData` for a PKCS #1 public key and
// `SecKeyCreateEncryptedData` with `.rsaEncryptionPKCS1`, over PlatformShim's
// `RSAPublicKey`. What a game sends its server encrypted reads the same as
// what its iOS build sends. Anything else (private keys, signing, the
// keychain) answers nil. The error out-parameters are taken for the
// signatures' sake and left as they are: a nil is the whole answer.
import Foundation
@_exported import PlatformShim
import SpriteKitShim

public typealias CFData = Data

/// A key `SecKeyCreateWithData` made: an RSA public key.
public final class SecKey: @unchecked Sendable {
    let rsa: RSAPublicKey

    init(rsa: RSAPublicKey) { self.rsa = rsa }
}

/// Security's algorithm names. Only `.rsaEncryptionPKCS1` encrypts here.
public struct SecKeyAlgorithm: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let rsaEncryptionPKCS1 = SecKeyAlgorithm(rawValue: "algid:encrypt:RSA:PKCS1")
}

// Security's own strings for the attributes a key is made with.
public let kSecAttrKeyType: CFString = "type"
public let kSecAttrKeyTypeRSA: CFString = "42"
public let kSecAttrKeyClass: CFString = "kcls"
public let kSecAttrKeyClassPublic: CFString = "0"
public let kSecAttrKeyClassPrivate: CFString = "1"

/// An RSA public key from its PKCS #1 DER; nil for any other type or class.
public func SecKeyCreateWithData(
    _ keyData: CFData,
    _ attributes: CFDictionary,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> SecKey? {
    guard attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeRSA,
          attributes[kSecAttrKeyClass] as? String == kSecAttrKeyClassPublic,
          let rsa = RSAPublicKey(pkcs1: keyData)
    else { return nil }
    return SecKey(rsa: rsa)
}

/// `plaintext` encrypted to `key` with PKCS #1 v1.5 padding; nil for another
/// algorithm or a plaintext longer than the key's block less 11 bytes.
public func SecKeyCreateEncryptedData(
    _ key: SecKey,
    _ algorithm: SecKeyAlgorithm,
    _ plaintext: CFData,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> CFData? {
    guard algorithm == .rsaEncryptionPKCS1 else { return nil }
    return key.rsa.encryptPKCS1(plaintext)
}

/// The block size in bytes, as Security reports it for an RSA key.
public func SecKeyGetBlockSize(_ key: SecKey) -> Int { key.rsa.blockSize }
