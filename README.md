# SpriteKit for Android

A Swift runtime that runs SpriteKit games on Android. A game's own sources
compile for Android unedited, keeping `import SpriteKit`, `import UIKit`,
`import CoreGraphics` and the rest; this runtime answers those imports with
its own implementation of the SpriteKit, UIKit, CoreGraphics and CoreText
surface, draws with GLES 3 through SDL3, and puts Google Play's billing,
achievements, leaderboards and saved games behind the Apple-shaped APIs a
game's managers already call.

Nothing here is specific to any game. A game keeps its own Android code (its
controller, its managers' bodies, its Gradle app, its art pipeline and its
notes) in its own repository, and changes here are described in SpriteKit's
and Apple's terms.

## Why a SpriteKit runtime rather than an engine

A SpriteKit game is mostly code written against SpriteKit: its nodes are
subclasses of `SKNode`, `SKScene` and `SKSpriteNode`, often dozens of them.
Wrapping a C++ engine (Axmol, Cocos2d-x) would mean a hand-written C++
subclass bridging back into Swift for every one, since Swift cannot override
a C++ virtual method. A Swift-native SpriteKit keeps them compiling as they
are, and the surface a game uses is narrower than SpriteKit's: a few node
types, a handful of action primitives, shaders, crop and effect nodes, warps
and emitters.

## Layout

```
Package.swift        SpriteKitShim, GLESRenderer, PlatformShim and their
                     tests. Builds and tests on macOS.
Sources/
  SpriteKitShim/     The scene graph, actions, textures, labels, shapes,
                     crop and effect nodes, warps, emitters, transitions,
                     camera, SKRenderer, the UIKit / CoreGraphics /
                     CoreText / CoreImage surface, and Foundation's
                     NSUbiquitousKeyValueStore. On Apple platforms it
                     re-exports the real SpriteKit.
  GLESRenderer/      The GL-free half of the renderer: shader translation,
                     batching, render targets, compressed pages, the render
                     scale governor. Host-tested.
  PlatformShim/      The Android stand-ins for Apple's services, without the
                     device: Play Billing, Play Games, Saved Games (the
                     key-value store's cloud) and the sync engine,
                     MediaCodec-backed AVFoundation, haptics,
                     sharing, the launch-argument domain.
Tests/               Host tests: no device or GL context.
Modules/             Android-only. Targets that exist to own a module name
                     (SpriteKit, UIKit, CoreGraphics, CoreText, CoreImage,
                     QuartzCore, AVFoundation, StoreKit, GameKit, Metal,
                     CoreVideo, CryptoKit, Network, os, simd), each
                     re-exporting the shim, so a game's imports resolve.
Shell/               Android-only. The app shell: SDL3, the EGL context, the
                     frame loop and its pacing, input, audio, the GL backend
                     and `GameHost`, the seam a game's controller adopts.
Text/                HarfBuzz shaping, FreeType metrics and rasterising, the
                     glyph atlas.
Vendor/              Scripts that fetch and build FreeType, HarfBuzz and SDL.
                     Nothing binary is committed.
Scripts/             Building SDL and a game's shell library, checking the
                     runtime alone, launching with arguments, the emulator
                     pool.
Templates/App/       The Android app a game copies: the Gradle project,
                     MainActivity and the Java half of each platform
                     service (Templates/App/README.md).
```

`Modules` is a package of its own because a target named `CoreGraphics`
cycles with the system module on macOS; keeping it apart is what lets the
shim build and test on a Mac. `Text` is apart because it is the only part
with C dependencies, and `Shell` because it needs SDL's and the NDK's
headers.

## Using it in a game

Add this repository as a git submodule named `spritekit-android` inside the
game's Android directory. The name matters: a package's identity is its
directory's name, and the manifests here refer to this package as
`spritekit-android`.

```
<game>/Android/
  spritekit-android/   this repository (submodule)
  Game/                the game's package (GAME_PACKAGE_DIR)
  App/                 the game's Gradle project (APP_DIR), copied from
                       Templates/App/base
```

The game's package depends on `../spritekit-android`,
`../spritekit-android/Modules` and `../spritekit-android/Shell` by path, and
holds:

- **Its sources**, as symlinks into the game's `Source/` at their own paths,
  leaving out the Apple app's entry (`AppDelegate`, `SceneDelegate`, the view
  controller) and the managers that reach Apple's services.
- **A controller** adopting `GameHost`: the Android counterpart of the game's
  view controller and app delegate (launch work in the Apple order, the
  first scene, layout, Back, keys, links).
