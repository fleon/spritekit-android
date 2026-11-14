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
`GameCompat` compiles **219 of the game's 235 source files**, unmodified,
for Android on both ABIs (see **The game's own scenes** for the sixteen it
leaves out and why). The table below is the first slice that compiled:

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
  own switch silences them. Phones only, as `HapticsManager` decides.
- **Audio focus**, matched to the iOS build's ambient session: the player's
  own music wins. Coming to the front with another app's music playing, the
  game takes no focus and keeps its soundtrack quiet (its sounds still mix
  in); otherwise it takes focus for the soundtrack and steps aside when
  another app takes it, and everything waits through a call
  (`AudioManager.audioFocusDidChange`).
- **Background and foreground**: the shell suspends audio, saves and pauses
  the frame loop as Android takes the window, and resumes them after; the
  soundtrack stops with the game.
- **Battery saver** is Low Power Mode: `ProcessInfo.isLowPowerModeEnabled`
  reads it and `NSProcessInfoPowerStateDidChange` is posted as it changes,
  so the frame rate is held to 60 as on iOS.

### The beta's reporting — off, by decision

See below. `PlaytestLog.run` returns nil and `DesignerFeed.whenAnswered`
answers at once; neither opens a `URLSession`. The designer's server is
still reached for what stays after the beta, the players' shared levels
(see **The players' Level Designer**).

### What Data Safety has to say

Purchases (Play Billing: the purchase and its history, for app
functionality), the Play Games player ID and profile (sign-in,
achievements) and the saved game (Play Games Saved Games: levels cleared
and settings, app functionality). No maker name or photo.
`Tools/Play/PLAY-CONSOLE-SETUP.md` §4 has the answers.

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

One consequence for the Play listing, written up in
`Tools/Play/PLAY-CONSOLE-SETUP.md`: the solve log needs no Data Safety
declaration.

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
settings with their tabs. **219 of the game's 235 files** compile into
`GameCompat` unchanged, symlinked at the same paths they have under
`Source/` (`Title/TitleScene.swift`, `Game/GameScene.swift`, …).

Left out, each for a reason of its own:

| `Source/` file | why | what stands in |
|---|---|---|
| `AppDelegate`, `SceneDelegate`, `GameViewController` | the Apple app's own entry, window and controller | `Android/AndroidGameController.swift`, `GameViewControllerProtocols.swift` (below) |
| `Utils/GamepadInput.swift` | observes `GCController` through `#selector`, which needs the Objective-C runtime | `Android/GamepadInput.swift`: the same `Action`s, mapping, thresholds and repeat, fed by SDL's gamepads |
| `Utils/ShareSheet.swift` | `UIActivityViewController` | `Platform/ShareSheet.swift` (Android's chooser, from the share films) |
| `AudioManager`, `StoreManager`, `GameCenterManager`, `ICloudSyncManager`, `HapticsManager`, `PlaytestLog`, `DesignerFeed` | AVFoundation, StoreKit, GameKit, iCloud, haptics compiled for iOS only, the beta's reporting | `Platform/` (the platform ring) |
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
- **Launch arguments** from the intent's `args` extra in the argument
  domain, where `LaunchArguments` reads them (debug builds only, as on
  Apple). `-settings.musicEnabled,<false/>` works in any build.
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
| `Storefront.current` | `Compat/Sources/StoreKit` | nil: no App Store storefront, so a share's link falls back to the region's App Store page (a Play link is a follow-up; `SolutionShare` is the game's own) |
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

The two gaps outside the warp code that this found are closed: a repeat
carries what a frame runs past a round's end into the next, and every timing
mode runs on SpriteKit's measured curve (see **The game's own scenes**).

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
| `AVAssetWriter` + H.264 input + pixel buffer adaptor | `Sources/PlatformShim/Media`: each frame converted to BT.709 video-range YUV (`YUVConversion`) and encoded with MediaCodec into an MP4 (`Shell/Sources/CSwitchlingsMedia`) |
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
(`switchlings_drain_main_queue`). The shell logs "the main queue runs on
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

```bash
adb shell "setprop debug.switchlings.scene world:reef-1; am start -n com.fleon.switchlings.worlds/com.fleon.switchlings.MainActivity; sleep 3; setprop debug.switchlings.scene ''"
```

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
  Three box blurs a direction, on the CPU.
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
  cut out of its atlas page once into a texture of its own that wraps; the
  page itself would show the whole atlas.

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
can say whether that is the translator or the shader, and the same goes for
whether `BandedLayerNode` pays (Reef, Bug Woods and Ruins band; #396 found
bands a loss on the emulator). Reef also shows a faint seam where two of its
caustic bands meet, which wants the same device to tell timing from a bug.

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
(`switchlings_register_natives`), since SDL dlopens `libAndroidShell.so`
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
package and its signing certificates' SHA-256 fingerprints). It is empty,
so the route answers 404 and Android shows the page in the browser, whose
button opens the `switchlings://` link. To turn it on: add the Play App
Signing key's fingerprint (Play Console → Setup → App signing) and the
upload key's, deploy the server to fleon-home and restart it. Nothing was
deployed.
