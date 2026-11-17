# SpriteKit for Android

A Swift runtime that runs SpriteKit games on Android: the games' own sources
compile unedited against it, keeping `import SpriteKit`, `import UIKit`,
`import CoreGraphics` and the rest, and it draws them with GLES 3 through
SDL3, with Google Play's billing, achievements and saved games behind the
games' own managers.

It was built for Switchlings (fleon/switchlings, from November 2026), whose
Android port is its first game: 219 of that game's 236 source files compile
for Android as they are. Most of this README records how each part was
built and measured there, and so names Switchlings' scenes, worlds and
devices; what it describes is the runtime's.

## Using it in a game

Check this repository out as a submodule named `spritekit-android` inside
the game's Android directory (a package's identity is its directory's name,
and the manifests here refer to this package as "spritekit-android"):

```
<game>/Android/
  spritekit-android/   this repository (submodule)
  Game/                the game's package (Switchlings calls it Compat/)
  App/                 the game's Gradle project
```

The game's package depends on these packages by path
(`spritekit-android`, `spritekit-android/Modules`, `spritekit-android/Shell`)
and holds:

- **GameCompat**: symlinks into the game's `Source/` at their own paths,
  leaving out the Apple app's entry (`AppDelegate`, `SceneDelegate`,
  `GameViewController`) and the managers that reach Apple's services.
- **The controller**: the Android counterpart of `GameViewController`,
  adopting `GameHost` (`Shell/Sources/GLESBackend/GameHost.swift`).
- **The managers' bodies**: the game's `AudioManager`, `StoreManager`,
  `GameCenterManager`, `ICloudSyncManager` and `HapticsManager`, their API
  kept name for name, over `PlatformShim`.
- **The entry**: a target exporting `SDL_main`, which calls
  `Shell.start(argc:argv:app:game:configure:)` with the app's
  `AppIdentity` and the controller's type, and a dynamic library product
  named `AndroidShell` (the library SDL loads).

Scripts find the game from the runtime's parent directory, or from
`GAME_ANDROID_DIR`, `GAME_PACKAGE_DIR` and `APP_DIR` (`Scripts/config.sh`).
`Scripts/launch.js` takes the app's package and activity from
`SKA_APP_PACKAGE` and `SKA_APP_ACTIVITY`. Debug properties are
`debug.<AppIdentity.key>.*`.

An API a game needs that's missing here is added here, with SpriteKit's
signatures and behaviour measured against SpriteKit on a Mac, and a host
test, never worked around in the game.

```
swift test                                  # host tests, Mac
Vendor/build.sh android                     # FreeType + HarfBuzz
Scripts/build-sdl.sh arm64-v8a              # SDL 3.4.20
Scripts/build-shell.sh --debug arm64-v8a    # the game's AndroidShell
```

`Scripts/emulators.sh` is the pool of four emulators every project on the
machine shares (its AVDs and state keep Switchlings' names, since sessions
use it as it is).

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
| `SKEmitterNode` / `SKKeyframeSequence` | 5 / 7 — done, see **Particles** |

And the game's own `SKAction` helpers (`animate`, `animateSteadily`,
`pingPong`, `zoom` in `EasingFunctions.swift`) are built from just four
primitives: `customAction`, `run`, `sequence` and `repeatForever`.

## The runtime and the game

What's here is a SpriteKit runtime for Android with Switchlings as its first
game, on its way to a repository of its own so Hue Rings, Zyl and Phantom
Words can use it as it is. The runtime is `SpriteKitShim`, `GLESRenderer`,
`PlatformShim`, `Text`, `Shell`, the module-name targets in `Compat`, the
Gradle project's template and the tools. What's Switchlings' own is
`GameCompat` (its sources, `AndroidGameController` and the managers'
bodies), `SwitchlingsEntry` and `SwitchlingsStore`.

The seam is `GameHost` (`Shell/Sources/GLESBackend/GameHost.swift`): what
the shell asks of a game's controller (launch, layout, input, audio, the
frame rate and render scale). The game's entry target exports `SDL_main`,
calls `Shell.start(argc:argv:game:configure:)` with its controller's type,
and its package builds the `AndroidShell` library the APK loads. The shell
imports no game, and the runtime names no product: `PlayBilling` is told
which products to query.

Still Switchlings-named in the runtime, to go with the move: the C
functions' `ska_` prefix, the log tag, `debug.switchlings.*`
properties, the `SKA_*` environment variables `MainActivity` sets,
`CAndroidAudio`/`CAndroidMedia`, the Java package, and
`RenderScaleGovernor.swift`, which `GLESRenderer` symlinks from `Source/`.

## Layout

```
Android/
  Package.swift          SpriteKitShim + tests. Builds on macOS and Android.
  Sources/SpriteKitShim/ The layer.
  Sources/PlatformShim/  The Android stand-ins for AVFoundation, iCloud's
                         key-value store, StoreKit and GameKit — the parts
                         with no device in them. 30 tests.
  Sources/SwitchlingsStore/  Switchlings' own, not the runtime's: what it
                         keeps about what's owned (`Entitlements`: its
                         product, launch event and reward). Here so it tests
                         on the host.
  Tests/                 Host tests, no device or GL context needed.
                         RigRuntimeTests symlinks the game's RigData and
                         RigPose in and runs them against Assets/Rigs.
  Assets/                The packed art. Generated, gitignored, 101 MB.
  Compat/                Android-only. Do not build on a Mac.
    Sources/SpriteKit/   Targets that exist only to own a module name,
    Sources/UIKit/       so the game's imports resolve without an edit.
    Sources/CoreText/
    Sources/CoreGraphics/
    Sources/GameCompat/  Symlinks into Source/ — real files, not copies.
    Sources/SwitchlingsEntry/  `SDL_main`: hands the shell the game.
                         The package's `AndroidShell` product is the
                         library the APK loads.
  Shell/                 Android-only. The app shell: SDL3, the GLES 3
                         context, the frame loop, and the audio backend
                         (SDL3 output, MediaCodec for the soundtrack).
                         Depends on no game (`GameHost`, below).
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
do, and each re-exports the shim. **No file in `Source/` is edited for the
port — not even its imports** — beyond what the owner allowed: seedable
randomness (`-RandomSeed`) and phone checks that ask `os(iOS) || os(Android)`.

Apple is detected with `canImport(Darwin)`, not `canImport(CoreGraphics)`,
precisely because this package ships a module by that name.

## What is proven

```
swift build                                             # shim, macOS
swift test                                              # 240 tests, macOS
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple aarch64-unknown-linux-android23    # shim, Android

cd Compat
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple aarch64-unknown-linux-android23    # real game sources
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple x86_64-unknown-linux-android23     # emulator too

Vendor/build.sh                                         # FreeType + HarfBuzz
cd Text
PKG_CONFIG_PATH=$PWD/../Vendor/out/host/lib/pkgconfig swift test         # 60 tests
PKG_CONFIG_PATH=../Vendor/out/aarch64-linux-android/lib/pkgconfig \
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple aarch64-unknown-linux-android23 --product TextProbe

cd ../Probe
./run-probe.sh                                          # on a device
```

All of them pass. `TextProbe` is an executable rather than a library, so it
is the one thing here that proves the Android archives actually **link**: it
comes out as an ELF for both ABIs and needs no `libc++_shared.so`.
`GameCompat` compiles **220 of the game's 236 source files**, unmodified,
for Android on both ABIs (see **The game's own scenes** for the sixteen it
leaves out and why). Where the game asks `#if os(iOS)` about phones and touch
screens rather than Apple's own APIs (the camera housing's side in
landscape), it asks `os(iOS) || os(Android)`. The table below is the first slice that compiled:

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
| `Source/Game/Components/Rig/RigNode.swift` | 429 |
| `Source/Game/Components/Rig/RigData.swift` | 407 |
| `Source/Game/Components/Rig/RigPose.swift` | 366 |
| `Source/Game/Components/Rig/RigMeshNode.swift` | 342 |
| `Source/Game/Components/Rig/LedGlowNode.swift` | 95 |
| `Source/Game/Models/WorldTheme.swift` | 173 |
| `Source/Common/Components/BackdropWarp.swift` | 152 |
| `Source/Common/Components/BackdropTouch.swift` | 134 |
| `Source/Utils/AttributeShaders.swift` | 53 |
| `Source/Common/Components/CharacterEyesNode.swift` | 71 |
| `Source/Utils/CharacterFaces.swift` | 54 |

plus the generated `Source/Utils/ArtSlices.swift` and `CharacterFaces.swift`,
against the documented stubs in `Compat/Sources/GameCompat/Stubs.swift` and
`RigStubs.swift` — each one a seam that belongs to a later ring.

The rigs are the second useful case, and the one that runs: `RigData`,
`RigPose`, `RigNode` and `LedGlowNode` compile unchanged and **Switchlings
animate on a device**; `RigMeshNode` has a port of its own that draws real
triangles. See **Rigs** below.

`ArrowTileNode` is the useful case: a real `SKNode` subclass that runs a keyed
`pingPong` action built from `customAction` + `sequence` + `repeatForever`,
positions a child, reads ~8 `DesignSystem` constants and uses the `pt`/`sz`/
`rect` helpers. It compiles and its action semantics are covered by tests.

## Art

The Apple build ships 1,608 `@3x` image sets in `Assets.xcassets` (204 MB
with Apple TV's `@2x` renditions) and looks each one up by name through
`txtr(_:)`. Android gets the same pixels, repacked:

```
Tools/Art/ASTC/build-astcenc.sh   # once: Arm's ASTC encoder, built from its pinned source
npm run art -- --android      # Tools/Art/android-art.js → Android/Assets
npm run art:android:check     # 19 checks on the packer, the compression and the index
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

An image whose longest side is over 512 px takes a page of its own. That is
what keeps the tiling backdrop grounds (the smallest is 1158 px) whole
textures that can be sampled with `GL_REPEAT` — an atlas slice can't be.
Each packed image sits in a cell of its own, 4 px of gutter round it and
rounded up to whole 4 px blocks, its edge pixels extruded over the rest of
the cell, so a linear tap, a 9-slice stretch, an ASTC block or a mip level's
texel at a rect's edge never pulls in a neighbour. Its left and bottom edges
fall on block boundaries, so a shader's slice of it can be cut out of the
compressed page block for block.

### Compressed pages and mip levels

Every page but one ships as ASTC with its mip levels (`Tools/Art/ASTC/compress.js`,
written by Arm's `astcenc` 5.7.1 at `-thorough`): a KTX 1.1 file of blocks,
premultiplied (as SpriteKit's textures are, and the blend
`ONE, ONE_MINUS_SRC_ALPHA` wants) and bottom row first, so `GLDevice` hands
its levels to `glCompressedTexImage2D` as they are. The Galaxy M31's
Mali-G72 is bound by fill rate and memory bandwidth; ASTC reads 4 to 16
times fewer bytes a texel than RGBA8, and mip levels let a minified sprite
(3x art at render scale 0.5) read a small level instead of skipping across
a big one.

- **Atlas pages** take 4×4 blocks (8 bits a texel, ASTC's best): they hold
  the interface's pieces, hard-edged mechanisms and painted kits side by
  side. Three levels (2048, 1024, 512 px): a level-2 texel is a 4 px cell
  block, which the gutter covers.
- **Whole pages** take the biggest block (8×8, 6×6, 5×5, else 4×4) whose
  decode stays within 46 dB PSNR of the painting, with at most 0.1 channel
  values in 10,000 more than 24 levels off, measured over every texel either
  covers. The grounds mostly take 6×6 or 8×8; the wordmark's backings,
  blocks and bump switches 4×4 or 5×5. Every level down to 16 px.
- **Exact pages** stay PNGs with no mip levels: `BackdropGlassLawnStones`,
  the map the glass lawn's shader reads value by value (`EXACT`).

The index says which (`format`, `block`, `levels`) and how each page's
level 0 decodes against the art (`quality`). 2026-11-15: 18 atlas pages at
4×4, and whole pages at 4×4 (76), 5×5 (43), 6×6 (13) and 8×8 (11); 144 MB
of KTX, 73 MB deflated in the APK, against 101 MB of PNGs.

At run time (`GLDevice`, `ResourceCache`, `CompressedPage`):

- The renderer asks once whether the GPU samples ASTC
  (`GL_KHR_texture_compression_astc_ldr`, `GLDevice.astcSupported`) and
  logs `texture path: ASTC` or `RGBA8`. The emulator takes ASTC (decoding it
  in software where its host GPU can't); without it each page is decoded on
  the CPU as it's read (`ASTCDecoder`, held to astcenc's own decoder byte
  for byte by `ASTCDecoderTests`) and uploaded as RGBA8, its mip levels made
  by `glGenerateMipmap`. ETC2, which GLES 3.0 guarantees, isn't shipped: it
  would be a second set of pages for the few GPUs without ASTC.
- Pages with levels are filtered `LINEAR_MIPMAP_LINEAR`, with
  `GL_TEXTURE_MAX_LEVEL` at their last level. At 1:1 (the parity sweep's
  3x screen at render scale 1) that samples level 0 alone, as before.
- A shader never gets mip levels: a whole page a shader samples (the lawns'
  grounds, Kitchen's gingham, the planets) or draws with is uploaded again
  with level 0 alone (`plainName`), since a shader that tiles with `fract`
  would read the smallest level along the seam. An atlas image a shader
  samples is cut out of its page block for block (`CompressedPage.cut`).
- The CPU reads an image set's pixels (ledges' mitred ends, the Mainframe's
  floor, share avatars: `UIImage(named:)`) by decoding its rect.
- `SKTexture.usesMipmaps` is honoured where an unshaded sprite draws the
  image (`drawnName`): its levels come from `glGenerateMipmap`. The rigs
  ask for it, and get it now that their meshes draw as real triangles
  (**Rigs**): the game's `RigMeshNode` shader picked one of four triangles a
  pixel, so the texture coordinate's derivative jumped at every triangle's
  edge and the GPU read the smallest level there, a dotted seam over every
  Switchling. Interpolated across a triangle, it doesn't.
- The frame report logs the textures' memory every 300 frames:
  `[frames] game textures N  X MB on the GPU (Y MB as RGBA8)`.

```jsonc
{
 "version": 2,
 "scale": 3,
 "pages": [ { "file": "atlas-000.ktx", "width": 2048, "height": 2048, "format": "astc", "block": [4, 4], "levels": 3,
              "quality": { "psnr": 48.9, "worst": 41, "outliers": 0.01 } },
            { "file": "whole/BackdropReefSeabedSand.ktx", "width": 1254, "height": 1254, "repeats": true,
              "format": "astc", "block": [8, 8], "levels": 7, "quality": { "psnr": 51.7, "worst": 45, "outliers": 0.04 } } ],
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

## Rigs

The whole rig runtime is here: `RigData` reads a packed Spine 4.2 skeleton,
`RigPose` poses it the way Spine's runtime does (crossfades, physics step for
step) and `RigNode` draws it. Those, and `LedGlowNode`, compile for both ABIs
unmodified. `RigMeshNode` is the port's own
(`Compat/Sources/GameCompat/Android/RigMeshNode.swift`, below).

```
npm run art -- --android      # stages Android/Assets/rigs as well
npm run art:android:check     # 15 checks, two of them on the rigs
swift test                    # RigRuntimeTests: 24, against the real rigs
```

**Where the rigs live.** They are not in the asset catalog and are not
packed: `RigData` wants `Rig<Name>.json` and `RigNode` loads
`Rig<Name>.png` whole. `android-art.js` copies them to `Android/Assets/rigs`
as part of the same export, because that export clears its output directory
and would otherwise take a separately staged copy with it.
`Rig<Name>Normal.png` is deliberately left behind: a normal page is what
tells `RigMeshNode` a rig is lit, and nothing on Android lights one yet.

**How `Bundle.main` answers.** `RigData` asks
`Bundle.main.url(forResource:withExtension:)` and reads the result with
`Data(contentsOf:)`. Inside an APK there are no paths, and corelibs
Foundation's main bundle is beside the executable, which for an SDL app is
the system's `app_process`. `BundleResources` in the shim answers instead,
through an overload that takes plain `String`s where Foundation's takes
`String?` — so the game's own call, which passes plain strings, prefers it
with no edit. `RigBundle` in the shell installs a provider that copies a rig
out of the APK into the app's cache the first time it is asked for.

**The main thread.** SDL runs `SDL_main` on a thread of its own, so
`Thread.isMainThread` is false on the only thread the game has, and
`RigMeshNode.prepare(in:)`'s `precondition` traps. `MainThread` in the shim
takes over CoreFoundation's `_CFIsMainThread` and moves "main" to the thread
that calls `claim()`; the shell calls it first thing in `SDL_main`. Any
later ring that asserts the main thread needs this too.

**Meshes as triangles.** SpriteKit has no meshes, so the game's
`RigMeshNode` cuts each mesh attachment into runs of four triangles, one
sprite each, carrying twelve `vec4` attributes whose shader tests every pixel
of the sprite's quad against them and discards the rest. Here that cost a
draw call for every four triangles (a sprite with attributes never merges),
twelve `glUniform4f`s before each, and fragments over every quad's whole
bounding box. So the port has a `RigMeshNode` of its own, in the same shape
(`RigNode`, `SceneLighting` and the films call it as they call the game's),
that hands its triangles over as they are: one sprite a mesh, carrying an
`SKTriangleMesh` (the shim's own, not SpriteKit's: positions, texture
coordinates and indices), which `DrawList` carries on the sprite's command
and `SpriteBatcher` writes into the batch as geometry (`MeshBatching`), as it
does a warp's grid. A rig's meshes and regions sample its one texture with no
shader, so a Switchling draws in one call where nothing comes between its
parts (its eyes and painted faces are another texture, its clipping masks
crop nodes).

It draws what the game's does: the texture times the node's alpha
(`SKDefaultShading` untinted), premultiplied, in Spine's order (triangles
draw in index order within a call, and over is associative, so compositing
them one by one is compositing the run); dimmed while asleep by the sums
`RigNode`'s regions use (linear in the colour, so dimming each triangle is
dimming the run); and a mechanism's rig flat-lit by its world's light with
`WorldLight.flatShader(.floor)`, the shader every flat-lit piece shares,
whose sums are the ones the game's mesh writes out for that case. A mesh lit by a normal page isn't ported, as no normal page
ships (below). The game's mesh read an edge a ten-thousandth wide on either
side of each triangle, so a pixel centred on a shared edge took both; GL's
rasterisation rules give it to one.