- **The managers' bodies**: the game's audio, store, Game Center, iCloud and
  haptics managers, their public API kept name for name, over
  `PlatformShim`'s backends.
- **An entry target** that exports `SDL_main` and calls `Shell.start`, and a
  dynamic library product named `AndroidShell` (the library SDL loads):

```swift
@_cdecl("SDL_main")
nonisolated public func SDL_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    Shell.start(
        argc: argc, argv: argv,
        app: AppIdentity(name: "My Game", bundleIdentifier: "com.example.mygame", key: "mygame"),
        game: MyGameController.self
    )
}
extension MyGameController: GameHost {}
```

`AppIdentity` names the app wherever the runtime needs a name: `CFBundleName`
and `CFBundleIdentifier`, the logcat tag, the window title, the
`debug.<key>.*` system properties, the Google Play page and the saved game
(`<key>-progress`). Use the iOS bundle ID as the Android package name, so one
product ID serves both stores.

Build the game package with the same concurrency settings as its Xcode
target (Swift 5 mode, main-actor default isolation, Approachable
Concurrency): game code is written against them.

### The contract

`Shell/Sources/GLESBackend/GameHost.swift` is everything the shell asks of a
game: made with the view, it launches, lays out in points with the safe area,
idiom and refresh rate, takes Back, keys and links, gets the audio backend,
reports the scene size for a view size, and answers the frame rate and render
scale questions. Nothing in the shell imports a game.

### Scripts

The scripts find the game from the runtime's parent directory, or from
`GAME_ANDROID_DIR`, `GAME_PACKAGE_DIR` (default `Game/`) and `APP_DIR`
(default `App/`), in `Scripts/config.sh`.

```bash
Vendor/build.sh android                     # FreeType + HarfBuzz, both ABIs
Scripts/build-sdl.sh arm64-v8a              # SDL 3.4.20, staged into the game's App
Scripts/build-shell.sh --debug arm64-v8a    # the game's AndroidShell library, staged
Scripts/check-android.sh arm64-v8a          # this runtime alone, cross-compiled
swift test                                  # host tests, on a Mac
```

