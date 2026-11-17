// On Android there is no system SpriteKit, so a module of this name lets the
// game's own files compile with `import SpriteKit` untouched — no edits to
// its presentation files, not even to their imports.
@_exported import SpriteKitShim

// Apple's SpriteKit re-exports `simd` (SKWarpGeometry and the matrix types
// are built on it), which is why files here use `simd_normalize` with no
// `import simd` of their own. Matching that keeps those compiling untouched.
@_exported import simd
