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
  Shell/                 Android-only. The app shell: SDL3, the GLES 3
                         context and the frame loop.
  App/                   The Gradle project — the installable APK.
  Scripts/               Cross-compiling SDL and the shell.
  Text/                  Shaping, metrics, rasterising, the glyph atlas.
                         60 tests. Needs Vendor/ built first.
  Probe/                 Android-only. Runs the game's own text layout on
                         a device: Probe/run-probe.sh.
  Vendor/                FreeType and HarfBuzz, fetched and built by a
                         script. Nothing binary is committed. The shell
                         links them too, for the glyph atlas, so
                         Scripts/build-shell.sh needs them built first.
```

The app shell has a README of its own: **[App/README.md](App/README.md)** —
how to build the APK, install it, read logcat, and which ABI goes with which
emulator image.

`Compat` is a separate package because a target named `CoreGraphics` cycles
with the system module when built on macOS. Keeping it out means the shim
itself stays host-testable. `Text` is separate for a related reason: it is
the only part of the port with C dependencies, and folding them into the
root package would make `swift build` here need a cmake run first, for
everyone working on the scene graph, the actions or the renderer. The shim
therefore never links FreeType — it asks whatever `TextProvider` has been
registered with `TextMetrics`.

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

Vendor/build.sh                                         # FreeType + HarfBuzz
cd Text
PKG_CONFIG_PATH=../Vendor/out/host/lib/pkgconfig swift test              # 60 tests
PKG_CONFIG_PATH=../Vendor/out/aarch64-linux-android/lib/pkgconfig \
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple aarch64-unknown-linux-android23 --product TextProbe

cd ../Probe
./run-probe.sh                                          # on a device
```

All of them pass. `TextProbe` is an executable rather than a library, so it
is the one thing here that proves the Android archives actually **link**: it
comes out as an ELF for both ABIs and needs no `libc++_shared.so`.
`GameCompat` compiles **4,790 lines of real, unmodified game
source** for Android on both ABIs:

| file | lines |
|---|---|
| `Source/Utils/DesignSystem.swift` | 3,925 |
| `Source/Utils/GeometryHelpers.swift` | 338 |
| `Source/Utils/TextHelpers.swift` | 79 |
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

## Text

Done, in `Text/` over `Vendor/` — see `Text/README.md`. HarfBuzz 15.1.0 for
shaping and FreeType 2.15.0 for metrics and rasterising, both built from
source for the host and both Android ABIs by a script, with a glyph atlas
over them. `SKLabelNode` breaks and places its text and reports a real ink
frame; `UIFont` reports real metrics; `DrawList.Label` carries the laid-out
lines so the renderer draws what was measured.

Thai is the acceptance test, since it is where FreeType alone is not merely
imprecise but wrong: SARA AM splits into two glyphs and reorders them, tone
marks take different forms over tall consonants, consonants lose their
descenders under below-vowels, and marks are positioned by GPOS rather than
stacked at the pen. Each has a test against what `FT_Get_Char_Index` alone
produces. Axmol, for the record, would not have helped here: it vendors
FreeType and **no** HarfBuzz.

`Source/Utils/TextHelpers.swift` compiles here **unchanged** and runs on a
device. It is pure CoreText, and the shim answers for it: `Typesetting.swift`
does the work over `TextMetrics.provider` (no C dependency, host-testable)
and `CoreTextCompat.swift` puts the `CTTypesetter` / `CTLine` names on it for
Android. `Probe/run-probe.sh` runs the real `wrappedLines`, `capitalsOffset`
and `TextBlockNode` on an emulator or device, because a build cannot show
that corelibs Foundation's `NSAttributedString` really hands a `UIFont` back.

It draws, too. `GlyphPages` uploads the atlas as `R8` textures, honouring
its dirty rect and generation so a page goes up once and then only where it
was written, and `CoverageGeometry` turns `DrawList.Label`'s layout into
quads — the layout, never a second measurement, so what is drawn and what
`contentFrame` reported cannot drift. Glyphs are shaped at the label's point
size and rasterised at the screen's density, so a 24-point label on a 3x
phone is not a 24-pixel bitmap magnified.

What text still needs is the localisation ring: `FontRegistry` and
`Localization.scriptFontName` are the last stubs in `GameCompat`.

## Rasterising

`PathRasteriser` in `Sources/GLESRenderer` fills and strokes a `CGPath`
into 8-bit coverage: a scanline fill with both winding rules, and stroking
with the caps, joins and mitre limit the path carries. It is Swift rather
than a vendored C library on purpose — it sits in the half of the renderer
with no GL in it, so its edge cases are tested on the Mac against paths
built with CoreGraphics' own API, and nobody needs a second cmake build to
work on the scene graph. See its doc comment, and `PathRasteriserTests`.

`SKShapeNode` draws through it today. `SurfaceTexture`'s 7 `CGContext`
sites — which is every chunky button, panel and meter — need a `CGContext`
over the same rasteriser, with gradients, shadows and clipping. That is the
surfaces ring and it is not started.

## What is deliberately unfinished

- **`CGContext`.** The rasteriser is there; the context around it is not, so
  `SurfaceTexture` cannot draw yet. It also needs `UIImage`,
  `UIGraphicsImageRenderer` and `SKTexture(image:)`, which do not exist.
- **The renderer.** Sprites, text and shapes draw; the rest does not. The
  game's GLSL is ES 1.0 with SpriteKit's preamble (`u_time`, `v_tex_coord`,
  `u_texture`, `SKDefaultShading()`), rewritten to ES 3.0 at upload by
  `ShaderTranslator` rather than in 31 source files.
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

## The beta's reporting is off on Android

Decided 2026-11-13, and it has to be honoured when the platform ring lands
rather than patched afterwards.

On iOS every build — debug, TestFlight and release alike — plays the Level
Designer's feed and posts each clear to the designer's server
(`DesignerFeed`, `PlaytestLog`). That is fine there, because those features
come out before the App Store release and TestFlight is not a public
listing. On Play it is not: an **internal or closed track is a distributed
build**, so anything it reports has to be declared in Data Safety.

So the Android build does not report. `PlaytestLog` and `DesignerFeed` are
chokepoints — five and six call sites, none of which touch the network
themselves — so the port swaps their bodies for ones that do nothing, the
same way `StoreManager`, `GameCenterManager` and `ICloudSyncManager` get
Android implementations. Nothing in `Source/` changes.

Nothing in the shell reports today: it draws a board and knows nothing of
levels or sessions. This note exists so that stays true by intent rather
than by accident.

Two consequences for the Play listing, both written up in
`Tools/Play/PLAY-CONSOLE-SETUP.md`: the solve log needs no Data Safety
declaration, and since there is no Game Center on Android there is no maker
name or photo on a shared level either — so the whole Name/Photos half of
the iOS answer drops away rather than carrying across.

## Toolchain

Swift 6.4.2 (open-source, via swiftly — Xcode's Swift cannot cross-compile),
the `swift-6.4.2-RELEASE_android` SDK bundle, and Android NDK LTS r30 at
`$ANDROID_NDK_HOME`. See
<https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html>.