`build-shell.sh --debug` is for every check; an optimised build (no flag) is
for measuring frame times, and `--store` for a store upload (no `DEBUG`, and
symbols kept for the bundle's native debug metadata). `Scripts/launch.js`
starts the app with launch arguments, taking its package and activity from
`SKA_APP_PACKAGE` and `SKA_APP_ACTIVITY`.

## Toolchain

Swift 6.4.2 (open source, via swiftly: Xcode's Swift cannot cross-compile),
the `swift-6.4.2-RELEASE_android` SDK, Android NDK r30 at
`$ANDROID_NDK_HOME`, JDK 17, cmake and ninja. Native code links against API
23; an app may declare a higher `minSdk`.

## How it works

### A frame is a value

The shim issues no draw calls. `SKView.tick` returns a `DrawList`: a flat,
ordered list of sprite, shape and label commands with nested effect and crop
groups. The scene graph, transforms, actions and draw order are therefore
testable on a Mac with no window, and the renderer is a separate consumer.
Draw order is by accumulated `zPosition`, sorted stably. At the same z,
keeping sibling order (`ignoresSiblingOrder` false, SpriteKit's default and
the view's here), nodes draw in tree order; ignoring it, they fall in
SpriteKit's three classes, each in tree order: colour sprites, shapes, crop
and effect groups; then textured sprites and labels; then shader sprites
(`DrawOrderTests`, measured by readback). In the middle class SpriteKit
keeps each texture's sprites together, and the labels together, each group
where its first member is: its most frequent answer, which the list gives
every time. A snapshot (`texture(from:)`) is drawn in tree order whatever
the view's setting.

### SpriteKit's behaviour, measured

Where SpriteKit's behaviour is not documented, it was measured on a Mac
through `SKRenderer` and pinned in host tests:

- **Actions:** the timing modes' curves, a scene's first frame counting no
  time, frames over a second counting none, time a frame runs past an
  action's end handed on to what follows (`ActionTimingTests`,
  `ActionClockTests`).
- **Warps:** each cell subdivided bilinearly, levels past 3 drawn as 3, two
  triangles a cell (`WarpGeometryTests`, against measured pixels).
- **Nodes:** `calculateAccumulatedFrame()` includes hidden and transparent
  descendants; a scaled 9-slice keeps its caps.
- **Paths and contexts:** checked against CoreGraphics' own API, every blend
  mode included.

A change to the shim's behaviour comes with a test of this kind.

### The renderer

- **Shaders:** SpriteKit's GLSL dialect (ES 1.0 with its preamble:
  `u_time`, `v_tex_coord`, `u_texture`, `SKDefaultShading()`) is rewritten to
  ES 3.0 at upload by `ShaderTranslator`. `gl_FragCoord` is rewritten to count
  from the top left, as Metal's does, so shaders written for SpriteKit land
  the right way up.
- **Effect and crop nodes** composite through render targets; a draw counts
  the pixels of the target it lands in, as on Metal. `shouldRasterize` keeps
  its pixels until the subtree changes (a digest of transforms and textures,
  not uniform values).
- **Batching:** one vertex and one index stream a frame, written through one
  synchronised map of a freshly orphaned buffer (Adreno drivers let
  unsynchronised writes land over draws still pending).
- **Meshes:** `SKTriangleMesh` and warped sprites batch as geometry with the
  sprites of their texture.
- **Render scale:** fill rate decides frame time on mid-range GPUs, so the
  scene can draw at a share of the screen's size, the display scaling it up
  (`ANativeWindow_setBuffersGeometry`). `RenderScaleGovernor` picks the scale
  by wall-clock frame times; a game's settings can fix it.
- **Pacing:** frames start on the display's vsync (AChoreographer), so every
  step moves the scene a whole number of refreshes.
- **Programs** are kept as driver binaries between launches, keyed by source
  and driver, so an app update doesn't relink what didn't change.

### Art

A game's images reach the runtime as an index and pages:

```jsonc
{
 "version": 2, "scale": 3,
 "pages": [ { "file": "atlas-000.ktx", "width": 2048, "height": 2048,
              "format": "astc", "block": [4, 4], "levels": 3 } ],
 "assets": {
  // rect: [x, y, width, height] in page pixels, top left origin;
  // size: points; caps: 9-slice insets [top, left, bottom, right].
  "Button": { "page": 0, "rect": [0, 0, 192, 96], "size": [64, 32], "caps": [12, 12, 12, 12] }
 }
}
```

`AssetIndex` reads it and `SKTexture(imageNamed:)` resolves through it, so a
texture reports its art's size in points and `textureRect` is its slice of
the page. Pages are ASTC with mip levels where the GPU samples ASTC
(`GL_KHR_texture_compression_astc_ldr`), else decoded on the CPU
(`ASTCDecoder`) and uploaded as RGBA8. Images over 512 px take a page of
their own, so they can repeat; packed images keep a 4 px gutter so filtering
and block compression never reach a neighbour. Shaders sample level 0 only.

### Packing art from an asset catalog

A game with no exporter of its own packs its Apple asset catalogs straight
into the art above with `Tools/Art/xcassets-art.js`:

```
Tools/Art/ASTC/build-astcenc.sh     # once per checkout: astcenc into Tools/Art/ASTC/out (gitignored)
node Tools/guard.js 12 -- node Tools/Art/xcassets-art.js <outDir> <Assets.xcassets> [<more.xcassets> ...] [--png]
node Tools/Art/check-xcassets-art.js   # the packer against Tools/Art/Fixtures
```

`Tools/guard.js` kills the run if it passes 12 GB (it never comes near:
the packer holds one decoded image and one page at a time). `--png` writes
PNG pages and needs no encoder; without it pages are ASTC with mip levels,
exactly as above. `outDir` is cleared first, so it must be empty, missing
or an earlier pack.

It reads a catalog as Xcode does:

- **Names.** Every `*.imageset` at any depth is an asset named after the
  set, prefixed `Folder/` for each folder whose `Contents.json` sets
  `provides-namespace`: `SystemSymbols/clock.fill.imageset` is
  `SystemSymbols/clock.fill`. Several catalogs pack into one index (a game's
  own art and its SF Symbols pre-rendered into a second catalog); a name
  two of them share is an error naming both.
- **Pixels and size.** Each set's highest-scale PNG (3x, 2x, 1x, then a
  single-scale image as 1x), universal before iPhone before iPad, leaving
  out dark-mode, size-class, P3 and right-to-left variants. `size` is its
  pixels over that scale, so `SKTexture(imageNamed:).size()` is Apple's.
  The index's one `scale` is the most common; an asset taken at another
  carries its own `scale`, which `AssetIndex` does not read (it only
  affects `UIImage(named:).scale`; sizes are right either way).
