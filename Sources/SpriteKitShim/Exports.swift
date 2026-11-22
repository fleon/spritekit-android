#if !SPRITEKIT_SHIM && canImport(SpriteKit)

// On Apple platforms the shim is a passthrough: importing SpriteKitShim is
// importing SpriteKit, CoreGraphics and UIKit, as the shim stands in for all
// three on Android. Every other file here is `SPRITEKIT_SHIM`, so there is
// only ever one implementation in the app on iPhone, iPad, Apple TV and the
// Mac, and `import SpriteKitShim` is all a file that builds on both needs.
@_exported import SpriteKit
@_exported import CoreGraphics
#if canImport(UIKit)
@_exported import UIKit
#endif

#endif
