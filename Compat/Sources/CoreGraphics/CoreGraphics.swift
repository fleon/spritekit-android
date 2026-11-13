// Stands in for the system CoreGraphics module on Android, where the game's
// geometry (CGAffineTransform, CGVector, CGPoint.applying) comes from the
// shim instead. Foundation already vends CGFloat, CGPoint, CGSize and CGRect
// there, so only the gaps are defined.
@_exported import SpriteKitShim