- **Slicing.** An image's `resizing` (the Slicing inspector) gives `caps`:
  its `cap-insets` are pixels, written as points. actool cuts out the
  pixels between the end of the `center` and the far cap, and so does the
  packer, so a sliced image's packed pixels and size are the ones the app
  gets on Apple (checked against actool's own output). A centre that tiles
  on Apple stretches here, as SpriteKit's `centerRect` does; it is noted.
- **Left out, and said so.** PDF and SVG images, JPEGs and interlaced PNGs
  are skipped by name; colour sets, app icons, data sets and the other
  kinds of set are ignored by kind. `template-rendering-intent` and
  `preserves-vector-representation` are ignored.

Every PNG form decodes (palette, grey, 1 to 16 bits, `tRNS`). Packing is
deterministic, so two runs are byte for byte the same. A whole page over
4096 px is packed with a warning: GLES guarantees 2048.

`Tools/Art/Fixtures` holds two small catalogs and their pack: the Node
check holds the packer to it byte for byte, and `PackedArtTests` reads it
through `AssetIndex`. After changing the packer on purpose,
`node Tools/Art/check-xcassets-art.js --update` rewrites it.

Measured 2026-11-17 on a catalog of 304 image sets (122 MB): 5 atlas pages
and 37 whole, 78 MB of KTX (72 MB as PNGs, 356 MB as RGBA8) in 72 s, at a
peak of 1 GB.

### Text

HarfBuzz shapes and FreeType measures and rasterises (`Text/`), behind
`SKLabelNode`, `UIFont` and a CoreText surface (`CTTypesetter`, `CTLine`), so
`NSAttributedString`-based layout code runs unchanged. Glyphs are rasterised
at the screen's density into an atlas uploaded as `R8` pages. Complex scripts
(Thai is the acceptance test) shape correctly, which FreeType alone cannot.

#### Attributed labels in several styles

An `SKLabelNode`'s `attributedText` whose runs differ in font, colour,
`.kern` or `.baselineOffset` draws each run in its own style when the label
is one line (`numberOfLines` 1), as SpriteKit does: the runs end to end on
one baseline, each raised by its `.baselineOffset`, and the whole line
placed by its combined ink as a one-style line is, so `frame` and every
alignment mode agree with SpriteKit's (`AttributedLabelRunTests`, against
Apple's `SKLabelNode` on the same font file). `SKLabelNode.runs` holds the
runs; `laidOutRuns` is set when the layout placed them, and the draw list
then emits one label command per run. A wrapped label in several styles
still draws in its first run's style.

### The platform layer

Everything Apple-shaped that needs a device goes through one channel
(`PlatformChannel`): Swift calls the app's Java (`platformCall(name, json)`),
and Java's answers and events are queued and drained by the frame loop on the
game's thread. Both directions are JSON as UTF-8 bytes (JNI's modified UTF-8
splits characters outside the BMP). The decisions above Java are Swift here
and tested on a Mac against a fake Java:

- **Purchases** (Play Billing): prices, purchases, pending purchases,
  acknowledgement, restore on launch and resume, refunds.
- **Achievements and the player** (Play Games Services v2): silent sign-in,
  achievements mapped from Game Center's IDs, incremental ones from Game
  Center's percentages.
- **Saved data** (Play Games Saved Games): a key-value store's records in one
  snapshot, merged commutatively so a conflict resolves without loss.
- **Audio:** sound effects (`.wav`) through SDL's audio streams, music
  through the NDK's MediaCodec, with loop points kept in presentation time.
  A track may be AAC in `.m4a`, MP3 or Ogg Vorbis (`.ogg`), looked for in
  that order, so the files an iOS build ships play as they are. Gradle
  stages them in `audio/SFX` and `audio/Music`, and `Bundle.main` finds them
  there too (`ResourceBundle.defaultFolder`).
  A track with no loop points of its own repeats whole with
  `MusicLoop.wholeTrack`, as `AVAudioPlayer`'s `numberOfLoops = -1` does.
- **Media:** `AVAssetWriter`, `AVAudioFile` and composition stand-ins over
  MediaCodec and MediaMuxer, for games that render video.
- **The device:** haptics (primitives where the vibrator has them), audio
  focus, battery saver as Low Power Mode, sharing through Android's chooser.

### iCloud's key-value store, as Apple names it

A game that talks to `NSUbiquitousKeyValueStore` itself (keeping its
progress there as one `Data`, say) gets Apple's API
(`Sources/SpriteKitShim/UbiquitousKeyValueStore.swift`). Values are kept on
the device in user defaults, each with the time it was set, and synced
through any `CloudKeyValueStore` the game installs as its `cloud` (Play
Games Saved Games), one record per key under `ubiquitous.<key>`. When two
devices write one key, the later write wins, as with iCloud; two writes at
the same instant settle on the same value everywhere. The keys that change
here are posted as `didChangeExternallyNotification`. The reason is the
initial sync for the first merge that hears from the cloud (installed with
data there, or the first fetch after Play signs in), and a server change
after that. A removal is a record too, so it travels. With no cloud the
store is the device's alone, as with iCloud off. It is safe from any
thread; the cloud is spoken to on the main thread. A game uses this or
`ICloudSyncManager`'s `SyncEngine` on one cloud, not both: each takes the
cloud's `externalChanges`.

