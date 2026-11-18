# SpriteKit for Android

A Swift runtime that runs SpriteKit games on Android. A game's own sources
compile for Android unedited, keeping `import SpriteKit`, `import UIKit`,
`import CoreGraphics` and the rest; this runtime answers those imports with
its own implementation of the SpriteKit, UIKit, CoreGraphics and CoreText
surface, draws with GLES 3 through SDL3, and puts Google Play's billing,
achievements, leaderboards and saved games behind the Apple-shaped APIs a
game's managers already call.

It also holds the platform code SpriteKit games share on every platform,
Apple's included (`Platform/`): what's game-agnostic in a game's helpers and
managers, so each game stops keeping its own copy and a fix reaches them
all.

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
Package.swift        PlatformServices, SpriteKitShim, GLESRenderer,
                     PlatformShim and their tests. Builds and tests on
                     macOS.
Sources/
  PlatformServices/  Plain Foundation, on every platform: the protocols a
                     game's audio, achievements, leaderboards, purchases and
                     synced saved data stand on, the sync engine's merge and
                     the render scale governor.
  SpriteKitShim/     The scene graph, actions, textures, labels, shapes,
                     crop and effect nodes, warps, emitters, transitions,
                     camera, SKRenderer, the UIKit / CoreGraphics /
                     CoreText / CoreImage surface, and Foundation's
                     NSUbiquitousKeyValueStore. On Apple platforms it
                     re-exports the real SpriteKit.
  GLESRenderer/      The GL-free half of the renderer: shader translation,
                     batching, render targets, compressed pages.
                     Host-tested.
  PlatformShim/      The Android stand-ins for Apple's services, without the
                     device: Play Billing, Play Games, Saved Games (the
                     key-value store's cloud), MediaCodec-backed
                     AVFoundation, haptics,
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
Platform/            The platform code games share, on Apple platforms and
                     Android alike: `Macros` (`@NSCodingUnsupported`),
                     `PlatformCore` (geometry shorthands, timing curves and
                     eased actions, seeded randomness), `PlatformAudio`
                     (sound effects and the soundtrack), `PlatformInput`
                     (focus for the remote, gamepads and the pointer;
                     keyboard and Menu protocols), `PlatformDisplay`
                     (frame-rate and graphics settings with Auto),
                     `PlatformGameCenter` (sign-in, achievements,
                     leaderboards) and `PlatformStore` (in-app purchases).
                     See "Shared platform code".
Text/                HarfBuzz shaping, FreeType metrics and rasterising, the
                     glyph atlas.
Vendor/              Scripts that fetch and build FreeType, HarfBuzz and SDL.
                     Nothing binary is committed.
Scripts/             Building SDL and a game's shell library, checking the
                     runtime alone, launching with arguments, the emulator
                     pool.
Library/             Android-only Java: the Gradle library modules a
                     game's app includes in place from the submodule.
                     SDL's activity under `SpriteKitActivity`, and the
                     Java half of each platform service (`spritekit`,
                     `spritekit-billing`, `spritekit-notifications`).
Templates/App/       The Android app a game copies: the Gradle project,
                     its manifest and a `MainActivity` over the library
                     (Templates/App/README.md).
```

`Modules` is a package of its own because a target named `CoreGraphics`
cycles with the system module on macOS; keeping it apart is what lets the
shim build and test on a Mac. `Text` is apart because it is the only part
with C dependencies, and `Shell` because it needs SDL's and the NDK's
headers.

## Shared platform code

`Platform/` is a package of its own, for Apple builds as much as Android's.
On iPhone, iPad, Apple TV and the Mac (Catalyst) it builds against Apple's
SpriteKit, UIKit and services; on Android, and on a Mac host for its tests,
against the shim, which `SPRITEKIT_SHIM` selects there. Its sources import

```swift
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif
```

and never `Modules/`, whose targets collide with Apple's frameworks. It
reaches this package as `..`, so a game's graph holds one
`spritekit-android`.

A game adds `<submodule>/Platform` to its Xcode project as a local package
and links the products it uses (in place of its own `Macros` package, which
it deletes: two targets named `Macros` can't share a graph), and its Android
package depends on it by path. Code moved here is public and keeps its
names, so a game deletes its own copy and imports the module (`import
PlatformCore`) in the files that use it.

What belongs here: code a game's helpers and managers would otherwise copy
that carries nothing of any one game. What a game configures (its sounds,
products, achievements, constants) it passes in.

### Game Center (`PlatformGameCenter`)

`GameCenterManager` signs the player in at launch, reports achievements,
sends scores and opens the dashboard and leaderboards, over
`AchievementsBackend` and `LeaderboardsBackend`: GameKit on Apple
(`GameKitAchievements`, `GameKitLeaderboards`), Play Games on Android
(`usePlayGames(channel:mapping:)`, with `PlayGamesMapping(resource:)` reading
the mapping the APK carries), `LocalAchievements` and `LocalLeaderboards`
otherwise. A game configures it with:

- `progress`: each achievement's percentage by its ID, from the game's saved
  data and the moments recorded so far (`percent(_:of:)` and
  `percent(when:)` round as the services count);
- moments (`record(_:)`): firsts saved progress can't tell, kept under
  `momentsKey`, or saved by the game itself (`saveMoments`,
  `resetMoments`) when its synced saved data carries them;
- `banners`: `.whenEarnedHere` (the default: not for what a sign-in catches
  up or another device earned), `.always` or `.never`;
- `logSubsystem`, and `resetsOnSignIn` for a debug reset.

At each sign-in it loads what the service holds and sends only what has
moved past it; a report that doesn't arrive is sent again next time.
`start(presentSignIn:answered:)` hands GameKit's sheet to the game (or the
top view controller) and runs `answered` at the first answer, which a launch
screen may wait on. `player` (`GamePlayer`: the service's ID, name and
GameKit's legacy `playerID`) and `signInChanged`/`playerChanged` are for a
server or a credit; `submitScore(_:context:to:)`, `standing(on:)` and
`showLeaderboards(_:)` for leaderboards.

### Store (`PlatformStore`)

`StoreManager` keeps what's owned, prices and purchase dates over a
`BillingBackend`: `StoreKitBilling` (StoreKit 2) on Apple,
`PlayBilling(channel:products:)` on Android, `SimulatedBilling` for a debug
build's simulated purchases, `NoBilling` with no store. A game lists its
products (`StoreProduct`: `.nonConsumable` or `.consumable`), with
`deliver` for consumables, and an optional preview price. What's owned
(bought, or free where the player shops) is cached, so locks are right
before the store answers: the cache stands until the backend says it knows
(`knowsOwnedProducts` after StoreKit's entitlements or Play's first query,
`knowsFreeProducts` once prices have loaded), and simulated purchases never
reach it. The earliest purchase date and when the device
first saw each product owned are kept, so `owned(_:by:)` grants an offer to
whoever owned a product by a deadline. `StoreManager.didChange` is posted
whenever anything moves.

`StoreKitBilling` listens to `Transaction.updates`, finishes unfinished
transactions, buys promoted purchases started on the App Store
(`PurchaseIntent`), hides a promotion on a device that owns its product
(`promoted`), and, with `confirm`, lets a server credit each transaction
before it is finished.

### Audio (`PlatformAudio`)

One `AudioManager` plays a game's sound effects and soundtrack on every
platform, over `AudioBackend`: on Apple platforms `AppleAudioBackend`
(pools of `AVAudioPlayer`s for sounds; an `AVAudioEngine` streaming each
track, its intro once and then its loop section seamlessly, crossfading
tracks on player nodes of their own, and picking the soundtrack up again
after an interruption, a route change or the background), on Android the
shell's, which the game hands over as it opens:

```swift
// At launch
AudioManager.configure(AudioConfiguration(
    sounds: AudioConfiguration.sounds(Sound.self) { sound in
        sound == .step ? AudioConfiguration.Sound(sound.rawValue, rateVariation: 0.9...1.1) : nil
    },
    soundVolume: 0.8, musicVolume: 0.4,
    crossfadeDuration: 2, musicFadeDuration: 0.25,
    musicLoops: loops,                        // [track: MusicLoop]
    settings: .init(write: { cloud.set($0, forKey: $1) })
))
// Android only, in the game's shell wiring
Shell.audioDidOpen = { AudioManager.shared.use($0) }
```

Then `AudioManager.shared.play(_:)` (a name or a `String` enum; returns the
sound's duration; `skipIfPlaying`, `variants`), `playEffect(_:repeats:
variants:onFinish:)` and `stopEffect(_:fadeDuration:)` for sounds on voices
of their own, `playMusic(_:loop:)` (the track already playing keeps going,
another crossfades in, nil fades out), `stopMusic`, `pauseMusic`,
`resumeMusic`, `duckMusicForJingle()` and `restoreMusicAfterJingle(duration:)`;
`AudioManager.isSoundEnabled` and `isMusicEnabled` are the settings'
switches, saved under `settings.soundEnabled` and `settings.musicEnabled`
unless the configuration says otherwise, and `savedDataDidSync(_:)` follows
another device's. Android's audio focus arrives through
`audioFocusDidChange(otherAudio:interrupted:)`; on Apple platforms the backend
reports another app's audio itself. Whatever a backend can't do (a voice of
its own, on a backend without them) falls back to playing the sound once.

### Input: focus, gamepads, keys (`PlatformInput`)

Focus is how the Apple TV remote, gamepads and the Mac's pointer reach a
scene's controls. A control adopts `Focusable` (where it sits, whether it
takes focus now, showing focus its own way, `fadeFocusRing` for a ring that
glows), and a control that takes some moves itself `FocusSteering`.
`SceneControls` collects what's on screen in reading order, only a popup's
while one is open (a direct child of the scene adopting `FocusOverlay`),
skipping hidden, faint and `hidesFocus` subtrees; a scrolling list adopts
`FocusScrollArea` so its controls out of view still take focus and scroll
in. `FocusNavigator` moves focus to the nearest control each way
(`nearest(from:among:_:)`), presses it, starts where the scene or popup
says (`FocusDefaulting`) and comes back where it was when a popup closes.

`FocusDriver` is what a view controller holds: on Apple TV focus always
shows; elsewhere a gamepad's first press brings it up where the screen
starts it, and a touch (`TouchWatcher` on iOS, `watchTouches(in:)` on
Android), the Mac's pointer moving (`HoverFocus`, which shows focus under
the pointer meanwhile) or the last gamepad going hide it again.

`GamepadInput` reads extended gamepads: GameController on Apple, the
shell's `GamepadEvents` on Android. The d-pad or left stick points a way
(with press and release thresholds on the stick), the pad that last
pointed holds it and a held way repeats; each button sends one press
(`Action.move`, `Action.press`). `FocusDriver.connect` has the d-pad and A
drive focus and hands the other buttons to the game. On Apple TV, which
turns a gamepad's presses into the remote's too, `routeRemotePress` holds
the remote's back for the echo window and drops the echoes; Menu stays the
remote's way back. `playScript` plays `GamepadScript` steps on a pretend
pad for test runs, and `showVirtualGamepad` puts up Apple's on-screen one.
Timings and thresholds are `GamepadConfiguration`'s and
`FocusConfiguration`'s (`FocusNavigator.configuration`).

`KeyboardControllable` (keys by HID usage; the remote's Back and Android's
back arrive as Escape) and `MenuToggling` (a gamepad's Menu) are the scene
protocols the controllers route to, and `TouchOrigin` (with
`TouchOriginWindow`) remembers where the player last touched or pressed.

### Display: frame rate and graphics (`PlatformDisplay`)

`DisplaySettings` holds the player's frame rate (Auto, or one of
`Configuration.frameRates` the screen can draw) and graphics tier (Auto, or
one of five shares of the pixels, `Graphics`, which a game names in its own
strings), kept on the device under `keyPrefix`. Auto draws at 60 (50 on a
50 Hz screen), never slower, and between Highest and Medium as
`RenderScaleGovernor` chooses once for the device (`noteAutoChosen`); a
pinned scale or a simulator leaves Auto nothing to choose. `choices` is
what the renderer applies, `running` what it draws at now. A game
configures the store, the scenes that measure (`isMeasured`: not a loading
screen), a pinned scale, a logger and a save hook for syncing
(`didSave`, `pickKeys`, `savedDataDidSync`).

On Apple, `RenderScaleController` applies them to the game's `SKView`
(rate, `contentScaleFactor` and the Metal drawable), timing frames as the
view's delegate; the game calls `apply()` as each scene change starts,
`fitDrawable()` after layout, and hears density changes through
`onDensityChange`. On Android the shell's renderer applies them through
`GameHost`: a controller that also adopts `DisplaySettingsHost` gets its
display members (`displayChoices`, `observeDisplayChoices`, `isMeasured`,
`setRunning`, `noteAutoChosen`, `pinnedRenderScale`) from
`DisplaySettings`, so it needn't write them.

Checks: `swift test --package-path Platform` on the host, the Apple builds
(`xcodebuild -scheme <product> -destination 'generic/platform=iOS
Simulator'`, and tvOS and Mac Catalyst), and `Scripts/check-android.sh`,
which builds it for Android.

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
                       Templates/App/base, which builds the runtime's
                       Library/ modules in place
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
- **Timing functions:** `timingFunction` runs on the timing mode's curve
  and is clamped to 0...1, finishing an action once it reaches 1; custom
  actions get curved time, sequences and groups run their children on their
  curve (jumping to the end once their time is past), repeats ignore it.
  `reversed()` keeps a move's, rotation's, scale's or custom action's mode,
  function and speed; sequences, groups, repeats, waits and fades come back
  linear at speed 1, and a reversed fade takes no time, as SpriteKit's
  does (`ActionTimingFunctionTests`). `SKShader` is open, its designated
  initialisers main-actor isolated so a main-actor-by-default game can
  subclass it.
- **`run(_:) async`:** returns on the frame the action finishes (an instant
  one included), awaited actions play in turn, and it never returns for an
  action taken off or a node out of a scene (`AsyncRunTests`).
- **Warps:** each cell subdivided bilinearly, levels past 3 drawn as 3, two
  triangles a cell (`WarpGeometryTests`, against measured pixels).
- **Nodes:** `calculateAccumulatedFrame()` includes hidden and transparent
  descendants; a scaled 9-slice keeps its caps.
- **Constraints:** applied after the actions each frame, before
  `didApplyConstraints()`; nodes take turns in the order they were given
  constraints or entered the scene, not in tree order, and each set after
  a pass adds another turn while keeping the earlier ones, as SpriteKit's
  list grows; ranges clamp as `max(lower, min(upper, v))`; `orient`
  clamps between the target's direction, in [−π/2, 3π/2), plus its limits,
  unwrapping nothing (`ConstraintTests`). A `zRotation` constraint's
  `referenceNode` is ignored: SpriteKit's use of it follows no rule found.
- **Scenes:** a scene's `frame` is its size placed by its anchor point, and
  its position and scale stay out of it and of its accumulated frame; a
  scene is never among its own `nodes(at:)` (`SceneFrameTests`).
- **Tile maps:** `SKTileMapNode` draws one sprite per filled cell, each
  definition at its own size from its cell's bottom-left corner, turned
  counter-clockwise within that rect by its rotation, and tinted by the
  map's colour as a sprite is; cell centres and tile indices (clamped at 0,
  not at the far edge) are SpriteKit's (`TileMapTests`). Animated
  definitions show their first texture, and automapping keeps a group's
  centre rule.
