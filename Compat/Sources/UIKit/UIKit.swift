// Stands in for the system UIKit module on Android. The game's presentation
// files import UIKit almost entirely for UIColor, which SpriteKitShim vends;
// anything else they reach for will fail here, loudly, which is the point.
@_exported import SpriteKitShim

// As Apple's UIKit does.
@_exported import simd

// On Apple, `URLSession` is Foundation's; corelibs keeps it in a module of
// its own. The game's files that talk to the Level Designer's server
// (`LevelShare`) import UIKit and Foundation, so the networking half comes
// in here, where Apple's import of UIKit would bring all of Foundation.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
