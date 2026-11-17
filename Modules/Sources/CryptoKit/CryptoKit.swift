// Stands in for CryptoKit on Android, which the game imports for one thing:
// `SHA256`, a Level Designer board's fingerprint and a level's in the feed
// (`DesignerStore`, `LevelFingerprint`). PlatformShim's is plain Swift and
// tested against CryptoKit's on the Mac.
@_exported import PlatformShim

// `DesignerFeed` fetches the level feed with `URLSession`, which is
// Foundation's on Apple and a module of its own in corelibs. Its only other
// import is this one, so the networking half comes in here, as UIKit's
// stand-in brings it to `LevelShare`.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