- **Paths and contexts:** checked against CoreGraphics' own API, every blend
  mode included.
- **Core Image:** `CILinearGradient` and `CIRadialGradient` mix
  premultiplied colour in linear light and encode sRGB as written (black to
  white is 188 half way); pixels take their centre's colour; a fractional
  rectangle ends in a part-covered pixel; `CIGaussianBlur`'s radius is
  `applyingGaussianBlur`'s sigma, and an unclamped blur grows the extent by
  Core Image's own margin (6 each side at sigma 2); an unknown filter name
  gives an empty image (`CoreImageTests`, against Core Image's own output).
  A bitmap cropped off whole pixels keeps every pixel it reaches, where
  Core Image keeps the fraction. `SKEffectNode.filter` is kept, not yet
  drawn.
  mode included; `setLineDash(phase:lengths:)` strokes in dashes as
  CoreGraphics does, the pattern scaled with the context (`LineDashTests`).

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
- **Shapes** are rasterised on the CPU into coverage masks, cached by what
  they draw. A shape whose path changes every frame (marching ants, a ring
  drawing itself round) draws its last mask while the next is made on a
  thread of the lowest priority (`MaskLag`), a frame or two behind; one
  appearing gets its mask at once, and a fixed frame step makes every mask
  at once. The frame report logs what masks have cost.
- **Render scale:** fill rate decides frame time on mid-range GPUs, so the
  scene can draw at a share of the screen's size, the display scaling it up
  (`ANativeWindow_setBuffersGeometry`). `RenderScaleGovernor` picks the scale
  by wall-clock frame times; a game's settings can fix it.
- **Pacing:** frames start on the display's vsync (AChoreographer), so every
  step moves the scene a whole number of refreshes.
- **Programs** are kept as driver binaries between launches, keyed by source
  and driver, so an app update doesn't relink what didn't change.
- **Shapes** are rasterised on the CPU into coverage masks at the density
  they're drawn at, except that no mask is made larger than the GPU's
  biggest texture: a very long shape is rasterised coarser instead, its
  edges a little softer.

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
then emits one label command per run. On several lines (`numberOfLines`
other than 1, no `preferredMaxLayoutWidth`) the runs break at their
newlines, and each line takes the largest ascent, descent and leading of the
runs on it, as SpriteKit sizes the block (`AttributedParagraphParityTests`).
A wrapped label in several styles still draws in its first run's style.

### UIKit around the scene

A game's SpriteKit code also reads UIKit, so the shim carries the parts it
reaches for, kept as values where Android has nothing to show:

- **Views:** `UIView`'s `frame`, `subviews`, `isUserInteractionEnabled`,
  `contentMode`, `autoresizingMask` and `clipsToBounds`, `UIImageView`,
  `SKView(frame:)`. Only the game's `SKView` draws; other views are kept, not
  composited, and `snapshotView(afterScreenUpdates:)` and `drawHierarchy`
  answer nil and false, as UIKit does for a view it can't render.
- **Reserved regions** (iOS 27.1): `reservedRegions(kind:options:)` answers
  from `reservedRegionList`, which the shell may fill (a foldable's hinge);
  none by default, as on a phone without one.
- **Windows and scenes:** a window joins its scene through `windowScene`;
  the scene's `windows`, `keyWindow` and `coordinateSpace` follow.
- **SF Symbols:** Android has no symbol font, so
  `UIImage(systemName:withConfiguration:)` looks a symbol up in the packed
  art as `SystemSymbols/<name>`. `Tools/Art/system-symbols.sh` renders the
  symbols a game names into an asset catalog for the packer, with UIKit as
  a Mac Catalyst tool (AppKit rounds symbol sizes up to whole points); the
  configuration a game passes is the one it rendered them with.
- **Text types:** `NSParagraphStyle`/`NSMutableParagraphStyle`,
  `NSTextAlignment`, `NSLineBreakMode` and the `.paragraphStyle` and
  `.baselineOffset` keys, which corelibs Foundation leaves to the UI
  frameworks; `NSMutableString(initialCapacity:)` (corelibs has only
  `init(capacity:)`, and an extension can't add `init()`).
- **Settings:** `UIApplication.openSettingsURLString` opens the app's own
  page in Android's settings (`device.openAppSettings` on the channel).

### The platform layer

Everything Apple-shaped that needs a device goes through one channel
(`PlatformChannel`): Swift calls the app's Java (`platformCall(name, json)`),
and Java's answers and events are queued and drained by the frame loop on the
game's thread. Both directions are JSON as UTF-8 bytes (JNI's modified UTF-8
splits characters outside the BMP). The decisions above Java are Swift here
and tested on a Mac against a fake Java:

- **Purchases** (Play Billing): prices, purchases, pending purchases,
  acknowledgement, restore on launch and resume, refunds.
- **Consumables** (Play Billing): a price per product; a purchased
  consumable is never owned, handed to the game once (its token written
  down first, so a stop before the consume never grants it twice) and then
  consumed; a pending one when paid (`PlayBillingConsumableTests`).
- **Achievements and the player** (Play Games Services v2): silent sign-in,
  achievements mapped from Game Center's IDs, incremental ones from Game
  Center's percentages.
- **Leaderboards** (Play Games Services v2): scores, entries and Play's
  leaderboard screens behind GameKit's own calls (below).
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
  `AudioBackend.duration(ofSound:)` is a prepared sound's length (from its
  WAV), what a game reads from `AVAudioPlayer.duration`.
- **Media:** `AVAssetWriter`, `AVAudioFile` and composition stand-ins over
  MediaCodec and MediaMuxer, for games that render video.
- **The device:** haptics (primitives where the vibrator has them), audio
  focus, battery saver as Low Power Mode, sharing through Android's chooser.

#### Consumables: what the app's Java answers

A game with consumables passes them to `PlayBilling(consumables:)` and sets
`deliver`, which is handed each product and quantity once. Nothing is
delivered or consumed before `deliver` is set. On top of the one-time
products' calls and events, the Java side (`Library/spritekit-billing`) answers:

- `billing.consume` `{"token"}`: consume the purchase
  (`consumeAsync`), then send `consumed` `{"code": "ok" | <error>,
  "token"}`. A token answered `ok` is never delivered again this session,
  though a query already under way may still list it; one that fails is
  consumed again after the next query.
- Each purchase in `owned` and `updated` carries `"quantity"`
  (`Purchase.getQuantity()`, 1 unless the product allows more), which
  `deliver` is given.

A token is written to `PlayBilling.deliveredKey` in the game's user
defaults before `deliver` and removed once consumed, so a game stopped
between the two never grants it twice.

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

### Leaderboards

The `GameKit` module answers a game's leaderboard code with Apple's
signatures, on `GKLeaderboard.backend`: `PlayGamesLeaderboards`
(`Sources/PlatformShim/PlayGamesLeaderboards.swift`), which a game installs
at launch beside its achievements, or by default `LocalLeaderboards`, which
has none. `LeaderboardsBackend` itself is in `PlatformServices`, so Apple
builds share it (`PlatformGameCenter` puts GameKit behind it).

- `GKLeaderboard.submitScore(_:context:player:leaderboardIDs:)`, and the
  instance `submitScore(_:context:player:)`, each with a completion handler
  or `async throws`.
- `GKLeaderboard.loadLeaderboards(IDs:)`, with `baseLeaderboardID` and
  `title` (Play's display name).
- `loadEntries(for:timeScope:range:)` and `loadEntries(for:timeScope:)`,
  giving `GKLeaderboard.Entry` (`player`, `rank`, `score`, `formattedScore`,
  `context`, `date`), with `TimeScope` and `PlayerScope`.
- `GKAccessPoint.shared.trigger(state: .leaderboards, handler:)` and
  `trigger(leaderboardID:playerScope:timeScope:handler:)`.
- `GKGameCenterViewController(state:)` and
  `(leaderboardID:playerScope:timeScope:)`, presented with
  `present(_:animated:completion:)`, with `gameCenterDelegate`.
- `GKError`, with all of Apple's codes as Swift sees them: `catch
  GKError.notAuthenticated`, the static code shortcuts, and as an `NSError`
  in `GKErrorDomain` with the code's number.

Game Center leaderboard IDs map to Play's in the generated `PlayGamesMapping`
file, under `leaderboards` (`{"leaderboard.high-score": {"id": "CgkI…"}}`).
`today`, `week` and `allTime` are Play's daily, weekly and all-time spans;
`global` and `friendsOnly` its public and friends collections. A score's
64-bit context travels as Play's score tag, in decimal digits (none for 0),
and Play keeps a player's best (`submitScoreImmediate`), as Game Center does.

Where it differs from Apple:

- **Every completion handler runs, once:** signed out with
  `.notAuthenticated`; without Play Games on the device, or with no backend,
  `.notSupported`; for a leaderboard ID with no Play counterpart,
  `.invalidParameter`; and with `.communicationsFailure` when Play says no
  or doesn't answer within 30 seconds. Game Center queues an offline score
  and sends it later; Play's immediate submission doesn't, so a game that
  must not lose one retries.
- **Leaderboards are classic:** no recurring occurrences, start dates or
  leaderboard sets.
- **Other players:** `loadEntries(for players:timeScope:)` returns only the
  local player's entry, as Play loads no other player's score by ID.
- **No widget:** the access point draws nothing (`isActive` and `location`
  are kept, `isVisible` is false). `trigger` opens Play's leaderboards for
  `.leaderboards` or a leaderboard ID and nothing for other states
  (achievements open through `AchievementsBackend.showDashboard()`); its
  handler runs once Play has been asked.
- **No view:** a presented `GKGameCenterViewController` opens Play's
  leaderboards, an activity of its own over the game, and on the next turn
  tells its delegate it has finished, so the game's dismissal runs as on
  Apple. Play's list of all leaderboards takes no time span or collection.
- As on Apple, only `GKGameCenterViewController` (a view controller) is
  main-actor isolated. `GKLeaderboard`'s `async` calls are nonisolated and
  run on their caller's actor, so Swift 6 code awaits them from any actor,
  as it does Apple's; they reach the backend on the main actor, where
  it lives, as `GKAccessPoint.trigger` does. `Modules/Checks` holds game
  code calling GameKit in Swift 6, Swift 5, and Swift 5 with the main actor
  as default, which `Scripts/check-android.sh` compiles.

Play's half lives in the game's app, in its Play Games service, under
`games`. Every request carries a `request` number its answer repeats; an
answer with `ok: false` may add `reason: "signedOut"`, which Java answers at
once when nobody is signed in. The leaderboard screens sign the player in
first.

| Call | Answer | Play Games Services v2 |
|---|---|---|
| `submitScores {items: [{id, score, tag}]}` | `scoresSubmitted {ok}` | `submitScoreImmediate` for each, then `Tasks.whenAll` |
| `loadLeaderboards {ids?}` | `leaderboards {ok, items: [{id, title}]}` | `loadLeaderboardMetadata` |
| `loadScores {id, timeSpan, collection, count}` | `scores {ok, items, local?, total}` | `loadTopScores`, then `loadMoreScores` up to `count`; `loadCurrentPlayerLeaderboardScore`; the variant's `getNumScores()` |
| `showLeaderboards {id?, timeSpan?, collection?}` | — | `getLeaderboardIntent(id, timeSpan, collection)`, or `getAllLeaderboardsIntent()` |

`timeSpan` is `daily`, `weekly` or `allTime` (`TIME_SPAN_*`); `collection`
is `public` or `friends` (`COLLECTION_PUBLIC`, `COLLECTION_FRIENDS`). A
score is `{rank, score, formattedScore, tag, time, playerId, name}`, from
`LeaderboardScore` and its score holder, `time` in milliseconds since 1970
(`getTimestampMillis`); `total` is -1 when Play doesn't know it; `count` 0
loads only the signed-in player's. The library's `PlayGamesServices`
answers all four.

### A game's own fonts, and the system font

The shell registers every `.ttf`/`.otf` the game stages in the APK's
`fonts/` at launch (`AssetBundle.installFonts`), as an iOS app's
`UIAppFonts` are. The files the game names in `Shell.start(fonts:)` come
first, in its order, so its default face is the one it chose. A game that
registers its fonts itself goes through
CoreText's font manager, which `CoreTextCompat.swift` answers over
`TextMetrics.catalog` (the `TextEngine`): `CTFontManagerCreateFontDescriptorsFromURL`
lists a file's faces as CoreText does (one for a plain file, one per named
instance for a variable font: pinned against CoreText on the Mac's own
Geneva, New York and SF, all 369 of SF's), `CTFontCreateWithFontDescriptor`,
`CTFontCopyPostScriptName` and `CTFontDescriptorCopyAttribute(_, kCTFontNameAttribute)`
name them, and `CTFontManagerRegisterFontURLs` registers, reporting a second
registration of a file as an error, as Apple does, with CoreText's error
codes (101 missing file, 103 not a font, 105 already registered). A font
collection (`.ttc`) registers its first face only. A file is known by its
name without extension, so two files of one name in different folders count
as one.

`UIFont(name:size:)` is nil for a name no registered face answers to, as on
Apple, so "this face, else the system font" falls back as it does there.
`UIFont.systemFont(ofSize:weight:)` draws in the device's Roboto:
`/system/fonts/Roboto-Regular.ttf`, whose named instances are its weights on
Android 12 and later (a file a weight before that), at the instance of SF's
weight class for each UIKit weight (`.semibold` is Roboto SemiBold), chosen
by `SystemFontFaces`.

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
- **Localized strings:** `NSLocalizedString` reads the APK's
  `lproj/<language>.lproj/<table>.strings`, choosing the language as
  `Bundle.main` does: the first preferred language a folder serves, else the
  app's development region (`AppIdentity.developmentRegion`, its own folder
  or `Base`). A key the chosen table lacks is the value or the key
  (`LocalizedStringsTests`, measured on a Mac). Only `NSLocalizedString`:
  `Bundle.localizedString(forKey:value:table:)`, `String(localized:)` and
  `.stringsdict` still answer with keys, and `bundle:` isn't read. A file
  that imports only Foundation needs the shim re-exported in its module.
- **Layout:** a point is a dp. The safe area includes the system bars, the
  cutout and the gesture handle; Back (and Android 16's predictive back)
  arrives as Escape.
- **Input:** one touch at a time, hardware keys by HID usage, gamepads
  through SDL.
- **Threads:** libdispatch workers start below the frame thread's priority.
- **Associated objects:** `objc_getAssociatedObject`, `objc_setAssociatedObject`
  and `objc_removeAssociatedObjects` work without an Objective-C runtime,
  answering as Apple's do (`AssociatedObjectsParityTests`); a value goes a
  little after its object rather than with it.
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
