// Stands in for CryptoKit on Android, as far as `SHA256` goes: a game that
// fingerprints its data with it gets the same digests on both platforms.
// PlatformShim's is plain Swift and tested against CryptoKit's on the Mac.
@_exported import PlatformShim

// A file importing CryptoKit may also fetch with `URLSession`, which is
// Foundation's on Apple and a module of its own in corelibs. If CryptoKit is
// its only other import, the networking half has to come in here, as UIKit's
// stand-in brings it to the files importing UIKit.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
