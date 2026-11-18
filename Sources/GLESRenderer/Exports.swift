// The rasteriser moved down into the shim when `CGContext` arrived: the
// context is what a game's own drawn textures go through, and it has to be reachable
// from a game file's plain `import UIKit`, which resolves to a target that
// re-exports the shim and nothing else. Keeping it here would have meant
// exporting the whole renderer — batcher, viewport, GL resource cache —
// into the game's own namespace.
//
// So `PathRasteriser` and `PathElement` live in SpriteKitShim now, and this
// re-export means everything that reached them through `import GLESRenderer`
// still does.
@_exported import SpriteKitShim

// The render-scale governor moved into PlatformServices, which Apple builds
// share; the renderer still offers it to everything that imports it.
@_exported import PlatformServices