Where it differs from Apple's:

- No limits are enforced: not the 1 MB total, the 1,024 keys, the 1 MB per
  value, or the 128-character keys.
- `QuotaViolationChange` and `AccountChange` are never posted (the
  constants exist). If the player switches Play account, the new account's
  values merge with what the device holds.
- `synchronize()` always returns `true`.
- Writes are timestamped by the device's clock, so a device whose clock is
  far off can win or lose a key it shouldn't. A fresh install that writes
  before Play's snapshot arrives competes on time with the snapshot's
  values.
- The type is visible only through a module that re-exports
  `SpriteKitShim` (`Foundation` itself can't gain it).

### Ratings: Play In-App Review

`SKStoreReviewController.requestReview(in:)` (and `requestReview()`,
`AppStore.requestReview(in:)`) in the `StoreKit` module go to
`StoreReview.request()` (`Sources/PlatformShim/StoreReview.swift`):
`PlayInAppReview` over the shell's channel, nothing in a host build. As on
iOS, the request is fire-and-forget and the store decides whether a card
shows; a game's own rules about when to ask stay its own. One request is
with Play at a time; one that gets no answer within a minute stops holding
the next one back.

The Java half is a class of its own in the game's app (`PlayReview`, on
`com.google.android.play:review`), under `review`:
`request` runs `ReviewManager.requestReviewFlow()` then
`launchReviewFlow(activity, info)` and posts `requested {ok}` when the flow
is over. A build not installed from Play runs the flow and shows nothing, as
TestFlight shows nothing on iOS.

### The shell

- **The main thread** is SDL's thread: `MainThread.claim()` makes it so for
  Foundation, a hook gives the main actor an executor drained by the frame
  loop, and the loop drains `DispatchQueue.main` too.
- **Saved defaults:** corelibs keeps `UserDefaults` in memory on Android; the
  shell writes them to internal storage every few seconds and on going to the
  background.
- **Resources:** the process is `app_process`, so `Bundle.main` has no files;
  resources (data files, fonts, `.lproj` folders) are copied out of the APK on
  first use. The version comes from the APK.
- **Layout:** a point is a dp. The safe area includes the system bars, the
  cutout and the gesture handle; Back (and Android 16's predictive back)
  arrives as Escape.
- **Input:** one touch at a time, hardware keys by HID usage, gamepads
  through SDL.
- **Threads:** libdispatch workers start below the frame thread's priority.
- **Launch arguments** (debuggable builds only) come from the intent, as
  `-Key value` pairs in the argument domain, as on Apple.
- **Debug properties:** `adb shell setprop debug.<key>.<name> <value>`, read
  at start: `renderscale`, `slowdown`, `transitionslowdown`, `programcache`,
  `bandblur`, `poison` (makes a forgiving GPU fail as a strict one would),
  `workernice`, `dump` (the scene graph to `cache/scene-dump.txt`).

## What isn't here

`SKPhysicsBody` and physics, `SKVideoNode`, `SKAudioNode`, `.sks` scene and
action files, `SKReferenceNode`, UIKit views beyond what a SpriteKit app's
window needs (no `UIScrollView`, table or collection views, gesture
recognizers or SwiftUI), and anything that needs the Objective-C runtime
(`#selector`, KVO). A game that needs one adds it here.

## Emulators

`Scripts/emulators.sh` lends emulators from a pool of four that every game on
the machine shares, one session to a slot:

```bash
eval "$(Scripts/emulators.sh acquire <session>)"   # exports ANDROID_SERIAL
Scripts/emulators.sh release <session>
Scripts/emulators.sh status
```

Slots boot on the host GPU and lapse after their lease. A machine names its
pool's AVDs, state and the debug properties cleared for each new owner in
`~/.config/spritekit-android/pool.env` (see the script's header). Emulator
frame times describe the host's GPU, not a phone's: measure performance on a
device.

## Contributing

- Nothing game-specific: no game's names, identifiers, content or reasons.
  Describe a change by what SpriteKit or Apple does, and test it with neutral
  fixtures.
- Fill a gap with SpriteKit's or Apple's exact signatures; measure behaviour
  against Apple's on a Mac where it runs there, and pin it in a host test.
- Every change: `swift test` and `Scripts/check-android.sh arm64-v8a`.