The replacement is the one game file the port doesn't compile as written,
for the CPU it saves as much as the GPU: the game's version works out three
planes for every triangle each frame and writes them as attribute values,
which the renderer would then have had to work back into vertices.

*Before that:* the attributes were per node, so the translator made each a
uniform of the fragment stage (`ShaderTranslator`) and `SceneRenderer` set
it before the sprite's draw. They began as constant vertex attributes
passed through twelve varyings, which the emulator drew right and a Galaxy
M31's Mali-G72 did not: every rig dropped whole triangles. The translator
still handles them, for anything else that carries attributes.

**What is not wired yet.** Lighting is stood in for
(`RigStubs.swift`), so every Switchling's rig takes `RigMeshNode`'s unlit
path — which is its own real code, not a lit shader with invented light in it.

## Particles

`SKEmitterNode` is simulated here, in Swift, and its particles reach
`DrawList` as ordinary sprite commands — so the renderer needed nothing new.
The game makes every emitter in code (no `.sks` files): Reef's marine snow,
motes, vents and tap bursts in `SeabedNode`, and every other world's pollen,
dust, bubbles, fireflies and twinkles in `BackdropNode`'s
`AmbientParticlesNode`. The shim has what those set and what SpriteKit puts
beside them: birth rate, `numParticlesToEmit`, lifetime, position, angle,
speed and acceleration; alpha, scale, rotation and colour blend factor, each
with a range and a speed; colour, colour blend factor, alpha and scale
`SKKeyframeSequence`s (which override the value, its range and its speed, as
the game's comment says);
`particleAction`, `particleTexture`, `particleSize`, `particleBlendMode`,
`shader` with attribute values, `particleZPosition`, `targetNode`,
`advanceSimulationTime` and `resetSimulation`.

- **Ranges** are SpriteKit's: a value's whole spread, `value ± range / 2`.
- **Time** is the scene's: the emitter steps in `tickActions`, after its own
  actions (so the vents' `run` blocks that switch the birth rate on and off
  take effect that frame), scaled by `speed` and held while paused. Long
  steps are cut into equal steps of at most 1/60 s, so
  `advanceSimulationTime(12)` — how the ambient emitters start full — plays
  out exactly as 720 frames would.
- **Randomness** is a SplitMix64 per emitter, seeded in the order emitters
  are made: the same scene built the same way plays the same particles.
  `randomSeed` is the shim's own, for tests.
- **Space.** Particles live in the emitter's space, or with `targetNode` in
  the target's, born where the emitter stands at that moment and left there
  as it moves on. Either way they draw at the emitter's accumulated depth
  plus `particleZPosition`, ordered globally with everything else.
- **`particleAction`** runs on a stand-in node per particle, added on top of
  the particle's own motion: a `moveBy` measures from where it started, so
  run on the particle itself it would pull it back against its velocity.

`SKKeyframeSequence` is whole: numbers (however they arrive: `Int`,
`CGFloat`, `NSNumber`) and colours, `linear`, `step` and `spline`
(Catmull-Rom through the keyframes, the ends repeated), `clamp` and `loop`
(over the span from the first keyframe's time to the last's), and editing
that keeps keyframes in time order.

`EmitterTests` pins birth counts, lifetimes, every range's bounds under a
seed, `advanceSimulationTime` against ticked frames, pausing and speed,
sequences, actions and both spaces; `KeyframeSequenceTests` each mode.
Reef's own `SeabedNode` shows them in the game: `-StartLevel reef-1`.

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
over them. `SKLabelNode` breaks and places its text and reports the frame
Apple's would (the ink rounded out to whole points and padded by one); `UIFont` reports real metrics; `DrawList.Label` carries the laid-out
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
- **`SKWarpGeometry`** is done for sprites — see **Warps** below. An
  effect node carries `warpGeometry` but does not bend its texture yet; the
  game never warps one.
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

## The platform ring

The managers the game reaches the system through — audio, saved data,
purchases, achievements, the beta's reporting — are swapped **body for
body**. Every public API is the same name for name, so the call sites are
untouched: `StoreManager` is called in 15 files, `ICloudSyncManager` in 9,
`GameCenterManager` in 7, and not one of them imports StoreKit, GameKit or
`NSUbiquitousKeyValueStore`. That is what makes the swap possible at all.

The bodies live in `Compat/Sources/GameCompat/Platform/`, beside the
symlinked game sources rather than instead of them — these six files are the
only ones in the port that are *not* the game's own code, and each says at
the top what it keeps, what it drops and why.

Whatever has no device in it sits in `Sources/PlatformShim` and is tested on
the Mac: the merge saved data depends on, what the full game being owned
means, which achievements have moved. The device half is one protocol each
(`AudioBackend`, `CloudKeyValueStore`, `BillingBackend`,
`AchievementsBackend`), so the thing that cannot be tested is small enough
to read.

### Audio — done

`AudioManager` keeps every decision it made: the sound list, the per-world
track, the enable switches as synced settings, the pitch variation on
footsteps, music waiting while the app is away. What went is AVFoundation.

- **Sound effects**: the WAVs, decoded once with `SDL_LoadWAV`, a pool of
  `SDL_AudioStream` voices each so repeats overlap. SDL's per-stream gain
  and frequency ratio give the volume and the footstep pitch for free.
- **The soundtrack**: AAC, decoded by Android's own MediaCodec through the
  NDK's C API (`Shell/Sources/CAndroidAudio`), mixed on a thread of its
  own with sample-accurate gain ramps.

Why AAC rather than re-encoding to Ogg or MP3: Android's CDD makes all three
mandatory, so there is no format it prefers. What decides it is that the APK
then ships **the same bytes the IPA does** — one encode, one set of loop
points, nothing to drift — and that `libmediandk.so` is a system library, so
nothing is vendored or built. It is also hardware-decoded on a real phone,
which matters when the GPU is the budget. And it is cheap to undo:
`AMediaCodec_createDecoderByType` takes the MIME type out of the container,
so .ogg or .mp3 would decode through the same C unchanged.

Loop points are the subtle part. `MusicLoops.frames` counts frames of the
master, and an AAC decoder hands back the encoder's priming samples too, so
a frame counter would sit a constant off. The mixer works in the container's
presentation time for both "where am I" and "where does the loop start", so
that constant cancels — and `export-music.js` crossfades the seam into the
file itself, so the loop is forgiving by construction.

The audio is staged into the APK under `assets/audio/` by the Gradle project
and listed in `noCompress`: a stored asset has a file descriptor, which is
what lets MediaCodec read the music out of the APK instead of 28 MB being
copied onto the device first.

`-AudioProbe` plays a track, overlaps sounds, crossfades, loops and fades
out, saying in logcat what it did and how loud what it decoded was.

The game's `AudioManager` starts on a silent backend, since launch runs
before SDL is up; the shell hands it the SDL one the moment the device opens
(`Shell.audioDidOpen`, `AndroidGameController.useAudio`), which loads the
sounds into it and starts any track already asked for. Until 1.1.2 (56)
nothing did, so the game was silent on every device while `-AudioProbe`,
which talks to the backend itself, played fine. `audio: 19 sounds, 3 voices
each` in logcat says the game's sounds reached it.

A game whose soundtrack isn't AAC names its container in its entry's
`configure` (`AudioAssets.musicExtension = "mp3"`: MediaCodec reads the
format from the file, so only the name changes), and a track with no loop
points of its own repeats whole with `MusicLoop.wholeTrack`, as an
`AVAudioPlayer` with `numberOfLoops = -1` does (Hue Rings).

### Google Play and the device: one channel

Play Billing, Play Games Services, haptics, audio focus and battery saver
are Java APIs, so the app has a small Java side of its own
(`App/app/src/main/java/com/fleon/switchlings/`): `PlatformServices` routes
to `PlayBilling`, `PlayGamesServices` and `DeviceServices`. Between it and
Swift is **one channel** (`PlatformChannel` in `Sources/PlatformShim`), two
JNI calls wide however many services sit behind it:

- Swift calls `MainActivity.platformCall(name, json)` on the game's thread
  (`billing.purchase`, `games.report`, `device.haptic`…). Anything slow is
  started there and answered later.
- Java's answers and news are **events**, queued in Java; a native method
  the shell registers (`RegisterNatives`, since SDL dlopens the library and
  the JVM would never find it by name) flips a flag, and the frame loop
  drains the queue (`platformDrain`) on the game's thread. No Swift ever runs
  on a Java thread.

Both directions are JSON as UTF-8 bytes, not `jstring`s: JNI's modified
UTF-8 splits characters outside the BMP, and a player's name can hold an
emoji. Everything decided above Java — what is owned, which achievements
moved, how saved data merges — is Swift in `PlatformShim`, tested on the
Mac against a fake Java (`PlayBillingTests`, `PlayGamesTests`,
`SavedGamesTests`). `AndroidPlatformServices` (in `GameCompat`) installs the
backends before `AppDelegate`'s launch work starts the managers, so
`StoreManager`, `GameCenterManager` and `ICloudSyncManager` keep their API
for every caller.

### Purchases — Play Billing

`PlayBilling` (Billing Library 9.1) behind `StoreManager`, for the one
product, `com.fleon.switchlings.fullgame`:

- **The price** is Play's, in the player's currency (`fullGamePrice`).
- **A purchase** ends purchased, **pending** (cash at a shop, a parent's
  approval: the game unlocks when Play says it completed, live or at the
  next query on resume), cancelled or failed. Play's "already owned" is a
  restore.
- **Acknowledgement**: every purchase is acknowledged once (Play refunds one
  left for three days); a failed one is tried again after the next query.
- **Restore** is Play's purchase query, run at launch and on every resume as
  Google asks. A query that fails changes nothing (offline is not a refund);
  one that succeeds without the product takes it away (a refund).
- **The launch event**: Play's `purchaseTime` stands in for StoreKit's
  `originalPurchaseDate`, so a player who bought before 14 February 2027
  keeps the secret worlds on a new phone too.
- **The pre-registration reward** (Android's one store rule of its own):
  Play grants `com.fleon.switchlings.mainframe` free, at first launch, to
  whoever pre-registered. It's a one-time purchase like any other (no order
  ID or payload, which nothing reads), found by the launch query and
  acknowledged. While the launch event runs it waits to be **claimed**
  (`StoreManager.hasRewardToClaim`): The Mainframe's page stays locked, its
  purchase card saying "Your reward is here!" beside **Claim** in place of
  the full game's price, and its banner "Claim your pre-registration
  reward!"; Claim, or a tap on that banner, claims it (`claimReward()`, kept
  in `Entitlements.rewardClaimed`) and the world opens at once, as a bought
  one does, and the banner goes. Once the event is over the reward counts
  without a claim. Owned and claimed, it keeps The Mainframe for good, with
  or without the full game (`Entitlements.keepsSecretWorlds(owns:rewarded:)`),
  and nothing else unlocks. The first time it's seen, `MainframeReward`
  says so over the title or the world list with the game's own notice card
  (Play's rules ask for that), whose Claim claims it and opens The
  Mainframe's page (Play, once the event is over); Android's back closes it.
  The game never sells the product. To see it without Play:
  `-SimulatePurchases YES -store.simulatedProducts "(com.fleon.switchlings.mainframe)"`.
- **Family Library** is a Play Console switch for the product; a shared
  purchase reaches the family member's query like their own.
- **China**: Google Play isn't offered in mainland China, so there's no
  region to make free.

Purchases can be checked against the app's licence key
(`-Pswitchlings.playLicenseKey=…`, Play Console → Monetization setup); with
no server, that is the check there is. `-SimulatePurchases YES` still grants
locally, as on Apple.

The product's prices come from `Tools/Play/prices.py`, the App Store's
purchasing-power levels (`Tools/Store/localize_prices.py`) rounded in each
region's Play currency; `node Tools/Play/play.js product` plans it against
Play and `--send` creates it.

### Achievements and the player — Play Games Services v2

`PlayGamesAchievements` behind `GameCenterManager`. Sign-in is v2's own:
a returning player is signed in silently as the app starts, nobody is ever
asked, and play never waits (the launch splash takes the first answer, and
a build without Play Games answers "no" at once). Signing in later (from the
Play Games app) has the game catch up, as a Game Center sign-in does.

Each Game Center achievement maps to a Play Games one by ID
(`Tools/Play/PlayGames/PlayGamesAchievements.json`, generated by
`Tools/Play/games.js` and packed into the APK beside the levels; its project
ID is also the manifest's `APP_ID`). Counting ones are **incremental**: Game
Center's whole percentages, rounded back up, give exactly the count that
made them for up to a hundred steps, so 7 of 30 garden levels is 7 steps;
"every level" counts in percent. Only what moved is sent, as on Apple.
Play Games has no reset a game can call, so `-ResetAchievements` resets
nothing here.

**No maker credit from Android**, by decision (2026-11-13): a Level
Designer level shared from Android carries no name or photo, signed in or
not. The Play Games name and picture are built behind `localPlayer()` and
held off by one switch (`GameCenterManager.creditsPlayer`); turning it on
adds Name and Photos to Data safety. JPEG, which credits travel as, now goes
through Android's own codecs (`UIImage.jpegToPNG` / `pngToJPEG`, Java's
`BitmapFactory`), so a maker photo from iOS shows on Android.

Without the mapping file, nothing of Play Games runs: `LocalAchievements`
keeps the percentages on the device.

**The title's Play Games button** stands where iOS has its Game Center
button, the game's own (`TitleScene`'s `gameCenterButton`), and opens Play
Games' achievements over the game (`getAchievementsIntent`; v2's only other
overlays are the game's Play Games settings and comparing profiles with
another player). It wears Google Play Games' mark, a play triangle holding a
gamepad in its own two greens, as Huerings draws it on its Play Games button
(its Axmol app's `PlayGamesIconNode`, path data copied in), at the icons'
size, 20 points across (`Platform/GameCenterIcon.swift`, standing in for the game's file). A
signed-out player who taps it is asked to sign in, and the achievements open
once they have, as Game Center's button leads to its sign-in: the title asks
`GameCenterManager.isSignedIn` before opening the dashboard, which here is
true wherever Play Games' dashboard can open (`opensDashboard`). Where
Play Games can't run — no Google Play services on the device or out of date
(`games.available`, `GoogleApiAvailability`), a build without Play Games, or
`-GameCenterOff` — the button isn't shown: its icon hides it the first time
the scene runs it, before it's drawn. The game always shows the button, so
the icon is the one place the port can decide without touching `Source/`.

### Saved data — Play Games Saved Games

`ICloudSyncManager` keeps its shape exactly — `set` / `insert` /
`addedTimes` / `resetSet`, latest-wins and union, the `didUpdateLocalData`
notification — and runs its merge (`SyncEngine`, the Apple file's logic)
against `PlaySavedGamesCloud`: one Saved Games snapshot holding every key's
record as a binary property list.

**Why Saved Games.** It is Play's per-player cloud storage, it follows the
player's Play Games profile to every device, and it needs nothing the game
doesn't already have (the Play Games sign-in the achievements use). Block
Store is for sign-in tokens, a few kilobytes, and restores only when a phone
is set up; Android's Auto Backup restores at install and never syncs two
devices; anything else means running a server for saved games and declaring
it.

A **sync** opens the snapshot, takes Play's copy as the cloud's, lets the
engine merge this device's saved data in, and commits only if that changed
anything. A Saved Games conflict (two devices committed without seeing each
other) resolves to Play's copy: every record merges commutatively, and this
device's own changes are in its saved data with their times, so the merge
puts them back. Bytes that aren't a save are never overwritten. Syncs run as
Play Games signs in, at launch and back in the foreground (as `SceneDelegate`
asks iCloud), five seconds after the game saves, every two minutes while it
runs (so another device's clears arrive without a relaunch), and at once as
it goes to the background. `SavedDataObserving` screens catch up as on
Apple. Signed out, or under `-ICloudOff`, it runs against `LocalOnlyCloud`
and saved data stays on the device.

### The device

- **Haptics**: UIKit's feedback generators name their kind
  (`SystemServices.haptic`) and `DeviceServices` plays it: haptic
  primitives where the vibrator has them (Android 11+), predefined effects
  where not, a short buzz on the oldest, as touch feedback so the system's
  own switch silences them. The settings' Vibration switch shows, and
  feedback plays, wherever the device has a vibrator, tablets too
  (`VibrationSupport`, from `Vibrator.hasVibrator()`), not on phones alone
  as iOS's idiom test decides; `-Vibrator NO` (or `YES`) stands in for the
  device in a debug run.
- **Audio focus**, matched to the iOS build's ambient session: the player's
  own music wins. Coming to the front with another app's music playing, the
  game takes no focus and keeps its soundtrack quiet (its sounds still mix
  in); otherwise it takes focus for the soundtrack and steps aside when
  another app takes it, and everything waits through a call
  (`AudioManager.audioFocusDidChange`). "Another app's music" is
  `isMusicActive()`, which counts the game's own stream too, so it's read
  only as the game comes back from a stop, when SDL has paused that stream;
  through a pause without a stop (a dialog or the shade's device controls
  over the game, a second launch intent) the game keeps its focus
  (`AudioFocusPolicy`, tested by `./gradlew testDebugUnitTest`). Asking on
  every resume once took the game's own soundtrack for another app's and
  faded it out until the app next went to the background.
- **Background and foreground**: the shell suspends audio, saves and pauses
  the frame loop as Android takes the window, and resumes them after; the
  soundtrack stops with the game.
- **Battery saver** is Low Power Mode: `ProcessInfo.isLowPowerModeEnabled`
  reads it and `NSProcessInfoPowerStateDidChange` is posted as it changes,
  so the frame rate is held to 60 as on iOS.

### The beta's level feed and solve log — on in beta builds

See **The beta's level feed and solve log** below.

### What Data Safety has to say

Purchases (Play Billing: the purchase and its history, for app
functionality), the Play Games player ID and profile (sign-in,
achievements) and the saved game (Play Games Saved Games: levels cleared
and settings, app functionality). No maker name or photo.
`Tools/Play/PLAY-CONSOLE-SETUP.md` §4 has the answers.

## The beta's level feed and solve log

As on Apple, a beta build plays the Level Designer's live level feed and
posts each clear to its solve log, and both come out with the Apple betas'
before the store release. No Data Safety or privacy policy change goes with
them: they never reach production (below). (Off from 2026-11-13; the user
turned them on for the testing tracks on 2026-11-14.)

**The game's logic, ported where it must be.** `Platform/DesignerFeed.swift`
and `Platform/PlaytestLog.swift` are copies of the game's
`Source/Utils/` files, line for line but for what's listed at the top of
each: both ask the beta switch (below), since a store build reads no launch
arguments, and `PlaytestLog` watches the app's state with block observers
(Swift on Android has no Objective-C runtime for its `#selector`s) and
describes the device as Android's. `diff` either against its original to
see all of it; keep them in step.

- **The feed** (`GET /feed` on the designer's server) loads at launch while
  the splash waits for it (`DesignerFeed.whenAnswered`, as on iOS), and again
  whenever the game comes back to the front (`AndroidGameController`, as
  `SceneDelegate` does). The last good set is cached in the app's cache
  directory (`DesignerFeed.json`), else the bundle's levels play.
- **The solve log** (`POST /solves`) queues each clear in user defaults with
  its time over every visit since the level was last cleared, its replayable
  log and the device, and posts at launch, after each clear and back in front.
  Only clears post; a level left unsolved carries its time to the next visit.
  The device is Android's, from `MainActivity` (`AndroidDevice`): `device`
  "Google Pixel 6", `platform` "Android", `os` "17" (the designer shows
  "Android 17"), `simulator` for an emulator; the battery and the connection
  come from `DeviceServices.java` (`ACCESS_NETWORK_STATE`, a normal
  permission), the version and build from the APK. A player signed in to
  Play Games is named by their Play Games ID and name (`player` `pg:<id>`,
  `alias` their name: Java sends both just after each sign-in, `identity`,
  and `GKLocalPlayer` holds them), as Game Center's are on iOS (`gc:<id>`);
  signed out, a record names its install (`anon:<id>`), as a signed-out iOS
  build does.
- **FoundationNetworking and CoreFoundation.** `URLSession` comes in through
  Compat's `CryptoKit` (the feed's only other import), and the `CFBoolean`
  check `JSONText` uses for a level's fingerprint through PlatformShim
  (`CoreFoundationTypes.swift`), so `true` fingerprints as the designer's does.
  `GameKit` and `Network` are Compat stand-ins for the solve log alone.

**Beta builds.** Play can't tell an app which track installed it, so the
build says: `-Pswitchlings.beta=true` for every testing track (internal,
closed, open), `-Pswitchlings.beta=false` for production. A release build
must name it (`checkBetaChoice`); a debug build is a beta unless told
otherwise. Gradle writes it into the base module's assets
(`SwitchlingsBuild.json`), `MainActivity` puts it in the environment
(`SKA_BETA`, read by `BetaBuild`), the shell logs which it is at
launch ("beta build: …" / "not a beta build: …"), and
`Tools/Play/play.js release` refuses to upload a build that isn't a beta. A
production release is its own `false` build, never promoted from a testing
track (`Tools/Play/README.md`, "Beta builds").

**Launch arguments** work as on iOS in a debug build: `-DesignerLevels NO`,
`-Playtest NO|YES`, `-DesignerServer <url>`. With beta off the shell adds
`-DesignerLevels NO` and `-Playtest NO` unless the launch names them.
**An emulator records nothing** unless given `-Playtest YES`, as an iOS
simulator records none: `MainActivity` spots one by its goldfish or ranchu
hardware or an SDK image's fingerprint, and the shell adds `-Playtest NO`.
Its records, if told to post, say `simulator: true`, which the hosted server
drops anyway. Never post test solves to the production server: point a test
at a local one.

```bash
node Android/Scripts/launch.js --package com.fleon.switchlings -- -DesignerServer http://10.0.2.2:46198 -Playtest YES
```

## Native debug symbols

The game is almost all native Swift, so Play vitals can only read a crash or
ANR stack against the libraries' symbols. A release bundle carries them:

- `Scripts/build-shell.sh` strips a `--debug` build's libraries as it stages
  them, as before, but stages an optimised build's (`--store`, and the
  frame-time builds) with their symbols and DWARF.
- The release build type sets `ndk { debugSymbolLevel = "FULL" }`
  (`App/app/build.gradle.kts`), so `bundleRelease` strips the libraries for
  the APKs itself (the same `llvm-strip --strip-unneeded`, from the NDK at
  `ANDROID_NDK_HOME`, which it fails without) and puts each one's debug
  sections in `BUNDLE-METADATA/com.android.tools.build.debugsymbols/<abi>/<lib>.so.dbg`.
  Play keeps those and never sends them to a device; it matches them to a
  crash's frames by each library's build ID.
- The debug build type keeps the staged libraries as they are
  (`keepDebugSymbols`), so `assembleDebug` needs no NDK and the pool
  emulators' install is as quick as before.

FULL rather than SYMBOL_TABLE: it adds file and line numbers, and is smaller
too, since a `.sym` keeps each library's code and a `.dbg` only its debug
sections. Measured on 1.1 (54), both ABIs, `--store`:

| | AAB | symbols in it (compressed) | arm64 split APK | x86_64 split APK |
|---|---:|---:|---:|---:|
| before (stripped by `build-shell.sh`) | 227.3 MB | none | 81,114,791 B | 83,506,795 B |
| SYMBOL_TABLE (40 `.so.sym`) | 297.0 MB | 69.6 MB | same | same |
| FULL (40 `.so.dbg`), what ships | 285.5 MB | 58.2 MB | same | same |

The APKs bundletool makes from the bundle hold the same libraries, byte for
byte, as before (no `.symtab`, no debug sections), so the download a device
gets is unchanged; only the upload grows. `play.js release` checks a bundle
for a symbol file per library and says which are missing, as a bundle built
from `--debug` libraries would be. Builds already on Play (1.1.1 (55),
1.1.2 (56)) keep Play's "Native code without debug symbols" warning until
they're replaced. Play's other warning, "No deobfuscation file", is for R8's
`mapping.txt`; the app doesn't use R8, so there's none (`play.js release
--mapping` passes one through if it ever does).

To look at a symbolised stack locally, `ndk-stack -sym` takes the
`.dbg` files' folder for an ABI (unzip `BUNDLE-METADATA` from the bundle).

## Toolchain

Swift 6.4.2 (open-source, via swiftly — Xcode's Swift cannot cross-compile),
the `swift-6.4.2-RELEASE_android` SDK bundle, and Android NDK LTS r30 at
`$ANDROID_NDK_HOME`. See
<https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html>.

## The game's own scenes

The app plays as the iOS game does, from launch: Fleon Labs' splash, the
loading screen, the title (its wordmark, drawer, showcase and banner), the
world list (its pages, sheet, level strip and previews), a level with its
whole HUD (back, settings, the level code, the tip, undo, restart, hint and
help), the win card with its Next, Level Select, Replay and Share, and the
settings with their tabs. **219 of the game's 236 files** compile into
`GameCompat` unchanged, symlinked at the same paths they have under
`Source/` (`Title/TitleScene.swift`, `Game/GameScene.swift`, …).

Left out, each for a reason of its own:

| `Source/` file | why | what stands in |
|---|---|---|
| `AppDelegate`, `SceneDelegate`, `GameViewController` | the Apple app's own entry, window and controller | `Android/AndroidGameController.swift`, `GameViewControllerProtocols.swift` (below) |
| `Utils/GamepadInput.swift` | observes `GCController` through `#selector`, which needs the Objective-C runtime | `Android/GamepadInput.swift`: the same `Action`s, mapping, thresholds and repeat, fed by SDL's gamepads |
| `Utils/ShareSheet.swift` | `UIActivityViewController` | `Platform/ShareSheet.swift` (Android's chooser, from the share films) |
| `AudioManager`, `StoreManager`, `GameCenterManager`, `ICloudSyncManager`, `HapticsManager` | AVFoundation, StoreKit, GameKit, iCloud, haptics compiled for iOS only and offered on phones alone (Android offers them wherever there's a vibrator) | `Platform/` (the platform ring) |
| `Utils/DesignerFeed.swift`, `Utils/PlaytestLog.swift` | the beta switch, which a store build can't read from launch arguments; `PlaytestLog`'s `#selector` observers | ports in `Platform/`, the game's logic line for line (**The beta's level feed and solve log**) |
| `Common/Components/GameCenterIcon.swift` | Game Center's mark, on a button that opens Play Games here | `Platform/GameCenterIcon.swift`: Play Games' mark (below) |
| `HeaderVideo/*`, `EventVideo/*` | the Mac's filming tools, debug only | nothing |

### The controller

`AndroidGameController` is what `GameViewController` is on Apple, and keeps
its decisions where they are game logic: `launch(link:)` starts what
`AppDelegate` starts, in its order; the first layout presents the splash,
whose `onReady` goes through `TransitionManager` to `initialDestination`
(launch arguments, a world link or a friend's level, else `ResumeScreen`),
copied with `resumedDestination` from the Apple file. `layout(…)` is
`viewDidLayoutSubviews`: the view's size in points, the safe area from SDL
(`SDL_GetWindowSafeArea`), which way up, the idiom (a tablet by Android's
own rule, a smallest width of 600 dp) and the display's refresh rate, which
caps the frame rates on offer (`DisplaySettings.screenMaximum`). The view
has a window now, the game's own `TouchOriginWindow`, so panels zoom out of
the last touch, and `SceneLayout` takes its windowed path: Android's corner
radii are not in `DesignSystem.displayCornerRadii` (Apple's screens), so a
phone with a gesture bar gets the game's own fallback radius, as an
unlisted iPhone does.

Input, as the Apple controller routes it:

- **Touches** reach the scene through the window (`UIWindow.sendEvent`, then
  `SKScene.deliverTouch`), one finger at a time as the game asks of its view
  on iOS (`isMultipleTouchEnabled = false`). A touch hides gamepad focus.
- **Back** (button or gesture) is Escape, as Apple TV's remote Back is: it
  closes a popup or goes back, and leaves the game only from the title or
  the splash (to the background, as back from a launcher app's first
  screen). Android 16 no longer sends a back key to an app that targets it
  (predictive back), so `MainActivity` registers an `OnBackInvokedCallback`
  that hands SDL the key; older versions send it themselves, and SDL's trap
  hint keeps them from finishing the activity.
- **A hardware keyboard** reaches `KeyboardControllable` by HID usage (SDL's
  scancodes are that table), so the digits tap Switchlings and U undoes.
- **Gamepads**: SDL's gamepad events become `GamepadEvent`s (`GamepadBridge`
  in the shell), which `GamepadInput` turns into focus moves and presses
  through the game's own `FocusNavigator`.
- **Typing** (the Level Designer's friend code) goes to a `UITextField`
  stand-in over SDL's text input; the field's delegate sees each insertion,
  backspace and Return as UIKit hands them over. See **The players' Level
  Designer** for the keyboard's frame, Paste and links.

### What the shell gives the game

- **Its resources through `Bundle.main`** (`ResourceBundle`): rigs, levels,
  fonts and each language's `.lproj` (staged by Gradle under `lproj/`) are
  copied out of the APK into the cache the first time each is asked for in
  a run. `LevelCatalog` loads the bundled levels as on Apple, without the
  replay of every solution the old `AndroidLevels` door made.
- **The device's language** (`SDL_GetPreferredLocales` → `AppleLanguages`),
  matched as Apple matches it: corelibs' `Bundle.preferredLocalizations`
  picked Indonesian for `en-US`, so the shim has an overload the game's call
  prefers (`LocalizationMatch`, checked against Apple's for twenty locales).
- **Saved data that lasts.** corelibs keeps `UserDefaults` in memory only on
  Android (the process is `app_process`, with no bundle identifier), so the
  shell writes the game's values to `defaults.plist` in internal storage
  every five seconds and whenever the app goes to the background, and reads
  them back at launch (`GameEnvironment`). Progress, settings and
  `ResumeScreen` survive a relaunch.
- **Launch arguments**, from the intent, in the argument domain and
  `ProcessInfo.arguments`, where `LaunchArguments` reads them (debuggable
  builds only, as on Apple): see **Launch arguments, and the parity sweep**.
- **Leaving the game**: `UIApplication.open` (`SDL_OpenURL`), the clipboard,
  keeping the screen on (`SDL_DisableScreenSaver`).

### The concurrency settings are the app's

`GameCompat` builds as the Xcode target does: Swift 5, main-actor isolation
by default and Approachable Concurrency (`Compat/Package.swift`). The game
depends on it — `TitleScene` calls the explicitly `@MainActor` `SettingsFlow`
from its own methods. So the shim's `SKNode`, `UIView`, `UIWindow`,
`UIScreen`, `UIViewController`, `UITouch` and `UIEvent` are main-actor
isolated, as Apple's are (they descend from `UIResponder`), and so are the
shell's frame loop, renderer and controller, which share SDL's thread with
the game. `SDL_main` enters with `MainActor.assumeIsolated`, which holds
there because the main actor's executor is the frame loop's
(`MainActorJobs`). Where SpriteKit runs scene code off the main thread
unchecked (a share film's `SKRenderer`), the shim says so explicitly
(`mainActorUnchecked`).

One more flag: on x86_64 corelibs' `CGFloat` has a `Float80` initialiser,
and `MechanicSampleNode.opaqueBounds` then takes the type checker past its
default scope limit, so `GameCompat` passes `-solver-scope-threshold`.

### What the scenes needed from the shim

Each with host tests (`SceneSupportTests`, `BlendModeTests`), checked
against Apple's own where Apple's runs on the Mac:

- `calculateAccumulatedFrame()` is SpriteKit's: in the parent's space, hidden
  and transparent descendants included (measured on the Mac). Dropdowns find
  their anchor and samples their icon through it.
- A 9-sliced sprite keeps its caps when scaled, as SpriteKit's does: the
  borders are fitted to the sprite's own size, then kept while its scale
  stretches the middle. The meter's fill at a small fraction is a pill, and
  so is the world list's current page dot (an 8-point dot from a 16-point
  texture, stretched 3× across).
- Actions keep SpriteKit's clock (measured on a Mac's `SKView`): a scene's
  first frame after it's presented counts no time, however long it took,
  and a frame longer than a second counts none either (dropped, not
  clamped). Without it the frame that presents a level, slow while it
  draws for the first time, ran out the tip sample's 0.2 s wait before its
  rigs had a frame: their meshes hadn't attached their shader, so the
  snapshot held only the arrows and the text column started 19 points too
  far left (`ActionClockTests`).
- `SKSpriteNode`'s designated initialiser is `init(texture:color:size:)`, as
  SpriteKit's (`GlowNode`, `ConveyorNode` call it); an untextured sprite
  draws its own colour, its alpha included (a clear one draws nothing).
- Crops draw their mask and contents where the crop stands, and a shape can
  be a mask (the scroll areas' rounded clips, through an alpha-cut coverage
  program); an effect drawn in place carries its transform. Without these
  the level strip, the banner's text and the rigs in it were missing or
  misplaced.
- Actions: `rotate(toAngle:duration:shortestUnitArc:)`, `colorize`,
  `setTexture`, `reversed()`; timing modes on **SpriteKit's measured
  curves** (ease in `2t² − t³`, ease out `t + t² − t³`, both smoothstep, read
  back from `SKRenderer` on the Mac). Every action hands on the time a
  frame runs past its end, as SpriteKit's does: a sequence to its next step,
  a group what its longest child left, a repeat to its next round (several
  in one long frame). A step finishes as its time is reached exactly, but
  what follows starts only on time left over, so a `.run` after a step that
  ends right on a frame runs on the next one; a group runs a finished child
  no more (`ActionTimingTests`, each case measured with `SKRenderer`).
- Paths: `addArc(tangent1End:tangent2End:radius:)`,
  `copy(dashingWithPhase:lengths:)` and `currentPoint`, checked against
  CoreGraphics. The software context has every CoreGraphics blend mode, the
  four non-separable ones and the two plus modes included (and soft light
  is CoreGraphics' formula, not the PDF's).
- `SKTexture.cgImage()`, a snapshot's pixels read back from the GPU, and
  alpha-only bitmaps: the collection and the tips fit each sample by what it
  draws.
- `SKShapeNode`'s shape initialisers, `simd_quatf` (Starry Sky's planet
  block), `NSHashTable`, `SHA256` (a Level Designer board's fingerprint, the
  same bytes as CryptoKit's), CGFloat rounding, `UIImage(data:)` and
  `draw(in:)`.

### Stand-ins, every one

Things with no Android meaning, or none yet, keep the game's shapes and say
so where they are declared:

| stand-in | where | what it does |
|---|---|---|
| `Storefront.current` | `Compat/Sources/StoreKit` | nil: no App Store storefront. The App Store link `SolutionShare` builds from it never leaves the device: Android's `ShareSheet` swaps it for the game's Google Play page in the game's language (`PlayStorePage`, `ShareRequest(items:storePage:)`) |
| `UIDevice.batteryLevel` | `UIKitInput.swift` | unknown, as a simulator reports |
| `UIApplication.connectedScenes` | `UIKitInput.swift` | empty |
| `CTFontManagerRegisterFontsForURL` | `CoreTextCompat.swift` | true: the shell registered the fonts already |
| `SKShapeNode.strokeShader`, `SKSpriteNode.normalTexture` | shim | carried, not drawn: the game sets neither in a way that shows |

**The version line** reads the APK's own: `MainActivity` puts its
`versionName` and `versionCode` in the environment before the Swift
libraries load, and the shim's `Bundle.infoDictionary` answers with them
under Apple's keys (`BundleInfo.swift`). It shadows Foundation's member,
which a module may do for a module it imports, so the game's
`Bundle.main.infoDictionary` reaches it unchanged. (`Bundle.main` itself is
`/system/bin`, the process being `app_process`, and CoreFoundation ignores
`CFProcessPath` in an app process.)

The emulator draws a few frames a second when the host is loaded, which is
the host's, not the game's.

**A point is a dp.** The view's points are the display's density-independent
pixels (`SDL_GetWindowDisplayScale`, dpi / 160), as an iOS point is its
screen's: a 420 dpi Pixel 6 is 411 × 914 points beside the iPhone 17 Pro's
402 × 874, so every popup, sheet and button takes the same share of the
screen as on iOS.

**The safe area is iOS's.** `MainActivity`'s surface reports the system bars
and the display cutout, and at the bottom the gesture-navigation handle (as
iOS counts its home indicator); SDL's own adds the back-gesture edges, about
30 dp a side, which made every screen 60 points narrower. With a bottom
inset, the game's own corner fallback (`displayCornerRadiusFallback`) applies
to an Android phone, as to an unlisted iPhone, so the corner buttons stand
where they do on iOS. Android's real corner radius is often much tighter —
the Pixel 6 emulator reports 28 px (11 dp) — so they stand further in than
the screen strictly needs, as on an iPhone. The art's export scale (3x) has no say in it; its textures
are drawn at 2.625 pixels a point, and glyphs, surfaces and effect textures
are rendered at the screen's density.

The scene graph can be dumped on a device to find what draws where:
`adb shell setprop debug.switchlings.dump <a new value>`, then
`adb shell run-as com.fleon.switchlings.scenes cat cache/scene-dump.txt`.

## Render-to-texture, and one backdrop

`SKEffectNode` and `SKCropNode` composite for real, and Starry Sky's
backdrop draws on a device — `Source/Common/Components/NightSkyNode.swift`
(972 lines), symlinked into `Compat` and compiled unmodified, with
`Theme.swift`, `WorldTheme.swift` and `ColorHelpers.swift` beside it, and
`BandedLayerNode`, which is the game's line for line but for its band count
(`Compat/Sources/GameCompat/Android/BandedLayerNode.swift`: a band count
the debug property can change, below).

Three things in the renderer are decided rather than inherited:

- **`gl_FragCoord` counts down from the top left.** SpriteKit runs on Metal,
  where it does; GLES counts up from the bottom. The game depends on Metal's
  — `SceneLighting` hands every lit shader `(visible.minX, visible.maxY,
  pixelsPerPoint, 0)` and recovers a scene point as `u_fragment.xy +
  gl_FragCoord.xy * u_fragment.zw`, which only lands on the board if y runs
  down, and `EdgeShade.Blur` writes `vec2(gl_FragCoord.x, -gl_FragCoord.y)`.
  `ShaderTranslator` rewrites the identifier to a call over one uniform, so
  every lit world and the edge blur are the right way up without touching
  the 31 files that read it.
- **A draw counts the pixels of the target it draws into.** What an effect
  node holds draws into its texture and counts that texture's pixels (why
  `SceneLighting.screen` exists); the effect's *own* shader runs as it is
  composited and counts the pixels of the target it lands in — the screen
  for the backdrop's edge blur, the crop's texture inside a crop node,
  which is why a crop node round an effect node moves the blur band. (This
  ring corrected the composite, which first counted the effect texture's
  pixels and so shifted the band by the backdrop's overscan.)
- **`shouldRasterize` keeps its pixels.** `BandedLayerNode` redraws one band
  a frame by toggling it, so the shim bumps a generation on every write and
  the draw list carries a digest of what the subtree draws — transforms and
  textures, deliberately *not* shader uniform values, or a band would redraw
  every frame as `u_time` moved and the cache would be a loss.
- **The edge blur blurs only its bands.** SpriteKit's way, the whole
  backdrop through a texture of its own and then onto the screen through
  `EdgeShade.Blur`, is a full-screen store and reload a frame on a tiler.
  `BandBlurPlan` reads the blur's uniforms and plans it instead: each band
  (and as far round it as the taps reach) drawn as a strip on the target's
  own pixel grid, the strips sharing one texture drawn in one pass (each its
  own viewport: a pass a strip cost the M31 more than the full-screen pass
  saved), the backdrop drawn straight into the target, scissored to the
  pixels outside the bands, and each strip composited onto its band through
  the same shader, `u_span` rescaled to the strip. The contents report the
  effect texture's `gl_FragCoord` wherever they draw. On the M31 (Starry Sky,
  render scale 0.5) it's within run-to-run noise of the full-screen pass, a
  millisecond or two faster at best.
  The full-screen pass stays where that can't draw the same picture: an
  effect node that fades, blends otherwise or is scaled, one inside a crop
  node or holding crops or shaded effect nodes of its own, bands covering
  most of the screen (`-BlurBackdrop`), films and bakes, and
  `debug.switchlings.bandblur off`.

### Adreno: nothing mapped unsynchronised

A Nothing Phone (3a) (Adreno 710) drew The Mainframe's world page with
level coins showing other frames' numbers, the Edit button's label cut to
"Ed" or gone, and bands of the glyph atlas smeared over the coin strip;
Samsung Remote Test Lab's Galaxy S23 (Adreno 740) did the same. Text and
shape masks were written draw by draw, each through an unsynchronised map at
the next offset of a buffer orphaned once a frame, and Qualcomm's driver
let those writes land over data draws still to run would read: a label drew
with another frame's quads, or with the coin strip's crop-mask quad over its
glyph page. Mali forgave it. Now the frame writes everything, text and masks
included, into its stream at once (`SceneRenderer.stage`, labels and shapes
made into runs first by `resolveCoverage`), the stream's one map is
synchronised (on a store just orphaned, so it never waits on a driver that
honours the orphan), and the few draws still written as they come (bakes, a
kept target drawn again) give their buffers their own data with
`glBufferData`. `debug.switchlings.poison` (debug builds) makes a forgiving
GPU harsher: `targets` fills every off-screen target with junk before its
clear, `stream` keeps the frame's store rather than orphaning it.

### What the emulator says, and what it does not

Measured on the shared `ska_shell` AVD, which reports
`Android Emulator OpenGL ES Translator (Apple M4 Max)` — it passes through to
the host GPU, so **the frame times flatter a phone and the draw-call and
render-target counts do not**. 1080×2400, a six-by-five board of Sky's
bricks, 300-frame windows after a 60-frame warm-up:

| scene | frame p50 | in `drawFrame` | scene graph | draw calls | target binds |
|---|---|---|---|---|---|
| board only, no backdrop | 16.9 ms (59 fps) | 7.3 ms | 0.53 ms | 15 | 1 |
| sky, banded (4 bands) | 21.5 ms (47 fps) | 14.4 ms | 0.87 ms | 21 | 3 |
| sky, whole every frame | 18.1 ms (55 fps) | 11.8 ms | 0.77 ms | 17 | 1 |

Read these as: the port's own CPU cost is **under a millisecond** and is not
the problem; the sky's shader is the whole of it. And `BandedLayerNode` is a
**loss** here — four bands cost 4 extra draw calls, 2 extra target binds and
a composite each, to save three quarters of a shader that this GPU runs
easily. On an A14 iPad, where the shader is the bottleneck, it wins, and on
a real phone it wins by far more (below): the emulator's verdict was the
host GPU's, not a phone's.

### Banded layers on the M31

On the Galaxy M31 (Mali-G72 MP3, optimised build, render scale held at 0.5,
each world's 12th level auto-solving a move every 1.5 s), banding is the
biggest single saving the port has: drawn whole, Castle and Reef run at
under half their frame rate and Ruins at not much more. More bands win more, since the GPU is the
whole of a frame and a band switch costs next to nothing beside an eighth of
a full-screen lit shader, so the port drew every banded layer in 8
(`BandedLayerNode.bandCount`), where the game drew 4 (Castle's sea behind
gameplay 6). Since 2026-11-17 both draw every layer in **4**, as the owner
chose; the measurements stand for reference. Frame p50 in milliseconds, the median of every 300-frame window
wholly inside the level over the runs counted (alternating modes, the same
build); 16.7 ms is the screen's 60 fps:

| world | whole | 4 bands | 6 bands | 8 bands |
|---|---|---|---|---|
| Starry Sky | 48.2 (4 runs) | 36.2 (4) | 37.9 (1) | **34.2** (3) |
| Cloud Castle | 43.1 (4) | — | 18.4 (4, its default) | **17.2** (3) |
| Coral Reef | 49.8 (4) | 18.6 (4) | 16.7 (1) | **16.7** (3) |
| Bug Woods | 20.1 (3) | — | — | **16.7** (3) |
| Flooded Ruins | 29.4 (3) | — | — | **16.7** (3) |

Against 4 or 6 bands, 8 cost 1–12 more draw calls and up to 20 more nodes a frame,
with the same target binds (Sky 152 → 157 calls, Reef 115 → 126) and the
same texture memory (the bands still add up to the layer). Drawn whole,
they take 3–12 fewer calls and 2–6 fewer binds than in 4 bands, and the
frame thread's CPU time is 0.2–3 ms *higher* (the GPU it waits on is
busier). Sky's runs
swing about 2 ms, so 8 bands there is likely, not surely, faster than 4; the
rest repeat to a tenth of a millisecond. Each band redraws every 8th frame,
under 0.15 s apart at 60 fps; what these layers show drifts slowly enough
that it can't be seen, as Castle's 6 already showed on iOS.

`adb shell setprop debug.switchlings.bands whole` draws them whole, and a
number in that many bands (read at launch; `''` for the default), for
measuring.

## Warps

`SKWarpGeometryGrid`, `SKWarpable` (`warpGeometry`, `subdivisionLevels` on
sprites and effect nodes) and the warp actions (`warp(to:duration:)`,
`animate(withWarps:times:)` and its `restore:` form) are in
`Sources/SpriteKitShim/SKWarpGeometry.swift`, with SpriteKit's signatures.
`BackdropWarp.swift` and `BackdropTouch.swift` compile unchanged. A warped
sprite's grid rides on `DrawList.Sprite.warp`, and `SpriteBatcher` draws it
as `WarpMesh`'s triangles instead of one quad — the same vertex layout, so it
still batches with plain sprites of its texture.

How SpriteKit draws a grid was measured, not guessed: a sprite whose texture
encodes its own texel in red and green, warped by SpriteKit on macOS and
rendered through `SKRenderer`, then fitted against candidate meshes.

- Each cell is cut into 2^`subdivisionLevels` × 2^`subdivisionLevels`
  smaller cells whose corners are **bilinear** in the cell's four vertices,
  source and destination alike. No smoothing spline: vertices stay put.
- Levels past 3 draw exactly as 3. The default is 2, which the game never
  changes.
- Each small cell is two triangles, split bottom left to top right.
- A grid whose destination is the untouched regular grid is not subdivided.

`WarpGeometryTests` holds 199 of those measured pixels and checks the mesh
lands within a texel of every one, at levels 1 and 2, with the source and
the destination moved; the coarser mesh misses them by several texels, so the
fixture tells levels apart. The actions were measured the same way, reading
`warpGeometry` back from a scene ticked by `SKRenderer`: every vertex moves
in a straight line, a keyframe list blends from the node's own warp to the
first pose by the first time, and a node with no warp — or one of another
shape — takes the first pose at once.

A pose changes every frame (the crowns, plants and wings loop through
theirs without rest), so the batcher writes a warped sprite's mesh straight
into the batch (`addWarp`: `WarpMesh`'s vertices and triangles, in its order,
carried through the sprite's frame and transform in one affine step)
instead of building a `WarpMesh` of its own each frame, and a warped sprite
culls by where its grid reaches (`WarpMesh.bounds`: no vertex of the mesh
lies outside its grid's destination), so the crowns off the screen's edges
cost nothing. On the Galaxy M31 that took the scene's CPU time (ticking,
flattening, batching) in Bug Woods from 5.98 to 5.06 ms a frame mid-level
and from 6.91 to 6.29 on its world page, all but what removing every warp
saves (5.00), and Sunny Garden's from 4.00 to 3.78; on an A14 iPad,
SpriteKit's own warps cost nothing measurable.

The two gaps outside the warp code that this found are closed: a repeat
carries what a frame runs past a round's end into the next, and every timing
mode runs on SpriteKit's measured curve (see **The game's own scenes**).

Android's libm overlay has no `Float` overloads of `sin`, `sqrt` and the
rest, which Darwin's has; `BackdropWarp` mixes them with `SIMD2<Float>`, and
the type checker gave up on the expression. `FloatMath.swift` supplies them.

The lawns show it in the game: `-StartLevel garden-1` or `meadow-1`
(crowns stirring, plants swaying, butterflies' wings), and a tap on the
scenery bends it through `BackdropTouch`.

## Scene changes: the view, its camera and its transitions

The game changes scene the way it does on Apple: `TransitionManager`,
`LoadingScene` (with `CharacterNode`, `BrickRunNode` and
`LoadingSpinnerNode`) and `SceneLayout` compile here unchanged, so the app
opens its first level through the real loading screen — a fade to black,
the Switchling hopping along its world's bricks while the level builds off
the main thread, a fade into the level — and a cleared level opens the next
the same way. `-StartLevel garden-3` picks the first one.

**The view** (`SKView.swift`, `UIKitView.swift`). `SKView` is a `UIView`
here as on Apple, with what the game reads off one: `bounds` **in points**
(the shell divides the drawable by the art's scale; the game sizes every
scene from `bounds`, so pixels would make each one three times too big),
`contentScaleFactor`, `safeAreaInsets`, `traitCollection`, a `window` (nil:
`SceneLayout` then takes its square-cornered path) and `convert(_:to:)`.

**Transitions** (`SKTransition.swift`). `presentScene(_:transition:)` swaps
at once, as SpriteKit does: the old scene hears `willMove(from:)`, the new
one becomes `view.scene` and hears `didMove(to:)` before the call returns.
The old one stays in the view, drawn and — unless `pausesOutgoingScene` —
updating and running its actions, until the transition lands; the new one
runs unless `pausesIncomingScene`. Both default to true, as on Apple; the
game turns both off. A scene presented mid-transition ends that one where
it stands. The view composes both scenes into one `DrawList` in the
incoming scene's coordinates, so scenes of different sizes and anchors (the
loading screen is anchored in its middle, a level is not) meet in the view
rather than in scene space. Kinds: `fade(withDuration:)` (through black, the
game's one), `fade(with:duration:)`, `crossFade`, `push`, `moveIn` and
`reveal`; each scene draws its `backgroundColor` over the whole view first.
A translucent scene is one `.effect` command, so it fades as one picture
through the renderer's render targets.

**The camera** (`SKCameraNode.swift`). The game's own scenes never set one
(only the Mac's video tools do), but the view's mapping runs through it:
`DrawList(scene:transform:)` draws the scene through
`SKScene.cameraTransform` — the camera's position in the middle of the view,
its scale and rotation undone, its children fixed on the screen — and
`convertPoint(fromView:)`/`(toView:)`, which the renderer now maps touches
through, undo it. `contains(_:)` and `containedNodeSet()` test against what
the view shows. `SKScene.visibleRect` is the one place the visible rectangle
is worked out; `GLESRenderer.Viewport` projects with it.

**The delegate and the frame loop.** `FrameRenderer.shouldDraw(_:)` is asked
before every frame; `SceneRenderer` answers with `SKView.shouldRender(atTime:)`
— not while paused, no sooner than `preferredFramesPerSecond`, and only if
the delegate's `view(_:shouldRenderAtTime:)` agrees. A frame skipped is
neither updated, drawn nor swapped, so the screen holds what it showed, and
the next one's `delta` covers the gap. On Apple that method is an
Objective-C optional requirement, and `FilmDrawTurns` asks it as
`forwarded?.view?(view, shouldRenderAtTime: time)`; with no Objective-C,
`SKViewDelegate` gives it a default and keeps that spelling with a property
named `view` holding a callable value, so the game's line compiles as it is
(`ViewTests` has a copy of `FilmDrawTurns`' shape).

**Main-actor work.** `Task { @MainActor in … }` — how the loading screen
hands back the scene it built — never ran on Android: the main actor's jobs
go to libdispatch's main queue, which nothing on SDL's thread drained.
`MainActorJobs` gives the main actor an executor of its own, a queue the
shell runs at the top of every pass of its loop, on SDL's thread. The
runtime is told through `swift_task_getMainExecutor_hook`, set in C
(`ska_set_main_executor` in `CAndroidShell`), because its functions
pass a two-word struct in Swift's calling convention; the enqueue hook beside
it is never reached for the main actor since Swift 6.2, and SE-0469's
`ExecutorFactory` is not public in the 6.4 Android SDK. The shell logs
`main actor: jobs run on the frame thread` once it takes.
`DispatchQueue.main.async` (`BuildGate`'s deferred light updates,
`FilmDrawTurns` handing its turn back) is the share-film work's to drain.

**Debug properties** for filming and checking scene changes on a device,
each read once at start-up (`adb shell setprop …`, then relaunch):

| property | effect |
|---|---|
| `debug.switchlings.autosolve 1` | each level plays its stored solution, then opens the next through the loading screen |
| `debug.switchlings.transitionslowdown 25` | transitions only, 25 times slower (an emulator draws a few frames a second, so a 0.1 s fade shows no frames between) |
| `debug.switchlings.slowdown 8` | every action and transition, as `-AnimationSlowdown` |
| `debug.switchlings.programcache off` | links every program from source, keeping none (`clear`: deletes the kept programs first, every launch while it's set) |

logcat says when each scene arrives and when its transition lands
(`scene LoadingScene at 13.462, transition playing`), and when each first
draws (`[timings] WorldSelectScene first frame 12.807 s after launch, 4111 ms
after the last scene's, 4192 ms after the last input; programs: …`: from the
process's start, the scene before and the last touch, key or button, with the
program cache's count so far), then the launch's longest frame and its frames
of 50 ms or more once its first 30 s have passed (`LaunchTimings`).

## Share films

A cleared level's Share films its solution as iOS does: `SolutionFilm`
builds a stage off the main thread, renders each frame off screen through
`SKRenderer`, encodes it as it goes, mixes the soundtrack and opens the
share sheet with the file. **`SolutionFilm.swift`, `FilmSoundtrack.swift`
and `MediaClock.swift` compile here unchanged**, and so do the wordmark over
the board (`TitleLogoNode`, `WordmarkLayout`, `WordmarkLayouts`), the
credit and code under it (`CreditNode`, `LevelCodeNode`, `ShadowLabelNode`)
and, with them, the real `Localization.swift` and `LocalizedString.swift`
(every string its English fallback until the APK carries the `.lproj`s).

```bash
adb shell am start -n com.fleon.switchlings.film/com.fleon.switchlings.MainActivity \
    --esa args "-StartLevel,garden-1,-AutoSolve,-AutoShare,-ShareFrameRate,60"
```

`-ShareFormat image`, `-ShareFrameRate 30`, `-ShareOrientation landscape`
and `-ShareLink NO` are the form's other choices. Without `-AutoShare` a
cleared level shows a Share button (a tap elsewhere goes on).

### The Apple surface, and what stands in for it

| the film calls | on Android |
|---|---|
| `SKRenderer` `update(atTime:)`, `render(withViewport:commandBuffer:renderPassDescriptor:)` | `Sources/SpriteKitShim/SKRenderer.swift`: the view's own update (the scene's `update`, then its actions by the time since the last), then the scene flattened into a `DrawList` value, recorded into the command buffer |
| `MTLDevice`, queue, command buffer, render pass, textures, `waitUntilCompleted` | `Metal.swift`: a command buffer is the passes recorded into it; `commit` hands it to `MetalExecution.executor`, `waitUntilCompleted` blocks on it |
| `CVPixelBuffer`, its pool, `CVMetalTextureCache` | `CoreVideo.swift`: CPU memory in the format it says (32-bit BGRA); a texture made over one is where a render lands |
| `AVAssetWriter` + H.264 input + pixel buffer adaptor | `Sources/PlatformShim/Media`: each frame converted to BT.709 video-range YUV (`YUVConversion`) and encoded with MediaCodec into an MP4 (`Shell/Sources/CAndroidMedia`) |
| `AVAudioFile`, `AVAudioPCMBuffer`, `AVAudioFormat` | WAV read in Swift (`WAVFile`); AAC read through the soundtrack's own MediaCodec decoder, positioned by presentation time as the game's player is; AAC written through MediaCodec into an M4A, closed when the file goes |
| `AVMutableComposition` + passthrough `AVAssetExportSession` | MediaExtractor copying each track into one MediaMuxer, interleaved by time |
| `UIActivityViewController` (`ShareSheet.swift`) | `Compat/.../Platform/ShareSheet.swift`, the platform part: JNI into `MainActivity.shareFile`, `ACTION_SEND` with a `content://` URI from `FilmProvider` (androidx's `FileProvider` contract for the cache directory, without the dependency) |
| `UIImage.pngData()`, `draw(in:)`, `UIImage(named:)` | the shim's; the shell installs zlib for the PNG and cuts an image set from its atlas page |
| `UIApplication` active/inactive | `UIApplication.swift`, posted by the shell from SDL's background and foreground events |

The game's own module names resolve as `SpriteKit` and `UIKit` do: `Metal`,
`CoreVideo` and `AVFoundation` are targets in `Compat` that re-export these.

### Drawing on the view's context

There is one GL context and one thread that draws. A committed command
buffer waits in `FilmPasses` until the top of `SceneRenderer`'s next frame,
which draws each pass into a framebuffer with a stencil (#396's render
targets), through the same batcher, programs and texture cache as the
screen, then `glReadPixels` into the pixel buffer, turning the rows over and
swapping red and blue. No shared EGL context, no second upload of the art,
no second set of programs.

The film updates and records between the view's frames, holding
`FilmDrawTurns`' lock, which the view's delegate takes as each frame starts
(`SceneRenderer.shouldDraw` asks `SKView.shouldRender(atTime:)`, #404) and
gives back through the main queue. Committed film frames are drawn at the
top of `shouldDraw`, before the view takes its turn, and while a film is
being made the renderer waits up to 12 ms there for its next buffer, so the
film gets a turn every frame rather than losing the lock race every time. A
film therefore renders at most one frame per display frame: real time at
60 Hz, slower on a slow GPU (frames are timed by the film's clock, never the
wall's, so nothing in the film itself changes).

### `DispatchQueue.main` runs on the game's thread

Found on the way, and true of every ring: until this, nothing the game
queued on `DispatchQueue.main` ever ran on Android (#404 hooks the main
actor's own jobs, `MainActorJobs`; this is the queue itself, which
`FilmDrawTurns`, the film's progress and `ICloudSyncManager` use). libdispatch binds its main
queue to whichever thread runs its constructor, which was Android's UI
thread (`System.loadLibrary`), and nothing drained it. `MainActivity` now
leaves `libAndroidShell.so` to SDL's own `dlopen` on `SDLThread`, so the
queue is bound there, and `Shell.run` drains it once a frame
(`ska_drain_main_queue`). The shell logs "the main queue runs on
the game's thread" when it took.

### What the stage shows

`SolutionStage` is the game's own, and everything on it is too now: the
real `BoardNode` with every mechanic's art, the world's live backdrop and
light, and the real win card, whose Share opens the game's own form
(`ShareFormNode`, picture or video, frame rate, orientation, link) and
films through it into Android's share sheet. `FilmStubs.swift` and the
stand-in Share button are gone.

Android has no Game Center, so a film credits "A Switchlings player" with
one of the world's Switchlings, as iOS does signed out.

## Work off the main thread

The game builds scenes, world pages, backdrops, circuit floors and share
films on threads of its own while the main one draws, as on Apple, and
the port runs that as the game wrote it: the builds really do run on
libdispatch's workers (`offMainActor` is the game's own, an unchecked call
on the calling thread; `Task.detached`, `DispatchQueue.global` and
`Thread` all start threads here: `top -H` shows `DispatchWorker` threads
busy while a scene builds). A Linux thread takes the niceness of whoever
started it, so the workers came up at -2 or -4 beside `SDLThread`'s -4,
where Apple's QoS runs them below the main thread; libdispatch on Linux has
no QoS to ask for and no hook as a worker starts, so the frame loop watches
for new threads (`/proc/self/stat`'s count, then `/proc/self/task` when it
grows) and sets each `DispatchWorker` to niceness 9, an `AsyncTask`'s
(`WorkerPriority`; `adb shell setprop debug.switchlings.workernice off`, or
another value, for measuring). What the audit found was the shim putting
work back on the frame thread, or racing it:

| site | threads | on Android | verdict |
|---|---|---|---|
| `LoadingScene` builds the next scene (`DispatchQueue.global` + `offMainActor`, back with `Task { @MainActor }`) | worker, then main | builds on a worker; the main actor's jobs run on the frame loop (`MainActorJobs`) | OK |
| `SKTexture.preload` (the loading screen, `WorldTextures` for the world list and the title's tour, backdrops, the Level Designer) | the caller's | decodes the pages it names on the preloading thread (`PageDecodes`), turned bottom row first as it premultiplies; the frame thread uploads them a strip at a time ahead of their first draw (`ResourceCache.uploadAhead`), and builds the shaders the preloading thread made (below) | fixed |
| PNG unfiltering (`PNGDecoder`) | the frame thread | a byte-at-a-time `switch`; now a row at a time through pointers, byte-identical on all of the art's PNGs and 2.7× faster | fixed |
| `UIGraphicsImageRenderer` (`SurfaceTexture`, carets, credits, the circuit floor and lawns' masks off the main thread) | main and builds at once | **one context stack for every thread**: an image drawn on one could land in another's bitmap, and concurrent pushes tore the array (a crash in `ThreadingTests`); now per thread, as UIKit's is | fixed |
| `SKView.texture(from:)`, a baked texture's `cgImage()` | main | GL calls, current on the frame thread alone; any other thread is now refused with an error in the log rather than drawing into whatever was bound | guarded |
| World list pages, previews, backdrop planning (`pageQueue`, `previewQueue`), the title's boards, the designer's pieces and priming | workers, back by `DispatchQueue.main.async` | workers; `DispatchQueue.main` drained on the frame thread each pass (#401) | OK |
| `BuildGate` (`NSLock`s), the lights' and rigs' locks, `OSAllocatedUnfairLock` (an `NSLock` here) | main and workers | pthread mutexes; every lock is unlocked on the thread that took it, which a mutex needs | OK |
| `UISkin.using`, `UITraitCollection.performAsCurrent` | workers | the skin per thread (`threadDictionary`); the traits handed in are the global ones, so nothing is set | OK |
| `RouteSolver`'s hint map (`Task.detached`), the soundtrack mix | the cooperative pool | libdispatch's global queues | OK |
| `SolutionFilm` (`Thread`, `FilmDrawTurns`, `DispatchQueue.main.sync` to prime) | film thread and main | the film records off the main thread and the frame thread draws it; the lock is never held across a wait for the other | OK |
| `MTLCommandBuffer.waitUntilCompleted` | film thread | woke before the completed handlers had run; now after | fixed |
| `PlayBilling`, `PlayGamesAchievements`' `async` calls | **were** a libdispatch worker | Play's answers arrive on the frame thread, so the waiters raced it and Java was called from a worker; now on the main actor | fixed |
| `MediaTime`'s start | any | a `static let` | fixed |
| Text (`TextEngine`, `FontLibrary`, each face, `GlyphAtlas`) | main and builds | locked, each FreeType face behind its own lock | OK |

### The loading screen's warm-up, on a Galaxy M31

`LoadingScene` draws the next scene once offscreen before it fades to it
(`view.texture(from:)`), so its textures are on the GPU and its programs
built. On the M31 that one draw held the frame thread for 2.8–2.9 s going
into the world list, and the frames after it, a world list flick and opening
a level each froze for 0.5–2 s more. Broken down (`frame cost` lines and
simpleperf), it was mostly not GL at all:

- **Translating shaders**: `ShaderTranslator` broke each shader into
  `Character`s for every one of thirty words it checks, about a quarter of
  the frame thread's time; it works on UTF-8 bytes now (identical output,
  56 times faster), and shaders made from the same source and inputs share
  one program (`ResourceCache.programKey`), where every `SKShader` the game
  made (each tile's, each band's) was translated and linked again.
- **Batching**: the open batch was copied and written back for every
  sprite, its whole vertex array with it; the game primes its rig shaders
  behind 8,000 sprites (`AttributeShaders`), which took 1.2 s a time. Now
  in place: 8,000 sprites batch in 1 ms on a Mac, from 68.
- **Linking**: up to 220 ms a program on a cold shader cache (Mali keeps
  linked programs across launches, so a second launch barely links, until
  an update: see **Programs kept between launches**). The
  shaders a build makes on its thread are handed over as it preloads
  (`SKShader.programWarmer`) and linked on a second EGL context sharing the
  frame thread's (`GLBuilderThread`, `ProgramBuilds`), at niceness 0: the
  warm-up only waits for one still being linked. Where EGL can't share a
  context they're built a few a frame on the frame thread instead
  (`ShaderWarmQueue`). A shader whose uniforms change after its program was
  built is built again (`SKShader.revision`).
- **Pages**: turned over on the frame thread as they uploaded (150 ms of the
  warm-up); now as they decode. A page starts decoding as soon as a texture
  is made on it (`SKTexture.pageWanted`, `PageDecodes.prefetch`), which took
  the loading screen's own first frame from 0.9 s to 0.3 s.

Before (main) and after, optimised builds, launching into the world list,
four flicks and into a level (worst frame-thread stall, in ms):

| | cold shader cache, before | after | second launch, before | after |
|---|---|---|---|---|
| splash to loading screen | 2,163 | 299 | 2,658 | 276 |
| into the world list (warm-up and the frames after) | 2,791, 1,569, 916 | 223, 321, 378 | 2,889, 2,019, 565 | 255, 164, 144 |
| a world list flick | 516 | 153 | 569 | 93 |
| into a level | 819 | 105 | 1,064 | 89 |
| the loading screen up for | 10.4 s | 7.7 s | 12.4 s | 7.7 s |

A second pass, against every scene change (title to world list, world list
to a level, a level to its win card, the Level Designer):

- **Drawn surfaces and rig pages** (`SKTexture(image:)`, the game's
  `CGContext` drawings) the next scene shows are readied on the preloading
  thread and uploaded a few a frame before the warm-up (`TextureWarmQueue`,
  `ResourceCache.adopt`), as pages are, rather than decoded, turned over and
  uploaded in it.
- **Preloads waited for pages already decoding**: a page a texture's
  `pageWanted` had started was skipped by `PageDecodes.decode`, which
  returned before it was done, so the warm-up waited for it on the frame
  thread (the Level Designer's editor, a third of a second or more). It now
  waits on the preloading thread.
- **The launch's pages**: the pages the splash and first loading screen draw
  are kept (`LaunchPages`, in the app's cache) and start decoding as the next
  launch starts.
- **The software CoreGraphics** (`BitmapContext`), which draws every chunky
  panel, ran a closure, a blend switch, two colours and a division a channel
  for every pixel, and a gradient made a colour object a pixel: the win card's
  panels took most of its first frame. One colour laid down source-over, rows
  of a vertical gradient, the blur's columns and the divisions now take
  shortcuts with the same arithmetic, so the same bytes (a panel 1.8 times
  faster on a Mac).
- **Flattening** (`DrawList`) appends into one list for the whole walk, and
  sorts places rather than commands (a deep tree 2.3 times faster).

What's still over 100 ms: the warm-up's CPU (the rig priming's 8,000 sprites,
which Android doesn't need: a game change), the programs the game makes on the
main thread as the world list shows (cold cache only) and its own main-thread
work there.

### Programs kept between launches

Each program the port links is kept in the app's cache as the driver's binary
(`glGetProgramBinary`) and loaded at the next launch in place of compiling and
linking it (`glProgramBinary`, `ProgramCache`), on the frame thread and the
builder's context alike. Files are named by a hash of the translated sources,
in a folder named by the driver's vendor, renderer and version (a driver update
starts afresh); a binary the driver turns down or a file that's damaged or cut
short is deleted and the program linked from source and kept again; the folder
holds 32 MB at the most, the least recently used going first.

The app's build isn't part of the key, and that's the point: Android already
keeps linked programs between launches (its EGL blob cache, in the app's
`code_cache`), so a plain relaunch gains nothing, but every update empties
`code_cache`, and the first launch after it linked everything again. Programs
an update didn't change now load as before. On a Galaxy M31 (optimised builds,
render scale 0.5, launching to the title, into the world list and into three
worlds' first levels, medians of three runs):

| | first launch (empty caches) | relaunch | first launch after an update, before | after |
|---|---|---|---|---|
| programs | 38 linked, 2.2 s on the builder thread | 38 loaded in 52–70 ms | linked again | 38 loaded in 63–108 ms |
| linking on the frame thread, in long frames | 563 ms | 4 ms | 539–572 ms | 5–18 ms |
| longest frame in the first 30 s | 703 ms | 377 ms | 666 ms | 387 ms |

What every scene takes to show doesn't move (the title's first frame at 4.2 s,
a level's 0.7 s after the tap): programs were already linked on their own
thread while the loading screen played, and what holds the long frames up is
bakes and page waits.

Thread Sanitizer runs the host tests clean (`swift test --sanitize=thread
--scratch-path .build/tsan`); before these fixes it reported eight races.
The shell logs every frame that takes 50 ms or more (`long frame: … ms`),
so a stall shows up in logcat wherever it happens.

## Every world's backdrop

Every world's live backdrop draws behind its levels, lit by its own light,
with the live edge blur behind the round buttons: the game's own
`BackdropNode`, `EdgeShade`, `LiveBackdrop` and all eight live backdrops
(`LawnNode` for Garden, Farm, Bug Woods and Glass, `SeabedNode`,
`TeaTableNode`, `TemplePoolNode`, `TownRugNode`, `CloudSeaNode`,
`CircuitBoardNode`, and Sky's `NightSkyNode` from before), their kits and
plans (`ScatterPlan`, `Arrangement`, `StreetPlan`, `CircuitPlan`,
`CircuitFill`), the critter, swim and tail rigs, `BackdropTouch`, the
board's grounding (`BoardGroundingArt`, `CloudCushion`, `WaterlineArt`,
`TuftArt`, `PinArt`) and every light (`SceneLighting`, `WorldLight`,
`LawnLight`, `DuskLight`, `RoomLight`, `CircuitLight`, `WindowLight`,
`CloudShadows`, `Fireflies`, `Canopy`, `SharedLightNode`). That is 42 files,
about 14,800 lines, symlinked into `Compat/Sources/GameCompat/Backdrops`
and compiled unmodified. `BackdropStubs.swift` and `RigStubs.swift` are
gone, and so are the film's stand-ins for the backdrop and the lights.

Each world shows in its levels: `-StartLevel reef-1` and so on (the
launch arguments, below).

`WorldPreviewScene` stands in for `GameScene` until the scenes ring brings
it: the port's board over the backdrop, set up in `GameScene`'s order, the
round buttons the blur shades behind given as rects where `GameScene` puts
them. A tap on a Switchling plays its move; anywhere else the scenery
reacts. `--esa args -WorldHide,live+blur+lights+ambient+board` leaves parts
out, to see what each costs. `PlayBoardGrounding.swift` hangs the grounding
on the port's board as `BoardNode.init` does.

### The game builds main-actor by default here too

The Xcode project builds the game with `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`, and `WorldLight.apply` leans on it: it calls the main actor's
`BuildGate.unlessBuilding` from code that is main-actor only by that
default. So `GameCompat` builds with `.defaultIsolation(MainActor.self)`
(tools 6.2), and the shim's `SKNode` and `UIView` are `@preconcurrency
@MainActor`, as SpriteKit's and UIKit's are, so the game's overrides agree
with what they override.

### What the shim and the renderer gained

- **Core Image** (`CoreImageCompat.swift`, a `CoreImage` module in
  `Compat`): the lawn's clearing round the board and the board's shadow and
  glow are a mask blurred with `clampedToExtent().applyingGaussianBlur`.
  Three box blurs a direction, on the CPU, in linear light as Core Image
  blurs (colour decoded from sRGB unpremultiplied, alpha left linear, and
  encoded again on the way out), so the clearing reaches as far as on Apple.
- **`CGRect` as CoreGraphics answers** (`RectSemantics`): corelibs says
  touching rects intersect, gives a spanned rect's own width as the
  intersection's and tests `contains(_: CGRect)` as `union(r) == self`, which
  rounding breaks; the backdrops' arrangement meets those edges on its grid,
  so the scenery came out elsewhere. The shim's members shadow Foundation's,
  fitted to CoreGraphics and checked against it on the host.
- **`SKDefaultShading()`** is what the sprite would draw with no shader of its
  own: its texture mixed toward its colour by `colorBlendFactor` and
  multiplied by its alpha, as a Mac's SpriteKit measures (the lit signpost's
  ink arrow, a lit piece's fades).
- **CoreGraphics' image orientation.** `draw(_:in:)` puts an image's top on
  the rect's maxY, as CoreGraphics does, and a raw `CGContext(data:…)` is y
  up; a renderer's context stays y-down, as UIKit's is. The game flips for
  this itself (`BoardGroundingArt`, `CircuitBoardNode`), and a shim that
  drew images the UIKit way round turned those upside down. Tiled draws
  (`draw(_:in:byTiling:)`) lay the Mainframe's solder mask.
- **`UIImage(named:)`** answers for the packed art, measured in its points,
  its pixels cut from the page only when asked (`CircuitBoardNode` draws its
  kit's paintings into the floor it bakes). `SceneLighting` asks it some
  five hundred times just to learn whether an asset has normals.
- **Actions**: `reversed()`, `follow(_:asOffset:orientToPath:duration:)`
  (the circuit's pulses), `rotate(toAngle:duration:shortestUnitArc:)`.
- **`SKSpriteNode.init(texture:color:size:)` is designated**, as SpriteKit's
  is. As a convenience initialiser the game's sprite subclasses compiled
  their `super.init(texture:color:size:)` and then failed to link.
- **The first scene is presented once GL is set up** (`rendererDidStart`),
  so a backdrop that bakes its floor and edge shades in `didMove` gets
  pixels rather than nil.
- **Uncropped bakes measure the subtree in the node's parent space**, as
  SpriteKit's do: the edge shade bakes a canvas scaled down by
  `edgeShadeMapScale`, which otherwise came back as a small patch.
- **SpriteKit's blend modes**: Toy Box's room light is a `.multiplyX2`
  pass over the rug.
- **A shader's uniform textures get their own pixels.** A packed image a
  shader samples (Kitchen's gingham, the grounds, the clearing's stones) is
  cut out of its atlas page once into a texture of its own that wraps
  (its ASTC blocks copied as they are); the page itself would show the
  whole atlas.
- **A shaded sprite sees its own image.** SpriteKit hands a custom shader
  `v_tex_coord` in its texture's own 0…1, and on iOS each image is a texture
  of its own, so `CrumbleNode` strikes its cracks from the brick's middle
  and reads their colour from its front face at a fixed `y`, and every lit
  brick, kerb and piece reads its normals at `v_tex_coord`. Given the
  page's coordinates, a cracked tile drew as a plain brick (cracks struck
  off the brick) or with streaks of the page's other art, and the lit
  pieces took their normals from the wrong place. So the batcher gives a
  shaded sprite UVs in its image's own space (9-slices and
  `SKTexture(rect:in:)` slices within it, `SpriteBatcher.ownImage`), and the
  renderer binds that image cut out of its page, clamped as SpriteKit's are
  (`ResourceCache.imageName(for:)`). Shaded sprites batch by image rather
  than page; Kitchen's first level draws 108 calls a frame against 106
  (`ShadedSpriteTests`).
- **Textures are premultiplied, as SpriteKit's are.** The pages and the
  rigs' own PNGs decode straight, and the renderer blends and the game's
  shaders compute as SpriteKit's premultiplied textures ask. Uploaded
  straight, every soft edge drew at its colour's full strength over what
  lay behind it, a light halo round every Switchling, home and piece. The
  cache premultiplies a page as it decodes it, and the renderer does the
  same for an encoded PNG (`Premultiply`).
- **A baked texture lives as long as the game holds it.** `texture(from:)`
  used to keep its textures by the node baked, deleting the previous one
  when that node baked again; but the nodes are throwaway canvases, and the
  next one often lands at a freed one's address. Starry Sky's floor (its
  mottled blue, `u_floor`) was deleted by the edge shade baked after it, so
  the sky sampled the shade's near-transparent black and the night came out
  dark and hardly blue. Each baked texture is now deleted once its
  `SKTexture` is gone (`BakedTextures`, swept at the next bake).

### Frame times, and what they can't say

On a pool emulator (`emulators.sh`, host GPU: `Android Emulator OpenGL ES
Translator (Apple M4 Max)`, GLES 3.0 over Metal), 1080×2400, each world's
first level, 300 frames after a 60-frame warm-up. The host was busy with
other sessions' builds and emulators, so a run was repeated when the
board-only baseline drifted. The scene graph's own CPU time ("scene") is
the number that carries to a phone; the rest is the translator.

| world | frame p50 | draw calls | target binds | scene |
|---|---|---|---|---|
| board alone (Garden, no backdrop, lights, blur or motes) | 33 ms | 85 | 1 | 0.3 ms |
| Sunny Garden | 41 ms | 106 | 3 | 0.4 ms |
| Happy Farm | 39 ms | 104 | 3 | 0.4 ms |
| Bug Woods | 38 ms | 109 | 7 | 0.7 ms |
| Glass Garden | 60 ms | 142 | 3 | 0.4 ms |
| Coral Reef | 25 ms | 71 | 9 | 0.4 ms |
| Cozy Kitchen | 23 ms | 65 | 3 | 0.2 ms |
| Flooded Ruins | 34 ms | 116 | 5 | 0.4 ms |
| Toy Box | 23 ms | 69 | 3 | 0.3 ms |
| Cloud Castle | 253 ms | 85 | 5 | 1.7 ms |
| Starry Sky | 289 ms (28 ms with its lights stopped) | 87 | 5 | 1.5 ms |
| The Mainframe | 43 ms | 92 | 3 | 0.4 ms |

Every backdrop costs a few milliseconds over the board alone, except two.
Starry Sky and Cloud Castle drop to under 30 ms with the light nodes not
started (`-WorldHide lights`): their lit shaders loop over a handful of
lights held in `mat4`s, indexed per pixel, which the emulator's GL-to-Metal
translator runs badly. Only a real mid-range device (Mali-G57 / Adreno 610)
can say whether that is the translator or the shader. (Whether
`BandedLayerNode` pays, which #396 found a loss on the emulator, the M31
settled: it wins by far, under "Banded layers on the M31".) Reef also shows a faint seam where two of its
caustic bands meet, which wants the same device to tell timing from a bug.

### On a real phone: a Galaxy M31

The first physical device the port ran on (Exynos 9611, Mali-G72 MP3,
1080 × 2340 at 60 Hz, Android 12) was fill-rate bound, as the emulator
could never show. Optimised build, each world's first level, the median of
300 frames after the scene settled:

| | before | after | render scale |
|---|---|---|---|
| Sunny Garden, Happy Farm, Glass Garden, Cozy Kitchen | 51–55 ms (18–19 fps) | 16.7 ms (60 fps) | 0.5–0.58 |
| the world list (Sunny Garden) | 52 ms | 16.7 ms (60 fps) | 0.5–0.58 |
| the title | 51 ms | 20 ms (49 fps) | 0.5 |
| Flooded Ruins, The Mainframe, Cloud Castle, Coral Reef, Bug Woods | 70–75 ms (13–14 fps) | 20–22 ms (46–50 fps) | 0.5 |
| the world list (Starry Sky) | 98 ms (10 fps) | 26 ms (38 fps) | 0.5 |
| Starry Sky | 116 ms (8.6 fps) | 30 ms (33 fps) | 0.5 |
| Toy Box | 80 ms (12.5 fps) | 34 ms (29 fps) | 0.5 |

What changed, by what it bought:

- **The render scale** (`RenderScaleGovernor`). Frame times fell almost
  exactly with the pixels drawn (Sunny Garden 52 ms at full size, 25.5 at
  0.67, 16.7 at 0.5), so the scene draws at a share of the screen's size,
  with shaders still counting the screen's own pixels (`FragCoordSpace`).
  The display stretches it, not the GPU: the shell sizes the window's
  buffers to the scale (`ANativeWindow_setBuffersGeometry`, `SurfaceScaler`
  in `Display.swift`) and the renderer draws straight into them, so no
  full-screen pass writes every pixel of the screen again. Changing the
  size takes a few hundredths of a millisecond and shows nothing on screen.
  The shell sizes them again whenever SDL makes the surface again (back from
  the background) or the device turns. Until a new size takes, and wherever
  Android refuses one, the renderer draws into a target of that size and
  stretches it on itself (`glBlitFramebuffer`), as it always did. The
  governor starts at 1 and steps down while frames run late, unless the
  CPU took most of the frame, and tries a step up after a run of frames
  on time, backing off if that fails. It judges by the wall clock: the
  M31's `GL_EXT_disjoint_timer_query` answers a frame that draws into more
  than one target with nonsense, elapsed or by timestamps. `adb shell setprop
  debug.switchlings.renderscale 0.67` holds it, for measuring (and the
  frame rate with it). Auto now chooses only once for a device and never
  lowers the frame rate: it draws at 60 and measures at full size for one
  to three minutes of play, then keeps the largest of full size, 0.875 and
  0.75 whose share of the pixels would have brought the heavier moments
  within budget, drawn from the next scene on and kept for good. Its frame
  reports count the frames over budget (`[frames] game late`). A frame rate or Graphics setting the player
  picks applies at once, and a launch starts at the scale the device chose
  (`SceneRenderer.configure`, from `AndroidGameController.displayChoices`);
  the governor
  itself is the game's (`Source/Utils/RenderScaleGovernor.swift`,
  symlinked into GLESRenderer), as Apple's game view adapts the same way.
- **Frame pacing** (`VsyncPacer`, `Display.swift`). Frames start on the
  display's vsync, which AChoreographer reports on the frame thread's
  looper, never twice on one refresh. Each frame's time is the latest
  vsync, so every step the scene moves is a whole number of refreshes, even
  when a frame runs late. Before, the loop ran as fast as the swap let it,
  timed by the wall clock, and each step was however long the last pass
  happened to take. The game's frame rate skips refreshes as it did (half
  a refresh early at most, `SKView.refreshInterval`, so 40 lands on every
  third of a 120 Hz display's), and goes to Android as the window's rate (`ANativeWindow_setFrameRate`,
  so a screen that can switch to 120 Hz does). The governor still judges
  by the wall clock (`Frame.interval`). `-FixedFrameStep` isn't paced: its
  frames step their own clock, as before.
- **The CPU side**, a quarter to a third of the renderer's time (simpleperf):
  one vertex and one index buffer a frame, sprites, text and shape masks
  alike, written batch after batch through one map of a freshly orphaned
  store, not `glBufferData` for every draw; uniform locations
  looked up once per program; and optimised builds without Swift's run-time
  exclusivity checks, which on Android read emulated TLS and came to about a
  tenth of the game thread. None of it moved a frame on the M31, which was
  waiting on the GPU, but it is what the render scale's 60 fps stands on.

What's left, at 0.5 (the governor's floor):

- **Starry Sky, Toy Box and the Starry Sky world page** still miss 60 fps on
  the GPU: their backdrops' full-screen lit shaders (the night's nebula and
  planets, the rug's room light) cost more than a Mali-G72 has at any
  scale worth showing. Lighter shaders there are game-side work.
- **The CPU** takes 12–18 ms a frame (ticking actions, the rigs, flattening
  and batching), close to the whole budget. Bug Woods' warped trees were
  the most of it; round one's fixes and the warps' own (**Warps**) brought
  them down to about what the same sprites cost unwarped.

Rigs dropped triangles there too, and audio was silent everywhere; both are
under Rigs and Audio.

## The players' Level Designer

The title's Level Designer runs as on iOS, from the game's own
`Source/Designer` (symlinked into `GameCompat` with the rest): the list
(My levels and Community, the cards and their more-menus, the code prompt,
the Discord invite), the editor (world and tool selects, the tool panel
upright and in landscape, the rail and its modes, painting, moving and
erasing, playing in place with undo, redo and reset), Share (a picture of
the level and its link, into Android's share sheet) and a friend's level
by its code or link. `DesignerStore` keeps its file where corelibs puts
Application Support, `files/.local/share/Designer/Levels.json` in the app's
internal storage (`XDG_DATA_HOME`, set by `GameEnvironment`), so drafts and
friends' levels survive relaunches and updates. The full-game padlock and
`DesignerUnlocks` are the game's own over `StoreManager`'s Android body
(`-UnlockAll YES` in a debug build, `-SimulatePurchases YES` to walk the
offer).

### Shared levels, over the network

`LevelShare` posts a level (`POST /levels`) and fetches a friend's
(`GET /levels/<code>`) through `URLSession`, which on Android is corelibs'
`FoundationNetworking` over libcurl, re-exported by the `UIKit` module
target. Two things make it work:

- **`DesignerServer.endpoint`** answers as on iOS
  (`https://switchlings.fleon.com`, or `-DesignerServer <url>` in a debug
  build). The beta's feed and solve log stay off; only shared levels, which
  outlive the beta, reach the server. Play's Data Safety form therefore
  needs the shared levels (a board and a random maker key, no name or
  photo: Android has no Game Center) — `Tools/Play/PLAY-CONSOLE-SETUP.md`.
- **`android.permission.INTERNET`** in the manifest. TLS needs nothing of
  ours: the 6.4.2 SDK's `FoundationNetworking` reads Android's own CA store
  (`/apex/com.android.conscrypt/cacerts`, else
  `/system/etc/security/cacerts`). libcurl is not Android's Java network
  stack, so the network security config's cleartext rule doesn't reach it,
  and a debug build can share against a local server over plain HTTP:

```bash
SWL_DESIGNER_STORE=/tmp/designer SWL_SHARE_BASE=http://10.0.2.2:46198 \
  DESIGNER_SECRET=$(openssl rand -hex 24) PORT=46198 \
  node Tools/guard.js 12 -- node Tools/Levels/Designer/http.js
adb shell am start -n com.fleon.switchlings/.MainActivity \
  --esa args "-UnlockAll,YES,-DesignerServer,http://10.0.2.2:46198,-StartScreen,designer"
```

### The code prompt's keyboard

`CodePromptPopup` lays an invisible `UITextField` over its boxes and
listens for UIKit's keyboard notifications to rise clear of the keyboard.
On Android:

- **The keyboard** is SDL's text input, started with the field's own
  settings as an Android `InputType` (`AndroidInputType` in the shell): the
  code's capitals and no corrections or suggestions, as the field asks of
  UIKit. Gboard still offered words for letters with `NO_SUGGESTIONS` alone,
  and a word picked from its strip would arrive as one many-letter insert,
  so such a field is also a visible password (no suggestions, a number row
  for the code's digits). SDL's text input area is the field's frame.
- **Its frame** comes from Android's IME insets (`MainActivity`'s
  `GameSurface.onApplyWindowInsets` → `nativeKeyboard`) and is posted as
  UIKit posts it (`SoftKeyboard` in the shim: `keyboardWillShow`,
  `keyboardWillChangeFrame`, `keyboardWillHide`, each with
  `keyboardFrameEndUserInfoKey` as an `NSValue`), so the game's own code
  raises the card. The activity is `adjustNothing`: left to pan, Android
  moved the whole game down to keep SDL's hidden edit box in view.
- **Touches on the field** are the field's, as on iOS, where it is a view
  over the game's: a tap brings the keyboard back if Android's back put it
  away, and a long press offers Android's Paste over the boxes
  (`MainActivity.offerPaste`), which hands the clipboard's text to the
  field as a paste — so a link or a whole message finds its code
  (`LevelShare.code(in:)`). A keyboard's own clipboard suggestion pastes
  the same way, and a hardware keyboard's Ctrl+V (or Meta+V) too.

### Links

`switchlings://level/<code>` and `switchlings://world/<theme>` open the
game (`VIEW` intent filters), and so does a level's page,
`https://switchlings.fleon.com/l/<code>`, which `MainActivity` turns into
the same `switchlings://level/` link before the game sees it, since the
game's `LevelShare.code(opening:)` reads only its own scheme.

- **Cold**, the link rides in as `-OpenLink` (`getArguments`), which
  `AndroidGameController.launch(link:)` hands to `WorldLink.pending` or
  `LevelShare.pendingCode`, as iOS's scene delegate does with its URL
  contexts.
- **Running** (`singleInstance`, so `onNewIntent`), the link goes through
  `nativeOpenLink` to the frame loop, which hands it to
  `AndroidGameController.open` — the scene on screen opens it
  (`SharedLevelOpening`), or it waits for the next screen
  (`SharedLevelOpening.takePendingCode`), or the world list opens on the
  world (`WorldLink`).

`MainActivity`'s three natives (`nativeOpenLink`, `nativePaste`,
`nativeKeyboard`) are registered by the shell on the activity's class
(`ska_register_natives`), since SDL dlopens `libAndroidShell.so`
itself and the class loader never looks there; they leave what they're
handed in a small locked inbox the frame loop empties (`SystemInbox`). A
link that arrives before the shell has registered them waits in the
activity.

```bash
adb shell am start -a android.intent.action.VIEW -d switchlings://level/W3VYEV
adb shell am start -a android.intent.action.VIEW -d switchlings://world/reef
adb shell am start -a android.intent.action.VIEW -d https://switchlings.fleon.com/l/W3VYEV -p com.fleon.switchlings
```

**App Links** need the site to vouch for the app: the https filter is
`autoVerify`, and `Tools/Levels/Designer/http.js` now serves
`/.well-known/assetlinks.json` from `config.json`'s `android` entry (the
package and its signing certificates' SHA-256 fingerprints): Play App
Signing's key (24:3C:…:8F:3F, which signs every copy Play installs; Play
Console → Test and release → App integrity → App signing) and the upload
key's (19:4B:…:E3:69, for release builds installed by hand). fleon-home
serves main, so it goes live when fleon-home restarts after the change
merges. Without them the route answers 404 and Android shows the page in
the browser, whose button opens the `switchlings://` link.

## Launch arguments, and the parity sweep

Every debug launch argument in AGENTS.md's Debugging section works on
Android, read by the game's own `LaunchArguments` unchanged.

### Handing them over

```bash
node Android/Scripts/launch.js --package com.fleon.switchlings -- \
    -StartLevel reef-12 -Stills "move 3@0.05;celebrate@0.7" -settings.musicEnabled "<false/>"
```

`launch.js` sends them as `--es args64 <base64 of a JSON array>`, which
no shell on the way splits, so values with spaces, commas, quotes and plist
syntax arrive whole. For a quick one by hand, `--esa args` works too:

```bash
adb shell am start -S -n com.fleon.switchlings/.MainActivity --esa args -StartLevel,reef-12,-HideTips,YES
```

`am` splits it at commas (`\,` for a comma inside a value), and `adb
shell` hands the line to the device's shell, which splits it again at
spaces and eats quotes, so anything beyond words and digits goes as
`args64`. `MainActivity.getArguments` reads both, `args64`'s after
`args'`, and only in a debuggable build: a release APK ignores them, as a
release build on Apple ignores its arguments. SDL hands them to `SDL_main`
(`ShellArguments`), which puts them in `CommandLine.arguments` (so
`ProcessInfo.arguments`) and in `UserDefaults`' argument domain
(`LaunchArgumentDomain`, in `PlatformShim`: `-Key value` pairs, a value
read as a property list where it starts like one, nothing that starts with
a dash ever a value — checked by `LaunchArgumentDomainTests` against a Mac
process's own argument domain). `-AppleLanguages "(ja)"` stands in for the
device's languages.

The Swift side reads them under `#if DEBUG`, which every build defines but
`build-shell.sh --store` (what goes to Play): `--debug` builds, which every
check, emulator run and parity sweep uses, and the optimised builds made only
to measure frame times, which can then still take `-StartLevel` and
`-FrameLog`.

### What each driver does here

The Apple controller's debug drivers are in
`Compat/Sources/GameCompat/Android/AndroidGameController+Scripts.swift`,
each the `GameViewController` method of the same name:

| argument | on Android |
|---|---|
| `-Markers`, `-MarkerClock` | the game's `print` reaches logcat under `Switchlings` (`ska_redirect_stdio` pipes stdout and stderr into it, line buffered) |
| `-Stills` | holds the view still after each marker, as on Apple, its 2.5 s counted from the frame it paused in reaching the screen (an unoptimised build can take longer than that to draw a scene's first frame); the renderer then logs `view held: its last frame is on screen` once the frame it paused in has been swapped (an unoptimised build can take a second or two to draw it), and that's when `adb exec-out screencap -p` takes the still |
| `-FixedFrameStep 1/30` | the shell's clock (`MediaTime`, the one behind `CACurrentMediaTime()`, every shader's `u_time` and the frames' times) stands still between frames and moves on by exactly that much for each frame drawn, and the view's frame-rate cap stands aside; while the game holds the clock (`MediaClock.hold`, around its builds off the main thread) the shell draws nothing. MainActivity also sets `SWIFT_DETERMINISTIC_HASHING` before Swift loads, so every `Dictionary` and `Set` keeps one order from launch to launch. Apple ignores it |
| `-SnapshotEvery`, `-SnapshotLevels`, `-FrameLog` | write into the app's cache (`FileManager`'s caches directory is `XDG_CACHE_HOME`, the app's `cache/`): `adb exec-out run-as <package> cat cache/levels/garden-1.png > garden-1.png`. The frame is read back from the renderer before it's swapped (`SceneRenderer.captureNextFrame`) |
| `-KeyScript`, `-TouchScript` (`-ScriptTimes`, `-ScriptAfter`) | as on Apple: keys to `KeyboardControllable`, taps as touches at shares of the screen, named steps to `ScriptedStepping` |
| `-GamepadScript` | a pretend pad of `GamepadInput`'s own, connected as the script starts |
| `-RemoteScript` | Apple TV's presses as a TV's d-pad would press them: arrows move focus, `select` presses, `menu` is Back |
| `-Orientation landscape\|flipped\|portrait` | held by `MainActivity` before SDL starts (`holdDebugOrientation`), so the game's first layout is already turned, as Apple's controller holds it from launch, and by SDL's orientations hint as the window is made (`landscape` is the camera on the left, as on Apple); `turn` is left out |
| `-SyncedClears`, `-SyncedMoves`, `-SyncedLanguage` | as on Apple |
| `-OpenLink`, `-OpenLinkAfter`, `-OpenCode` | as `SceneDelegate` reads them: a link the game opened with wins, else `-OpenLink` opens at launch (`WorldLink.pending`, `LevelShare.pendingCode`), else `-OpenCode`'s code; with `-OpenLinkAfter`, `-OpenLink` opens that many seconds after the game shows, as a tapped link does. `LaunchLinks` (PlatformShim, host-tested) decides which; MainActivity hands a real link as `-LaunchLink`, apart from the debug `-OpenLink` |

One is the port's own: `-SafeAreaInsets top,left,bottom,right` (points)
lays the game out within those insets instead of the device's
(`SafeAreaOverride`, read by `AndroidGameController.layout` in debug builds
only), which the parity sweep uses to give the emulator the iPhone 17 Pro's
safe area as well as its screen.

Left out, as Apple's alone: `-SimulateViewSize`, `-MacWindowSize`,
`-HoverAt`, `-VirtualGamepad`, `-HeaderFilm`, `-EventVideo`.

For a quick build of just the emulators' ABI,
`./gradlew assembleDebug -Pswitchlings.abis=arm64-v8a` after
`Scripts/build-shell.sh --debug arm64-v8a`.

### The parity sweep

`Tools/Capture/parity.js` captures the states in `Tools/Capture/parity.json`
on up to four pool emulators at once, each at a still, and compares it with
the iPhone 17 Pro's shot of the same state with the same arguments, kept as a reference
set; it ranks the pairs by how much they differ:

```bash
node Tools/Capture/parity.js build
```

```bash
node Tools/guard.js 12 -- node Tools/Capture/parity.js
```

`build` (outside the guard, as Xcode builds run) makes an arm64 debug APK
(`build-shell.sh --debug`: the sweep compares pictures, not frame times) as
`com.fleon.switchlings.parity`. The sweep boots no simulator: the iPhone's
side is `~/.switchlings/parity-reference/iphone/<state>.png` (outside every
checkout; `--reference <dir>` for another), and a state with no reference is
listed as such. It takes as many pool slots as are free, up to `--slots N`
(unless told, 4, and one for every four states, so a targeted sweep of two
to four takes one), each through `Android/Scripts/emulators.sh acquire
parity-<pid>-<n>` (a sweep's own owners, so two sweeps never share a slot,
and a fresh lease, so each starts clean: screen size and density reset,
`debug.switchlings.*` cleared), and installs the APK on each. With fewer
free it uses what's free; with none, it looks again every 20 seconds. The
states wait in one queue in parity.json's order and each slot takes the next
as it finishes the last, so a slow state holds up only its own slot; every
state is a cold launch with the same arguments, so which slot takes it
changes nothing in its shot. Each slot goes back as soon as the queue is
empty (its screen put back first), and every slot it still holds goes back
on a failure, Ctrl-C or a kill, even when the guard SIGKILLs the whole tree
(a watchdog outside it releases them once the sweep's process is gone).
The slots boot one at a time: the guard counts an emulator while it boots
(once it's up it belongs to launchd), and one now takes about 6½ GB as it
boots, so four at once passed the guard's 12.

Every launch starts afresh: it deletes the app's saved data first (nothing to
resume; not `pm clear`, after which Android shows its "Viewing full screen"
notice over the next launch), tells the emulator that notice has been seen,
resets any screen size or density another session left on the slot (an
override outlives a reboot), gives it the iPhone 17 Pro's screen for the
sweep (1206 × 2622 px at 480 dpi, 402 × 874 points: the scenery's layout is
seeded by the screen's size; `--pixel-screen` keeps the Pixel 6's own) and
puts its own back before the slot goes, tells the game the iPhone's safe
area there too (`androidSafeArea`, as `-SafeAreaInsets`), launches both with parity.json's
`base`, whose `-RandomSeed 7` makes every random draw the game makes the same
on both (`Random`: scenery life, the title tour, petals, sparks, blinks…),
keeps sound and music off, takes a still again if it came while a scene
transition was still playing (a busy host can stall one frame for seconds;
four emulators at once make that likelier, and the retry covers it),
and writes `Tools/Capture/Out/parity/`: `pairs/<state>.png` (Android, iPhone,
where they differ), `report.json` and `report.html`, worst first. The score
is the mean difference of every channel on a 90-point-wide grid, 0 the same
and 100 black against white, both shots stretched to one size (the two
screens' aspects differ by 2%). `--only title,level-` captures the states
whose names start so.

Scores are reproducible: two sweeps of the same build give the same score
for every state, on one slot or four, however busy the machine. parity.json's
`base` passes `-FixedFrameStep 1/30`, with which every frame moves the
scene, every shader's `u_time` and `MediaClock` on by exactly a thirtieth of
a second, however long it really took (`MediaTime.fixedStep`: the shell steps
the one clock the port has), and no frame is drawn, so no clock moves, while
the game waits on a build off the main thread (`MediaClock.hold`: the loading
screen's next scene, the world list's pages, previews and backdrops, the
title's next board and sheets, the Mainframe's floor, and anything else that holds `BuildGate` off it, which holds back the lights' updates), and Swift hashes the same way every launch (`SWIFT_DETERMINISTIC_HASHING`, set by MainActivity: the world list baked its neighbours in a dictionary's order, so its still came out one of three ways). Without it the shaders'
time followed the wall clock while a still is timed on the scene's, so a
slower launch showed cloud shadows, water and light further along (between a
one-slot and a four-slot sweep the mean score moved 0.33, the lawns up to
1.8). The shots then match byte for byte (`shots/`), so a change in a score
is a change in the build.

The price is time: a debug build draws every step, however slowly. Before
the loading screen's warm-up left the frame thread (#462), a level drew about
11 frames a second on an idle emulator and far fewer on four busy ones, and
a full sweep took 76 minutes on one slot and 65 on four, which is why the
step is a thirtieth rather than a sixtieth and a still may take up to 15
minutes (`stillAfter` in `report.json`). Since, a lawn level reaches its
still in about 8 seconds: three of them took 65 s on one slot and 34 s on
two (2026-11-15). The iPhone references are taken without it, as Apple ignores it
(SpriteKit's view can't be stepped, and hands shaders the wall clock).

When to run which: every Android PR runs `swift test` and the
cross-compiles, and one that changes how anything draws adds a targeted
sweep of the states it touches (`--only level-reef,help`, a slot and a few
minutes); the full sweep runs nightly, or before an Android release build.

```bash
node Tools/guard.js 12 -- node Tools/Capture/parity.js --only level-reef,help
```

Re-capturing the references is explicit and opt-in: `--boot-simulator`
boots one iPhone 17 Pro simulator of its own while the sweep's pool emulator
runs, shoots the selected states into the reference directory, and deletes
it before the Android shots, on one slot (the machine's rule: Android only
on the four pool slots, and at most one iPhone simulator a session, booted only beside a
running pool emulator, four at most on the machine, which the sweep checks
before it boots one). Each launch is given empty seen-collectible and
seen-guide lists, since the simulator keeps its preferences from one state
to the next where Android starts clean:

```bash
node Tools/Capture/parity.js build --ios
```

```bash
node Tools/guard.js 12 -- node Tools/Capture/parity.js --boot-simulator --only collection-,help
```

`report` compares the shots on disk again, with no emulator.
