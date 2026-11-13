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
| `SKEmitterNode` / `SKKeyframeSequence` | 5 / 7 — done, see **Particles** |

And the game's own `SKAction` helpers (`animate`, `animateSteadily`,
`pingPong`, `zoom` in `EasingFunctions.swift`) are built from just four
primitives: `customAction`, `run`, `sequence` and `repeatForever`.

## Layout

```
Android/
  Package.swift          SpriteKitShim + tests. Builds on macOS and Android.
  Sources/SpriteKitShim/ The layer.
  Sources/PlatformShim/  The Android stand-ins for AVFoundation, iCloud's
                         key-value store, StoreKit and GameKit — the parts
                         with no device in them. 30 tests.
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
  Shell/                 Android-only. The app shell: SDL3, the GLES 3
                         context, the frame loop, and the audio backend
                         (SDL3 output, MediaCodec for the soundtrack).
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
`GameCompat` compiles **7,066 lines of real, unmodified game
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
`RigPose`, `RigNode`, `RigMeshNode` and `LedGlowNode` compile unchanged and
**Switchlings animate on a device**. See **Rigs** below.

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

## Rigs

The whole rig runtime is here: `RigData` reads a packed Spine 4.2 skeleton,
`RigPose` poses it the way Spine's runtime does (crossfades, physics step for
step), `RigNode` draws it and `RigMeshNode` cuts each mesh attachment into
runs of four triangles, one sprite each, whose shader tests every pixel
against them. All five files compile for both ABIs unmodified.

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

**The attributes.** A rig mesh sprite carries twelve `vec4`s — four
triangles, three each — and the quad's own four bring that to sixteen, which
is exactly what GLES 3.0 guarantees. They are *per node*, which is why
`SpriteBatcher` never merges a sprite that carries them; `SceneRenderer`
pushes each as a generic vertex attribute (`glVertexAttrib4f`), the constant
GL hands every vertex when no array is enabled for that location. The
renderer logs `GL_MAX_VERTEX_ATTRIBS` at start-up, because a driver at the
minimum leaves no headroom at all.

**What is not wired yet.** `SKTexture.usesMipmaps` is carried but the
uploader ignores it, so a minified rig aliases. Lighting is stood in for
(`RigStubs.swift`), so every rig takes `RigMeshNode`'s unlit path — which is
its own real code, not a lit shader with invented light in it.

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
`adb shell setprop debug.switchlings.scene particles` shows the
reef's particles alone, set up exactly as `SeabedNode` sets them up
(`Compat/Sources/GameCompat/Play/EmitterPreviewScene.swift`); tap for a
burst. The seabed itself is the backdrop stage's.

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
  NDK's C API (`Shell/Sources/CSwitchlingsAudio`), mixed on a thread of its
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

### Saved data — local, and honest about it

`ICloudSyncManager` keeps its shape exactly — `set` / `insert` /
`addedTimes` / `resetSet`, latest-wins and union, the `didUpdateLocalData`
notification — because `Progress`, `AudioManager`, `Localization` and
`GameCenterManager` all lean on those semantics. The merge itself is the
Apple file's logic, lifted into `SyncEngine` so it could be tested, and it
runs here against `LocalOnlyCloud`: the same path the Apple build takes
under `-ICloudOff`.

**Nothing syncs between devices yet.** The Android answer is **Play Games
Saved Games** (Snapshots), and the shape above fits it better than it looks:
a snapshot is one blob with a conflict callback, but every record here is
either a value with the time it changed or a set of items each with the time
it was added — so merging two snapshots is commutative and idempotent and
**there is no conflict to resolve**. One snapshot holding `[key: record]` as
JSON is a `CloudKeyValueStore`, and that protocol's doc comment spells out
which call maps to which part of the Snapshots API.

### The beta's reporting — off, by decision

See below. `PlaytestLog.run` returns nil and `DesignerFeed.whenAnswered`
answers at once; neither opens a `URLSession`.

### Billing and achievements — seams, and said so

Both need a Play Console that does not exist yet: the full-game product
`com.fleon.switchlings.fullgame` has not been created, and Play Games
Services needs a game with its achievements and an OAuth client tied to the
signing certificate. `Tools/Play/PLAY-CONSOLE-SETUP.md` is what has to
happen first.

What is real either way is the state above the service. The entitlement is
kept on the device and read before anything asks anybody, so every lock,
padlock, offer and the launch-event rule behave correctly — and the event's
end is the same instant on both platforms, so a player who bought in time
keeps the secret worlds wherever they play. Achievement progress is worked
out from the game's own saved data and kept locally, and only what has moved
is ever sent.

What is not real is plain: `NoBilling` fails a purchase rather than quietly
granting it, and `SimulatedBilling` — the Android side of
`-SimulatePurchases` — grants locally and keeps it across launches, which is
enough to walk the whole unlock flow on a device. There is no sign-in, no
dashboard, and `localPlayer()` returns nil for good: no Game Center means a
level shared from Android carries no maker credit, which is a settled
decision rather than a gap.

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

## A level, playable

Sunny Garden's first level loads from the game's own `LevelCatalog`, draws
its board from the game's own component nodes, takes taps and plays each
move through `Timeline`. `Android/Compat/Sources/GameCompat/Play/` holds the
assembly; everything under it is real game source, symlinked and unmodified.

The levels reach the device through the door the catalog already has.
`LevelCatalog` reads `Bundle.main`, and a file inside an APK is not a path on
disk, so `AndroidLevels.install(reading:)` hands the same files to
`LevelCatalog.contents(from:revision:)` and `use(_:)` — the seam the Level
Designer's feed uses. That door replays **every** level's stored solution
through `GameEngine` before accepting the set, so starting the app is 330
levels and ~4,500 moves of proof that the rules port. Gradle stages
`Assets/Levels/*.json` into `assets/levels/`, beside the packed art rather
than among it.

Reused from `Source/`, unmodified: `BoardMetrics`, `BoardOutline`,
`BoardFrameNode`, `TileNode`, `GoalNode`, `ArrowTileNode`, `ArrowBadgeNode`,
`LiftControlNode`, `SpriteHelpers`, `Theme`, `ColorHelpers`,
`CharacterEyesNode`, and the whole of `GameEngine`, `Timeline`, `GameState`,
`Level`, `LevelCatalog`, `RouteSolver` and `WorldTheme`. Written here: the
assembly (`PlayBoardNode`, `PlayScene`) and a stand-in for `ActorNode`, whose
`rig` is a stored, non-optional `RigNode` and so waits on the rig runtime.

Not drawn yet: every mechanic's own art — springs, whirlpools, gates,
buttons, blocks, arrow banks, currents, ice, screens, ledges, thresholds,
keys, locks, light pillars, turntables, platform switches and the
Mainframe's three. The rules are whole, so a level with those pieces plays
correctly over bare floor. There is no HUD, no backdrop and no landscape
transposition.

## Render-to-texture, and one backdrop

`SKEffectNode` and `SKCropNode` composite for real, and Starry Sky's
backdrop draws on a device — `Source/Common/Components/NightSkyNode.swift`
(972 lines) and `BandedLayerNode.swift`, symlinked into `Compat` and
compiled unmodified, with `Theme.swift`, `WorldTheme.swift` and
`ColorHelpers.swift` beside them.

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
- **An effect's shader sees the effect texture's pixels**, not the
  framebuffer's — which is why a crop node round an effect node moves the
  blur band on iOS, and now here. `EffectTexture.composite` maps the
  coordinate back, so the composite needs one pass rather than SpriteKit's
  two. It is exact for a translated and scaled effect node (every one in
  this game) and refuses a rotated one rather than drawing something
  plausible.
- **`shouldRasterize` keeps its pixels.** `BandedLayerNode` redraws one band
  a frame by toggling it, so the shim bumps a generation on every write and
  the draw list carries a digest of what the subtree draws — transforms and
  textures, deliberately *not* shader uniform values, or a band would redraw
  every frame as `u_time` moved and the cache would be a loss.

### What the emulator says, and what it does not

Measured on the shared `switchlings_shell` AVD, which reports
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
easily. On an A14 iPad, where the shader is the bottleneck, it wins; the
band count wants to follow the hardware rather than being 4 everywhere, and
nothing short of a real Mali-G57 / Adreno 610 can say where the crossover
sits.

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

Two gaps, both outside the warp code: `repeatForever` drops whatever part of
a frame runs past a round's end (SpriteKit carries it on), so a looping sway
loses up to a frame a round; and the shim's `easeIn` and `easeInEaseOut` are
quadratic, while SpriteKit's measured warp curves are `2t² − t³` and
smoothstep. The game sets no timing mode on a warp.

Android's libm overlay has no `Float` overloads of `sin`, `sqrt` and the
rest, which Darwin's has; `BackdropWarp` mixes them with `SIMD2<Float>`, and
the type checker gave up on the expression. `FloatMath.swift` supplies them.

The `warp` scene is `WarpProbeScene`: real lawn-kit pieces bent
by the game's own `BackdropWarp` (a crown stirring, plants at the lawn's sway
and at four times it, a butterfly's wings) and reacting through
`BackdropTouch`, on their own every 1.4 s and to a tap.

```bash
adb shell setprop debug.switchlings.scene warp
# or, for one launch, without touching a shared emulator's property:
adb shell am start -n com.fleon.switchlings/.MainActivity --esa args "-WarpProbe"
```

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
(`switchlings_set_main_executor` in `CAndroidShell`), because its functions
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

logcat says when each scene arrives and when its transition lands
(`scene LoadingScene at 13.462, transition playing`).
