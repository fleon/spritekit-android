# Android

A prototype of the SpriteKit compatibility layer for an Android port, plus
proof that the game's own presentation sources compile against it unchanged.

Nothing here is wired into the app: `Switchlings.xcodeproj` does not reference
it, and the iOS, Mac and Apple TV builds are untouched.

## Why a shim rather than an engine

The rules port almost for free — all 15 files in `Source/Game/Models` plus
`LocalizedString.swift` (5,378 lines) cross-compile with about 60 lines of
shims, the only Apple surface being `OSAllocatedUnfairLock`, `CGFloat`, and
the three Utils seams (`ICloudSyncManager`, `Localization`,
`LevelFingerprint`). The port is therefore entirely about the other ~60,000
lines, which are SpriteKit.

Wrapping a C++ engine (Axmol, Cocos2d-x) was considered and rejected: Swift
cannot override a C++ virtual method, and the game declares **104 subclasses**
of SpriteKit types (91 of `SKNode`, 8 of `SKScene`, 5 of `SKSpriteNode`).
Every one of them would need a hand-written C++ subclass bridging back into
Swift. A Swift-native layer keeps them compiling as they are.

The surface is also narrower than it looks. Across all of `Source`:

| | uses |
|---|---|
| `SKNode` / `SKSpriteNode` / `SKTexture` | 537 / 378 / 106 |
| `SKUniform` / `SKShader` | 446 / 107 |
| `SKAction` | 89, but only **16 distinct methods** |
| `SKLabelNode` / `SKShapeNode` | 22 / 16 |
| `SKCropNode` / `SKEffectNode` / `SKWarpGeometry` | 20 / 11 / 9 |

And the game's own `SKAction` helpers (`animate`, `animateSteadily`,
`pingPong`, `zoom` in `EasingFunctions.swift`) are built from just four
primitives: `customAction`, `run`, `sequence` and `repeatForever`.

## Layout

```
Android/
  Package.swift          SpriteKitShim + tests. Builds on macOS and Android.
  Sources/SpriteKitShim/ The layer.
  Tests/                 36 tests, no device or GL context needed.
  Assets/                The packed art. Generated, gitignored, 101 MB.
  Compat/                Android-only. Do not build on a Mac.
    Sources/SpriteKit/   Targets that exist only to own a module name,
    Sources/UIKit/       so the game's imports resolve without an edit.
    Sources/CoreText/
    Sources/CoreGraphics/
    Sources/GameCompat/  Symlinks into Source/ — real files, not copies.
```

`Compat` is a separate package because a target named `CoreGraphics` cycles
with the system module when built on macOS. Keeping it out means the shim
itself stays host-testable.

## How the same code compiles on both platforms

`SpriteKitShim` is a passthrough on Apple:

```swift
#if !SPRITEKIT_SHIM && canImport(SpriteKit)
@_exported import SpriteKit
#endif
```

and its own implementation otherwise. The `SPRITEKIT_SHIM` flag is defined
unconditionally in these packages so the layer can be developed with a normal
edit–test loop on a Mac; in the app it would be set for Android alone.

The module-name targets are what make "unchanged" literal. A game file keeps
`import SpriteKit`, `import UIKit`, `import CoreGraphics` and `import
CoreText`; on Android no system module answers those names, so these targets
do, and each re-exports the shim. **No file in `Source/` is edited — not even
its imports.**

Apple is detected with `canImport(Darwin)`, not `canImport(CoreGraphics)`,
precisely because this package ships a module by that name.

## What is proven

```
swift build                                             # shim, macOS
swift test                                              # 36 tests, macOS
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple aarch64-unknown-linux-android23    # shim, Android

cd Compat
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple aarch64-unknown-linux-android23    # real game sources
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple x86_64-unknown-linux-android23     # emulator too
```

All five pass. `GameCompat` compiles **4,711 lines of real, unmodified game
source** for Android on both ABIs:

| file | lines |
|---|---|
| `Source/Utils/DesignSystem.swift` | 3,925 |
| `Source/Utils/GeometryHelpers.swift` | 338 |
| `Source/Utils/ArtSlices.swift` | 111 |
| `Source/Utils/EasingFunctions.swift` | 140 |
| `Source/Game/Components/Board/ArrowBadgeNode.swift` | 76 |
| `Source/Game/Models/Direction.swift` | 61 |
| `Source/Game/Components/Board/ArrowTileNode.swift` | 60 |

plus the generated `Source/Utils/ArtSlices.swift`, against 76 lines of stubs
in `Compat/Sources/GameCompat/Stubs.swift`, each one documented and each one a
seam that belongs to a later ring.

`ArrowTileNode` is the useful case: a real `SKNode` subclass that runs a keyed
`pingPong` action built from `customAction` + `sequence` + `repeatForever`,
positions a child, reads ~8 `DesignSystem` constants and uses the `pt`/`sz`/
`rect` helpers. It compiles and its action semantics are covered by tests.

## Art

