// Stands in for the system CoreText module on Android.
//
// Nothing real is behind this yet: text shaping is the one part of the layer
// with no shortcut (HarfBuzz + FreeType). Files that only mention CoreText in
// an import compile; anything that calls into it will not, deliberately.
@_exported import SpriteKitShim
