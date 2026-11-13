#if !SPRITEKIT_SHIM && canImport(SpriteKit)

// On Apple platforms the shim is a passthrough: importing SpriteKitShim is
// importing SpriteKit. Nothing below this line is compiled there, so there is
// only ever one implementation in the app on iOS, Mac and Apple TV.
@_exported import SpriteKit
@_exported import CoreGraphics

#endif