The Apple build ships 1,608 `@3x` image sets in `Assets.xcassets` (204 MB
with Apple TV's `@2x` renditions) and looks each one up by name through
`txtr(_:)`. Android gets the same pixels, repacked:

```
npm run art -- --android      # Tools/Art/android-art.js → Android/Assets
npm run art:android:check     # 12 checks on the packer and the index
```

`android-art.js` runs from `export-art.js` and takes two things from it: the
`@3x` PNGs the Apple export has already written — so the two platforms ship
the same bytes by construction, not by a parallel renderer that might drift —
and the one manifest that `writeSlices()` turns into `ArtSlices.swift`, so
the 9-slice cap insets, content insets and board anchors reach Android from
the same source. It writes nothing into the catalog, and the Apple export is
byte for byte what it was.

The output is `Android/Assets`: 18 atlas pages of 2048×2048 (the size GLES
3.0 guarantees), 144 whole pages, and `index.json`. Packing is a
bottom-left skyline, tallest first, over a total order on name and size, so
the same input always gives the same pages at the same rects — two runs are
byte for byte identical and a rebuild reads as a diff of the index. Atlas
pages come out 87–97% full.

An image whose longest side is over 512 px takes a page of its own, copied
byte for byte from the catalog's PNG. That is what keeps the tiling backdrop
grounds (the smallest is 1158 px) whole textures that can be sampled with
`GL_REPEAT` and mipped — an atlas slice can be neither. Packed images sit 2 px
apart with their edge pixels extruded into the gap, so a linear tap or a
9-slice stretch at a rect's edge never pulls in a neighbour.

```jsonc
{
 "version": 1,
 "scale": 3,
 "pages": [ { "file": "atlas-000.png", "width": 2048, "height": 2048 },
            { "file": "whole/BackdropReefSeabedSand.png", "width": 1254, "height": 1254, "repeats": true } ],
 "assets": {
  // rect is [x, y, width, height] in page pixels, top left origin;
  // size is [width, height] in points; insets are [top, left, bottom, right].
  "BrickGarden1":         { "page": 7,  "rect": [1822, 246, 192, 240], "size": [64, 80],
                            "caps": [67.2, 0, 4.48, 0] },
  "KerbGardenHorizontal": { "page": 16, "rect": [960, 1106, 217, 116], "size": [72.333, 38.667],
                            "caps": [0, 8.4939, 0, 8.4939], "anchor": [0.125, 0, 0.2283, 0] },
  "ArrowTile":            { "page": 4,  "rect": [850, 1166, 360, 360], "size": [120, 120] }
 }
}
```

`AssetIndex` reads it. `AssetIndex.shared` is set once as the app starts, and
`SKTexture(imageNamed:)` resolves through it, so `size()` reports the art's
own size in points as SpriteKit's does — it used to report `.zero`, which is
why `SpriteHelpers.swift` could not be compiled — and `textureRect` is the
slice of the page the renderer samples, counted up from the bottom as
texture coordinates are. `SKTexture(rect:in:)` composes inside that, so a rig
mesh's slice of a packed texture lands in the right place. The index carries
no pixels: `url(ofPage:)` is what the renderer loads and caches on
`SKTexture.glName`.

With no index set, a named texture behaves exactly as it did before one
existed, so the other 34 tests need no art.

## Design: a frame is a value

The shim does not issue draw calls. `SKView.tick` returns a `DrawList`:

```swift
let list = view.tick(currentTime: now, delta: 1.0 / 60)
```

a flat, ordered list of sprite/shape/label commands with nested `effect` and
`crop` groups. That is why the scene graph, the transform maths, the action
system and the draw order are all testable on the host with no window and no
GL context — the layer can be built well before the Android app shell exists,
and the renderer becomes a separate, replaceable consumer.

Draw order is by accumulated `zPosition`, sorted **stably**, so ties fall in
tree order. SpriteKit leaves ties nondeterministic (which is why AGENTS.md
requires explicit `zPosition` for overlapping siblings); this is strictly more
deterministic, never less.

## What is deliberately unfinished

- **Text.** `SKLabelNode` holds its state and reports a zero frame. It needs
  HarfBuzz for shaping (Thai reordering, KoHo, CJK) plus FreeType for
  rasterising, feeding a glyph atlas, with the game's `wrappedLines` on top.
  This is the single largest remaining piece and has no shortcut — notably,
  Axmol would not have helped: it vendors FreeType and **no** HarfBuzz.
  `UIFont` here is a descriptor (family, size, weight) and measures nothing.
- **Rasterising.** `CGPath` and `UIBezierPath` record; nothing fills or
  strokes them yet. `SurfaceTexture`'s 7 `CGContext` sites need the same
  rasteriser. (`cmake`, `ninja` and `pkg-config` are installed for this.)
- **The renderer.** No GLES 3 backend yet. `SKTexture.glName` and
  `SKShader.glProgram` are where it caches its handles. The game's GLSL is
  ES 1.0 with SpriteKit's preamble (`u_time`, `v_tex_coord`, `u_texture`,
  `SKDefaultShading()`); the plan is to rewrite that preamble to ES 3.0 at
  upload, in one place, rather than editing 31 files.
- **`SKEffectNode` semantics.** The type and its bounds are here; the
  behaviour the game depends on is documented in its doc comment and must be
  reproduced by the renderer rather than inherited from whatever a
  render-target abstraction does by default.
- **`SKWarpGeometry`** (9 uses: plants, wings, crowns) is not started.
- **The texture cache.** `SpriteHelpers.swift` is not compiled here yet: it
  reaches into `SceneLighting`, `LiveBackdrops` and `RigMeshNode`, which are
  the renderer. Its `ArtSlices` dependency is settled — see **Art** below —
  and so is `SKTexture(imageNamed:)`, which the whole file hangs off.

## Next

The milestone worth aiming at is **one level, playable, no menus**: board,
rigs, shaders, `Timeline`. It needs the GLES 3 backend and the rig meshes but
none of the text or UI work, and it answers the question that actually decides
the port — whether eight procedural backdrops with live lighting hold 60 fps
on a mid-range Android GPU (Mali-G57 / Adreno 610 class, not a flagship, and
not the emulator, which renders through the host GPU and will flatter it).

## Toolchain

Swift 6.4.2 (open-source, via swiftly — Xcode's Swift cannot cross-compile),
the `swift-6.4.2-RELEASE_android` SDK bundle, and Android NDK LTS r30 at
`$ANDROID_NDK_HOME`. See
<https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html>.
