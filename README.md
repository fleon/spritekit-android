# SpriteKit for Android

**Bring your SpriteKit game to Android without rewriting it.**

SpriteKit for Android is a Swift runtime that lets a SpriteKit game's own
sources compile and run on Android, unedited. Your code keeps `import
SpriteKit`, `import UIKit`, `import CoreGraphics` and the rest; this runtime
answers those imports with its own implementation of the SpriteKit, UIKit,
CoreGraphics and CoreText surface a game uses, draws with OpenGL ES 3
through SDL3, and puts Google Play's billing, games services and saved games
behind the same Apple-shaped APIs your managers already call.

Alongside it is a toolkit (`Platform/`): the boilerplate nearly every
SpriteKit game ends up writing for itself (audio, in-app purchases, Game
Center, synced saved data, focus and gamepads, display settings, sprite and
text helpers), as small Swift packages that build against Apple's own
frameworks on iPhone, iPad, Apple TV and the Mac and against the runtime on
Android. A game that uses it gets its purchases, achievements and saves on
both stores from one set of calls, and it's useful on its own in a game that
only ships on Apple platforms.

It grew out of building and porting real, shipping SpriteKit games. It's
open source under the MIT license, and contributions are very welcome.

## What the runtime covers

- **Your scenes, nodes and actions as they are.** `SKNode`, `SKScene`,
  `SKSpriteNode` and your subclasses of them, actions, shaders (GLSL, as
  SpriteKit takes them), crop and effect nodes, warps, emitters, labels,
  transitions and cameras.
- **Text that looks like Apple's.** HarfBuzz shaping and FreeType
  rasterising, matched to Core Text's metrics: bidirectional text, Arabic,
  Thai, CJK, emoji and attributed strings.
- **Google Play behind Apple's APIs.** StoreKit-shaped purchases on Play
  Billing, GameKit-shaped achievements and leaderboards on Play Games,
  `NSUbiquitousKeyValueStore` on Saved Games, sharing, haptics and in-app
  review.
- **Measured against Apple.** Behaviour is checked against SpriteKit on a
  Mac and pinned in host tests, so the Android build looks and moves like
  the iOS one.
- **One build number, one product ID.** The Gradle app template reads the
  Xcode project's version and uses the iOS bundle ID, so both stores stay in
  step.

## The toolkit (`Platform/`)

Each module is its own library product in `Platform/Package.swift`; link
only the ones you need. A game passes in what's its own (its sounds, product
IDs, achievement IDs, constants), and the module does the rest.

| Module | What it saves you writing |
| --- | --- |
| `PlatformCore` | Geometry shorthands, timing curves and eased `SKAction`s, a node added at its z-position in one line, action keys as an enum, seeded randomness you can replay, a launch-argument reader for debug switches, notification observers removed together (`ObserverBag`) |
| `PlatformSprite` | A texture cache and sprite helpers, path and label builders, colours, text and font handling, SVG paths drawn as icons, shape sprites without `SKShapeNode`, scenes built off the main thread behind a loading screen, a studio's launch splash, safe-area layout, localization, debug markers |
| `PlatformAudio` | Sound effects, and a soundtrack that loops seamlessly, crossfades between tracks, ducks for a jingle and steps aside for other apps' audio |
| `PlatformStore` | In-app purchases (StoreKit 2, or Play Billing): products, entitlements, restores, promoted purchases |
| `PlatformGameCenter` | Sign-in, achievements and leaderboards that catch up from saved progress (GameKit, or Play Games) |
| `PlatformSync` | Saved data synced across a player's devices (iCloud's key-value store, or Play's Saved Games), with sets that merge instead of overwrite |
| `PlatformInput` | Focus for the Apple TV remote, gamepads and the Mac's pointer; a pressable control base that follows a tap and takes focus; keyboard and Menu handling |
| `PlatformDisplay` | Frame-rate and graphics settings, with an Auto mode that picks a render scale for the device |
| `PlatformDevice` | Haptics, rating prompts at the right moment, play time |
| `PlatformShare` | The share sheet, pasteboard, the App Store review page, feedback mail |
| `PlatformRigs` | Spine 4.2 skeletons posed and drawn in SpriteKit (Spine Runtimes License, see below) |
| `Macros` | `@NSCodingUnsupported` for node subclasses (`inherit:` for pass-through inits); `@LocalizedStrings` for the type-safe strings layer; `@LaunchArgument` for debug switches; `@Stored`, `@Synced` and `@SyncedKeys` for saved values; `@DecodableDefaults` for `Codable` types with defaults |

"Shared platform code" below describes each one in detail.

## Getting started

### Try the Android runtime

You'll need a Mac (the host tests compare against Apple's frameworks) and:

- Swift 6.4.2 from [swift.org](https://www.swift.org/install/) via
  `swiftly` (Xcode's Swift can't cross-compile for Android), and the
  `swift-6.4.2-RELEASE_android` SDK;
- Android NDK r30 at `$ANDROID_NDK_HOME`, JDK 17, cmake and ninja.

```bash
git clone https://github.com/fleon/spritekit-android.git
cd spritekit-android
swift test                                  # host tests: no device needed
Vendor/build.sh android                     # FreeType and HarfBuzz for Android
Scripts/check-android.sh arm64-v8a          # cross-compiles the runtime
```

### Bring your game to Android

1. Add this repository as a submodule at `<game>/Android/spritekit-android`.
2. Copy `Templates/App/base` to `<game>/Android/App` and fill in its
   placeholders (`Templates/App/README.md` walks through them).
3. Make a Swift package at `<game>/Android/Game` that links your game's
   `Source/` folder, adds a controller adopting `GameHost`, and exports
   `SDL_main`.
4. Build SDL and your game's shell library, then the app:

   ```bash
   Scripts/build-sdl.sh arm64-v8a
   Scripts/build-shell.sh --debug arm64-v8a
   (cd ../App && ./gradlew installDebug)
   ```

"Using it in a game" below has each step in detail, and "How it works"
explains the runtime itself.

### Use just the toolkit in an Apple game

1. Add this repository to your game as a git submodule, for example at
   `Android/spritekit-android` (the path the runtime expects, so it's
   ready if you port later).
2. In Xcode, add `<submodule>/Platform` as a local package (File → Add
   Package Dependencies → Add Local…) and link the products you want to
   your app target.
3. `import PlatformCore` (or `PlatformStore`, `PlatformAudio`, …) where you
   use them, and delete your own copies of what they replace.

## Getting help and contributing

- **Found a bug or a missing API?** Open an issue with the call involved
  and what you expected (for the runtime, what Apple does and what you see
  on Android). A small scene that shows it is the best report.
- **Writing the same helper in every game?** It may belong in the toolkit:
  open an issue describing it.
- **Want to fix it?** Pull requests are welcome; `CONTRIBUTING.md` has the
  few house rules (above all: match Apple's exact signatures and behaviour,
  and keep the runtime free of any one game's code).
- **Not sure where to start?** "What isn't here" lists SpriteKit features
  the runtime doesn't cover yet.

## License

MIT, in `LICENSE`, except `Platform/Sources/PlatformRigs`, a port of the
Spine Runtimes, which stays under the Spine Runtimes License (see
`LICENSE`). Dependencies fetched at build time (SDL, FreeType, HarfBuzz)
keep their own licenses, and the test fonts carry theirs beside them.

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
                     synced saved data stand on, the sync engine's merge,
                     the render scale governor and `ObserverBag`.
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
                     CoreVideo, CryptoKit, Network, os, Security, simd), each
                     re-exporting the shim, so a game's imports resolve.
Shell/               Android-only. The app shell: SDL3, the EGL context, the
                     frame loop and its pacing, input, audio, the GL backend
                     and `GameHost`, the seam a game's controller adopts.
Platform/            The platform code games share, on Apple platforms and
                     Android alike: `Macros` (`@NSCodingUnsupported`),
                     `PlatformCore` (geometry shorthands, timing curves and
                     eased actions, seeded randomness, the launch-argument
                     reader), `PlatformAudio` (sound effects and the
                     soundtrack), `PlatformSprite` (the texture cache and
                     sprite helpers, colours, text and fonts, SVG paths and
                     icons, shape sprites, scene loading, localization,
                     debug markers), `PlatformDevice` (haptics, rating
                     prompts, play time), `PlatformSync` (synced saved
                     data), `PlatformAndroid` (Android's Play and device
                     wiring), `PlatformAndroidHost` (what a game's Android
                     controller stands on), `PlatformInput` (focus for the remote,
                     gamepads and the pointer; keyboard and Menu protocols),
                     `PlatformDisplay` (frame-rate and graphics settings
                     with Auto), `PlatformGameCenter` (sign-in,
                     achievements, leaderboards, Play Games' mark),
                     `PlatformStore` (in-app purchases), `PlatformShare`
                     (share sheet, pasteboard, review page, feedback mail)
                     and `PlatformRigs` (Spine 4.2 skeletons, posed and
                     drawn). See "Shared platform code".
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
Templates/Game/      The game's Swift package for Android: its
                     `Package.swift`, its entry and a controller over
                     `AndroidGameHost` (Templates/Game/README.md).
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

Where the service is Play Games, a game's Game Center button wears Google
Play Games' mark in its own greens (`PlayGamesMark`: the path data and
colours, and `node(size:manager:isButton:)` drawing it on the button's
centre). Where Play Games can't run (no Google Play services, a build
without it) the button hides itself (`hidesButton(for:)`); Game Center's
button on Apple is never hidden by it. Where the service is Game Center, it
wears Game Center's four bubbles (`GameCenterMark`: their geometry and
gradients, `draw(in:rect:)`, and `texture(size:)` and `node(size:)` drawn
once a size into `DrawnTexture`'s cache). Both marks stand on a 24-unit grid
centred on the button, so `GameServiceMark.node(size:manager:isButton:)`
gives the platform's own with no platform check in the game. Each game keeps
its own button.

### Sharing (`PlatformShare`)

`ShareSheet.present(_:from:)` opens the system's share sheet with strings,
web links and files, from a node: `UIActivityViewController` on Apple
platforms, as a popover pointed at the node (its `RestingBounds`) on iPad
and the Mac; on Android the items are sorted into a `ShareRequest` for the
shell's `SystemShare.sheet`, an App Store link becoming the game's Google
Play page in `storePageLanguage()`. `copy(_:)` puts text on the pasteboard,
`didPresent` is told each time a sheet opens (a recording's marker).
`StoreReviewPage.open(appStoreID:language:)` opens the App Store's
write-a-review page, or the game's Play page on Android;
`FeedbackMail.compose(to:subject:body:over:)` writes a mail in
`MFMailComposeViewController` where mail is set up, else through its
`mailto:` link. Links leave the game through `SystemLinks.open`. Apple TV has
no sheet, pasteboard, review page or mail. Every address, ID and word is the
game's own.

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

### Sprites, text and scenes (`PlatformSprite`)

The SpriteKit infrastructure with no game in it. What each game's content
decides, it hands in:

- **Sprites** (`txtr`, `sprite`, `tinted`, `sliced`, `textures(in:)`,
  `forgetTextures(where:)`, `restingFrame(in:)`): a texture cache safe on
  any thread. `SpriteArt.capInsets` gives `sliced` its caps (a generated
  slice table), `SpriteArt.scale` sizes art drawn at a scale of its own,
  and `SpriteArt.whenForgetting` hooks a game's own caches of assets'
  textures (lit shaders' normal maps) onto `forgetTextures`.
- **Nodes and actions** (in `PlatformCore`): `addChild(_:z:at:)` sets a
  node's z-position (and position) as it adds it, and returns it.
  `run(_:withKey:)`, `action(forKey:)`, `removeAction(forKey:)` and
  `hasAction(forKey:)` take an owner's `enum ActionKey: String`, whose raw
  values are the keys (`case pulse = "logo.pulse"`: a prefix still keeps
  two owners apart on one node), at no cost over a string.
  `xConstraint`/`yConstraint` hold a node's x or y.
- **Observers** (`ObserverBag`, in `PlatformServices`, which `PlatformCore`
  re-exports): `observers.observe(name, object:, queue:) { … }` adds a
  block observer and keeps its token; the bag removes them all on
  `removeAll()` or when it goes, so an owner keeps one as a property and
  writes no `deinit`. Foundation's `NotificationCenter` on every platform.
- **Builders**: `path(.moveTo(…), .lineTo(…), .roundedRect(…), …)` makes a
  `CGPath` for `ShapeSprite`, a crop mask or a route (`ArcDirection` as
  UIKit names it: `.clockwise` is a rising angle); `label(.font(weight,
  size), .text(…), …)` makes an `SKLabelNode` in `Typography`'s face, or a
  named one (`.fontNamed`). `rectInScene(for:scene:)` is what a node draws,
  in the scene's space, and holds through rotation (`boundingRect(_:in:)`).
- **Colours** (`hex`, `rgb`, `rgba`, `UIColor(hex:)` from a number or a
  string, `withOpacity`, `blended`, `brightness`, `toVec3`, `cacheKey`).
- **Text** (`wrappedLines`, CoreText's breaks on both platforms;
  `capitalsOffset`, `centerCapitals`, `TextBlockNode`): `Typography` holds
  the game's font and line height, and `Typography.follow(_:base:)` sets
  them by the current language (`ScriptedLanguage`: a script's own face and
  line height). `FontRegistry.register(fontFiles:)` registers the game's
  font files once each.
- **Icons** (`SVGPath`, `IconDrawing`, `IconPart`): a game's enum of icons
  lists each one's path data, stroked or filled, on a grid; `node(size:color:)`
  draws it once a size into `DrawnTexture`'s cache and tints it.
  `ShapeSprite` draws rings, pills, discs and outlines the same way, never
  as shape nodes.
- **Loading spinner** (`LoadingSpinner`): an arc of a ring that reaches all
  the way round and back every period while it turns, its ends round, in
  any colour (`color`, which can change while it shows) at the game's
  `radius` and `thickness`. A shader draws it on one sprite, so it builds
  no path or texture per frame and looks alike on Apple and Android.
  `LoadingSpinnerSweep` is its curve alone.
- **Scenes** (`LoadableScene`, `TransitionManager.show`/`present`,
  `offMainActor`, `BuildGate`): `TransitionManager.sceneSize`, `scaleMode`
  and `duration` are the game's, and `present` takes the game's loading
  scene. `SceneLayout` is the safe area, the display's rounded corners
  (`DisplayCorners`), a camera's occlusion (iOS 27.1's `reservedRegions`)
  and where round buttons stand in the corners or a rail, by the game's
  `SceneLayout.Metrics`.
- **Launch splash** (`StudioSplashScene`): a studio's logo over a footer
  line or two, held at least a minimum time and until the game reports
  what it waits for `ready` (a game service's first answer, a feed), never
  past a maximum, then `onReady`; `present(_:in:)` crossfades into the
  game's first scene. The logo's asset, the footer's text and font, the
  colours and the timings are the game's (`StudioSplashScene.Style`), so
  nothing here names a studio. Its sizes are for an iPhone 16 Pro (393 ×
  852 points, turned for landscape) and scale to fit the view, so the
  splash keeps its proportions on a phone, a tablet, a window, a TV and
  Android. `StudioSplashGate` is its timing alone.
  `StudioSplashScene.launch(in:style:waitingFor:firstScene:)`
  (`StudioSplashLaunch`) is the whole launch, the same from an iOS view
  controller and an Android controller: it presents the splash on the
  view's first real size, fits it in `layout(_:)` (true while it holds the
  view) and starts its clock in `start()`. Its waits are named conditions
  run as the view appears (`.until` an async call returns, `.callback`,
  `.reported` by the game through `ready(_:)`, and `PlatformGameCenter`'s
  `.gameCenter(manager)`, the sign-in's first answer), every one bounded by
  the style's `maximumDuration`. The first scene is `.built` behind the
  splash, made `.whenReady`, or the game's own `.handOff`;
  `preloadsLogo` holds the splash until its logo's texture is in.
  `StudioSplashLaunchSteps` is its order alone.
- **Localization** (`Localizer`): the player's pick, else the device's
  language among the game's (`LocalizationLanguage`), its strings read from
  the bundle's `.lproj` with a content table keyed by its text; on Android
  from the APK's `lproj/`, through the shim's `.strings` parser, so the
  player's pick holds there too.
- **The strings layer** (`@LocalizedStrings` and `@L`, in `Macros`): an
  enum whose cases each carry their key, English fallback and translator
  comment (`@L("levels.completed", "%d of %d", comment: "…") case
  completed(Int, Int)`) gets `key`, `fallback`, `comment` and `localized`,
  one switch apiece. `localized` is `NSLocalizedString` (with a `table:`
  and `bundle:`), or the enum's own `lookup` (`lookup: .custom`, for a
  `Localizer`), then `String(format:)` or `localizedStringWithFormat`
  (`formatting:`, per enum or per case) with the associated values in
  order. A key built at run time is `@L(.custom)`, read from the enum's
  `customKey` and `customFallback`; `formatting: .custom` hands the looked-up
  string to its `customLocalized(_:)`. The compiler flags a case without
  `@L`, a fallback whose placeholders don't match the associated values, and
  a key used twice; generated members carry the enum's `nonisolated`.
- **Debugging** (`Markers`, `FrameLog`; `LaunchArgumentReader` in
  `PlatformCore`): the arguments are the game's; the reader answers fixed
  values in a release build. `@LaunchArgument("Key")` (`Macros`) writes a
  `var`'s getter as one read: the declared type picks the method (`Bool`,
  `String?`, `Int?`, `Double?`, `CGFloat?`, `CGSize?`, `[String]?`,
  `[Double]?`, a `String`-backed enum), `as:` another (`.fraction`), and
  `unset:`, `release:` and `separator:` pass through; a non-optional reads
  as its zero when the key isn't given. It reads the enclosing type's static
  `reader`, or the expression `reader:` names, and diagnoses a type it can't
  read, which keeps a hand-written getter.
### Haptics, ratings and play time (`PlatformDevice`)

`HapticsManager` plays UIKit's kinds of feedback (`lightImpact()`,
`mediumImpact()`, `softImpact()`, `selectionChanged()`, `success()`,
`warning()`, `error()`, …) where the device has haptics and the player
hasn't turned them off: an iPhone's generators (prepared again after each
use), an Android device's vibrator wherever it has one (`VibrationSupport`,
`-Vibrator NO` in a debug build), never Apple TV or an iPad. The switch
(`isHapticsEnabled`, on by default) is kept in `storage` under `settingKey`
(`settings.hapticsEnabled`); a game that syncs its settings hands in a
`ValueStorage` that saves through its sync manager and lists
`HapticsManager.syncedKeys`.

`ReviewPrompt` is one rule for asking for a rating (`.milestones` reached,
`.playTime` past a minimum, or `.once` when a condition first holds) and
the record of what it asked, in a `ValueStorage` under its key: the
milestones asked at as `[Int]`, `true` once a one-off asked, and a snooze's
end as `<key>.snoozedUntil`. `requestIfDue()` asks the store (the App
Store through the foreground window scene; Play In-App Review on Android)
and records it; a game with its own "enjoying the game?" flow reads
`isDue` and calls `markRequested()` or `snooze(for:)`.

`AppUsageTracker` counts play time on every device: each device adds its
own seconds under `<keyPrefix><device id>` while the game is in front, and
the total sums every device's, so syncing the prefix (`.latest`) loses
nothing.

### Synced saved data (`PlatformSync`)

`ICloudSyncManager` keeps saved data the same on the player's devices over
`SyncEngine`: user defaults stay the store here, `set` saves a value where
the latest change wins (nil removes it), `insert` and `resetSet` keep a set
every device adds to, and the keys another device changed are posted as
`didUpdateLocalData`. `start(syncing:prefixes:)` names what syncs: each
owner's `syncedKeys`, and prefixes for keys made as play goes on. The
cloud is `ICloudKeyValueStore` on Apple platforms (over
`NSUbiquitousKeyValueStore`, one record a key, or `.flat`: values under
their keys and times beside them, as games kept them before records), Play
Games Saved Games on Android once the wiring hands it in, or
`LocalOnlyCloud`, which keeps everything on the device (a test run kept
off iCloud). `Configuration` names where each key's time is kept
(`sync.<key>`, or an older build's layout, read alongside). Set
`ICloudSyncManager.configuration` and `cloud` before `start`: a game whose
iCloud data is flat that started on the default `.records` cloud would
replace its values with records its earlier builds can't read.

### Android's wiring (`PlatformAndroid`)

`AndroidPlatformServices.install(_:)` puts a game's managers on Google Play
and the device, once, before its launch work starts them. It makes each
backend the configuration asks for and hands it to the receiver the game
names: Play Games' achievements to its Game Center manager, the
leaderboards to `GKLeaderboard.backend`, the signed-in player to
`GKLocalPlayer.local`, Saved Games to its sync manager (flushed as the game
leaves the front, synchronized as it comes back), Play Billing or simulated
purchases to its store. Play Games needs the mapping packed in the APK
(`PlayGamesMapping.bundled()`); without it achievements and saved data stay
on the device. It also sets the device's hooks (haptics, battery saver as
Low Power Mode, audio focus, and on request the status bar, battery,
connection and image codecs). Its sources are all `SPRITEKIT_SHIM`, so Apple
builds compile it empty.

`PlatformAndroidHost` is what a game's controller stands on, likewise
Android's alone. `GameHostSurface` owns the view, the window, its window
scene (kept: the window's reference is weak) and the screen, and copies each
layout into them, the idiom and `DisplaySettings.screenMaximum`, with
`-SafeAreaInsets` in a debug build; its `launch` (a `StudioSplashLaunch`)
holds the view until the first scene. `AndroidGameHost` answers the
`GameHost` members every game answers alike from the surface (layout, the
scene sized to `sceneSize(for:)` then `didLayout(_:)`, `didAppear`,
`captureFrame`, `debugSummary`), `AudioManager.shared` (`useAudio`),
`-FixedFrameStep` in a debug build, and `DisplaySettingsHost`; Back, keys
and links go untaken until the game writes its own.
`AndroidPlatformServices.Configuration.toolkit(gameCenter:syncsSavedData:store:audio:)`
hands the toolkit's managers their Play backends (achievements and
leaderboards, Saved Games under `ICloudSyncManager`, Play Billing for the
store's products, audio focus), and `DisplaySettings.Configuration
.withLaunchSplash` keeps Auto from measuring the splash and reads
`-RenderScale`.
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

`PressableNode` is the base for a game's buttons, switches and tiles. It
follows one touch from down to up (pressed while the finger is on its
`hitFrame`, grown by `touchSlop`; let go while it strays off; firing as it
lifts on it, or as it lands with `trigger = .touchDown`), ignores a second
finger, drops a cancelled touch, takes no press or focus while disabled
(still swallowing its touches), and is `Focusable`: the remote's click, a
gamepad's A or a key fire it through `activate`, with the press flashed.
Its look is the subclass's: by default a press shrinks `pressScaleNode`, a
disabled control fades and focus fades `focusRing`, and `showPressed`,
`showEnabled` and `showFocused` replace those. Firing runs `onTap`, or a
subclass's `perform(_:)` (a switch flips there; `PressSource` says where a
touch let go); sounds and haptics go in `playFeedback`, or once for every
control in `PressableNode.feedback`. Defaults are `PressConfiguration`'s.
A control that can't subclass it (a sprite, or one a game hands touches its
own way) holds a `PressTracker`, the same state machine, or calls
`pressBegan(at:)`, `pressMoved(to:)` and `pressEnded(at:)` itself.

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

### Spine rigs (`PlatformRigs`)

A port of spine-core 4.2's runtime, played and drawn in SpriteKit. Use of
the Spine Runtimes is subject to the Spine Runtimes License: a game that
ships it needs a Spine license.

- `RigData` reads a skeleton Spine 4.2 exported as JSON, its images packed
  into one texture whose places a top-level `atlas` table gives (`[x, y,
  width, height]` in pixels, y down, by image name). It reads bones in every
  inherit mode, shear, slot colours, the default skin's regions, meshes
  (weighted or not), clips and paths, IK, transform, path and physics
  constraints, and bone, colour, two-colour (its light colour), attachment
  and deform keys; a JSON's other top-level fields are kept in `extras`.
  `RigData.named(_:)` reads a rig once and keeps it; by default it reads
  `Rig<name>.json` and `.png` from the bundle, and a game that packs rigs
  its own way sets `RigData.loader`.
- `RigPose` is AnimationState and Skeleton: tracks played, queued and
  cleared (`setAnimation`, `addAnimation(delay:)`, `clearTrack`), crossfades
  (`defaultMix`, `setMix(from:to:duration:)`, an entry's `mixDuration`),
  listeners (`onStart`, `onInterrupt`, `onEnd`, `onComplete`), `timeScale`,
  `skeletonColor`, and `play(_:loop:rate:from:until:then:rise:mix:track:)`,
  which plays at a rate (backwards down to `until`), from a time, then hands
  over to another animation, and scales how high `riseBone` lifts. `origin`
  is where the skeleton stands: physics trails behind as it moves, and every
  position read back (`boneTransform`, `worldVertices`) is relative to it,
  with weighted vertices taken relative to it before weighting.
- `RigNode` plays one: each mesh, and each region as its quad, draws as its
  own triangles (`RigMeshNode`), tinted, in slot order; clips mask what they
  hold. It ticks itself, trails physics behind its moves through the scene
  (`feelsMoves`), holds still while hidden, carries nodes on bones
  (`carry(_:on:)`), and caches its parts as one texture while it stands
  still (`caching:`, or a subclass's `mayCache`). Subclass it for what a
  game draws on a rig (`didRender()`).
- `RigMeshNode`: on Apple platforms, sprites whose shader tests each pixel
  against a few triangles; on the shim, one sprite carrying its triangles
  (`SKTriangleMesh`). A game shades meshes its own way (a light, a normal
  map) with `RigMeshNode.Shading`: GLSL run on each texel and on the
  result, with its uniforms. Shaders with attributes are primed before they
  draw (`AttributeShaders`, `RigMeshNode.primePending`, `primingGate`,
  `forgetShaders(where:)`); `ShaderPrimer` primes a screen's other shaders a
  few a frame.

```swift
// At launch, for rigs packed as a deflated skeleton plus a places JSON
RigData.loader = { name in MyRigs.read(name) }   // returns RigData(json:textureURL:)
// A rig
let rig = RigNode(name: "Hero", unit: 0.5, slotZ: 0.001)
rig?.pose.defaultMix = 0.15
rig?.pose.riseBone = rig?.data.bone(named: "move")
rig?.play("jump", loop: false, then: "idle", rise: 40)
```

`Platform/Tools/Rig/verify-pose.js` checks the runtime against spine-core
4.2, frame by frame: it plays every animation of a folder of rigs (looping,
crossfading, travelling) and any schedules given through `RigPose` and
spine-core alike, and prints the largest differences in bone transforms,
vertices and colours, and any attachments and listener events that differ
(`node Platform/Tools/Rig/verify-pose.js --rigs <dir> --spine-core <dir of
@esotericsoftware/spine-core>`). The tests' synthetic skeleton
(`Tests/PlatformRigsTests/Fixtures/RigTest.json`) uses every feature, and its
frames as spine-core posed them are checked in the tests.

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
  controller) and the managers that reach Apple's services. Link whole
  folders, not files one by one, so a file the Apple build adds compiles on
  Android too rather than going missing: what a folder leaves out goes in the
  target's `exclude:` (or an Apple-only subfolder), and a file is linked on
  its own only where its folder can't be.
- **A controller** adopting `GameHost`: the Android counterpart of the game's
  view controller and app delegate (launch work in the Apple order, the
  first scene, layout, Back, keys, links). Over `AndroidGameHost` it writes
  only what's the game's own.
- **The managers' bodies**: the game's audio, store, Game Center, iCloud and
  haptics managers, their public API kept name for name, over
  `PlatformShim`'s backends.
- **An entry target** that exports `SDL_main` and calls `Shell.start`, and a
  dynamic library product named `AndroidShell` (the library SDL loads).
  `Templates/Game` has all three to copy:

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
extension MyGameController: GameHost {}  // and AndroidGameHost, in its own file
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

Back that a game doesn't take (`handleBack()` answering false) sends it to
the background, as Back from any app does. A game that closes itself (Back
pressed again on its title) calls `Shell.finishActivity()`, Android's
`Activity.finish()`, which Apple has no equivalent of.

### Scripts

The scripts find the game from the runtime's parent directory, or from
`GAME_ANDROID_DIR`, `GAME_PACKAGE_DIR` (default `Game/`) and `APP_DIR`
(default `App/`), in `Scripts/config.sh`.

```bash
Vendor/build.sh android                     # FreeType + HarfBuzz, both ABIs
Scripts/build-sdl.sh arm64-v8a              # SDL 3.4.20, staged into the game's App
Scripts/build-shell.sh --debug arm64-v8a    # the game's AndroidShell library, staged
Scripts/check-android.sh arm64-v8a          # this runtime alone, cross-compiled
Scripts/art.sh                              # the game's asset catalogs, packed (below)
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
  its pixels until what Apple's SpriteKit redraws for changes: the subtree
  (a digest of transforms and textures), the node's own transform, alpha or
  shader, a write to `shouldRasterize`, or any write to a uniform its shaders
  or its subtree's use (the same value too). `u_time` running on, attribute
  values and ancestors moving keep the pixels. A layer cached in bands gives
  each band its own copies of the uniforms that change, written only on the
  frame that band redraws.
- **Batching:** one vertex and one index stream a frame, written through one
  synchronised map of a freshly orphaned buffer (Adreno drivers let
  unsynchronised writes land over draws still pending).
- **Meshes:** `SKTriangleMesh` and warped sprites batch as geometry with the
  sprites of their texture.
- **Shapes** are triangles (`ShapeTessellator`), as a game engine's draw
  node makes them (axmol's `DrawNode`, MIT): tessellated once in the node's
  own space, cached by what they draw and the density they're drawn at, and
  batched with the colour sprites either side, so a shape that moves, turns
  or fades costs no rasterising and no draw call of its own. Edges are
  SpriteKit's, measured in an `SKView` on the iPhone 17 Pro (3x) and iPad
  Air (2x) simulators: a fill isn't antialiased (a pixel is in when its
  centre is), and a stroke is softened over about 1.7 of the screen's
  pixels at any density, narrower than CoreGraphics', twice as soft in a
  node scaled 2x (`SpriteKitShapeEdgesTests`). A windowless `SKRenderer`
  on a Mac draws strokes softer than any device does: measure on one. Strokes take
  CoreGraphics' joins and caps; a path that changes is tessellated again on
  the frame thread in microseconds. The tessellator can also feather edges
  across a device pixel, held to the masks pixel by pixel
  (`ShapeTessellatorTests`).
- **Shapes it can't take** (a textured fill or stroke, a fill that crosses
  itself or holds another subpath, a crop's mask) are rasterised on the CPU
  into coverage masks with the same edges (`SpriteKitMasks`: a fill sampled
  at pixel centres, a stroke's triangles sampled), cached by what they draw. One whose path changes
  every frame draws its last mask while the next is made on a thread of the
  lowest priority (`MaskLag`), a frame or two behind; one appearing gets
  its mask at once, and a fixed frame step makes every mask at once. The
  frame report logs what masks and meshes have cost.
- **Render scale:** fill rate decides frame time on mid-range GPUs, so the
  scene can draw at a share of the screen's size, the display scaling it up
  (`ANativeWindow_setBuffersGeometry`). `RenderScaleGovernor` picks the scale
  by wall-clock frame times; a game's settings can fix it.
- **Pacing:** frames start on the display's vsync (AChoreographer), so every
  step moves the scene a whole number of refreshes.
- **Programs** are kept as driver binaries between launches, keyed by source
  and driver, so an app update doesn't relink what didn't change.
- **Shape masks** are rasterised at the density
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
texture reports its art's size in points and `textureRect()` is its slice of
the page. Pages are ASTC with mip levels where the GPU samples ASTC
(`GL_KHR_texture_compression_astc_ldr`), else decoded on the CPU
(`ASTCDecoder`) and uploaded as RGBA8; decoding there takes seconds a page
on an emulator, so the frame on screen draws without a page still decoding
rather than wait (a snapshot or film waits). Images over 512 px take a page of
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

#### Packing a game's art

A game packs its art with `Scripts/art.sh` (`Tools/Art/pack.js`), through
its own `Android/Scripts/art.sh`, which runs it with the game's settings
from `runtime.sh`, as the other scripts do:

```bash
#!/bin/bash
# SpriteKit for Android's Scripts/art.sh, with the game's paths (runtime.sh).
. "$(dirname "$0")/runtime.sh"
exec "$RUNTIME_DIR/Scripts/art.sh" "$@"
```

It builds the ASTC encoder if the checkout has none, then runs the packer
under `Tools/guard.js 12` on the game's catalogs. The settings are paths
from the game's root:

| Variable | What it says |
|---|---|
| `SKA_ART_CATALOGS` | The catalogs, space-separated, in order (default `Assets/Assets.xcassets`). |
| `SKA_ART_OUT` | Where the pack goes (default `Android/Assets`). |
| `SKA_ART_PNG` | `1` for PNG pages, which need no encoder (default ASTC). |
| `SKA_ART_CACHE` | A cache directory, as `--cache`. |

```
Android/Scripts/art.sh                       # the game's pack, as it ships
Android/Scripts/art.sh --png                 # PNG pages, quicker, for a look
Android/Scripts/art.sh --out <dir>           # somewhere else
Android/Scripts/art.sh --cache <dir>         # copied from <dir> when nothing changed
```

With a cache, each pack is kept under a hash of everything it is made from:
every file in each catalog (by its place in the list and its path inside
it, so the same catalogs in another worktree hash alike), the page format,
the packer, the compressor and the encoder's pinned release. A run whose
hash is there copies that pack instead of encoding again; the three most
recently used are kept. Steps that write into a catalog first (sprite
sheets, rigs, generated images) stay the game's, and run before it.
`node --test Tools/Art/pack.test.js` checks it.

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

#### Font descriptors

`UIFontDescriptor` and `UIFont(descriptor:size:)` resolve against the font
catalog's faces (`TextMetrics.catalog`: each registered face's FreeType
family name, style, weight and slant) as Core Text does, pinned by
`FontDescriptorParityTests` against Core Text on the same files, Montserrat
and KoHo (Core Text's answers there are UIKit's, measured on Mac Catalyst):

- A family's faces are its files' family name, whatever their PostScript
  names; `.name` wins outright, in any case.
- `.face` (a style) wins over the traits, a `wght` variation over the style.
- A weight trait, or the bold bit's 0.4, takes the face whose Core Text
  weight trait is nearest. Core Text gives a face a trait from its weight
  class (an instance's `wght`, else OS/2's: 100 −0.6, 200 −0.4, 300 −0.23,
  400 0, 500 0.2, 600 0.3, 700 0.4, 800 0.6, 900 0.8, straight between),
  kept as a `Float`. On Montserrat, `.ultraLight` and `.thin` are Thin,
  `.light` ExtraLight, `.heavy` and `.black` ExtraBold.
- `withSymbolicTraits(_:)` gives the face with exactly those traits: a family
  with `.traitBold` is Bold; a named instance Thin to Medium becomes Bold,
  SemiBold and up stay; `.traitItalic` with no italic face is nil for the
  family, and from another instance goes to Regular's `wght`, as Core Text's
  does.
  `symbolicTraits` is the face's bold (weight trait 0.3 and over) and italic.

The text stack draws named instances only, so a `wght` between them takes
the nearest, where Core Text draws the weight between. A font's widths
aren't known, so `.traitCondensed` and `.traitExpanded` find no face. With
no family or name, or one the catalog lacks, the descriptor is the system
font (Helvetica on Apple). `withDesign(_:)` answers for the system font
only, as UIKit's does.

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
  background. As on Apple, launch arguments are an overlay on reads alone: a
  value set for a key an argument also names is saved, though reads return
  the argument's until the next launch, and the arguments are never saved
  (`SavedDefaults`). Corelibs' `setVolatileDomain` merges into a domain
  where Apple's replaces it, so code that changes the argument domain
  replaces it with `SavedDefaults.replaceArguments` (`SavedDefaultsTests`).
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
  that imports only Foundation needs the shim re-exported in its module. A
  game that picks its own language reads that folder's tables with
  `LocalizedStrings.table(atPath:)`, as `PlatformSprite`'s `Localizer` does.
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

## Devices

`Scripts/device-lock.sh` shares the machine's physical test devices between
sessions, worktrees and games, one run at a time:

```bash
Scripts/device-lock.sh run <device> <session> [--wait] -- <command...>
Scripts/device-lock.sh status
```

`run` takes the device (or waits for it with `--wait`), renews the lock while
the command runs, and releases it when the command ends; when the device is
busy it exits 1 without running anything. `acquire`, `wait`, `renew` and
`release` hold a device by hand. A lock not renewed for 30 minutes is stale.
The machine lists its devices (`SKA_DEVICES`) and where the locks live
(`SKA_DEVICE_LOCKS`) in `~/.config/spritekit-android/devices.env`, which is
also the place for what a session needs to reach each one: device IDs,
addresses and adb servers stay on the machine, never in a repository.
[`Docs/Testing.md`](Docs/Testing.md) has the recipes for testing on devices,
simulators and emulators.

## Memory guard

`Tools/guard.js` runs a command and kills it, with everything it started, once
their resident memory together passes a limit in GB, so a runaway script can't
take the machine down (Node's own heap limit misses typed arrays and native
libraries). It prints the peak, and exits with the command's code, 137 when it
killed it, 2 on a bad command line and 127 when the command can't start.

```bash
node Tools/guard.js 12 -- <command> [args...]
node --test Tools/guard.test.js
```

A game keeps a shim at its own `Tools/guard.js`, so `node Tools/guard.js …` in
its scripts and docs runs this one. The shim requires
`../Android/spritekit-android/Tools/guard.js`, and when the submodule isn't
checked out (a fresh worktree) it says so and exits 2 rather than run the
command unguarded.

## Google Play

`Tools/Play/play.js` is every game's Google Play tool: the store listing,
images, managed product, Data Safety and releases, the nightly testing build
among them (to internal testing, copied to closed testing and sent for
review). Each game runs it through a two-line `play.js` in its own Play
directory, beside its `listing.json` and `play.json`;
[`Tools/Play/README.md`](Tools/Play/README.md) has the layout, the steps and
the rules it keeps.

## Strings

`Tools/Strings/strings.js` is every game's strings tool: it checks that each
language's `.strings` tables have the base's keys, order and placeholders and
that the type-safe strings layer names only keys the base has, exports
strings for translators (JSON, CSV or XLIFF) and imports their work back,
lays translations out as the base, and builds tables from JSON. Each game
runs it through a two-line `Tools/Strings/strings.js` beside its
`strings.json`; [`Tools/Strings/README.md`](Tools/Strings/README.md) has the
settings and commands.

## Prices

`Tools/Pricing/` prices every game's app or in-app purchases by purchasing
power: `ppp.py` turns World Bank price levels and live exchange rates into a
target per storefront, `appstore.py` plans (and with `--send` sets) the App
Store schedule at the nearest price points, `play.py` prices each Google Play
region as the App Store prices it, and `product.js` creates the one-time
product on Play. A game runs each through a two-line shim beside its
`pricing.json`; [`Tools/Pricing/README.md`](Tools/Pricing/README.md) has the
settings and the rules it keeps.

## Game Center definitions

`Tools/GameCenter/gamecenter.js` keeps a game's Game Center achievements and
leaderboards in App Store Connect in step with a definitions file in the
game's repository, through `asc`: it prints a plan, and creates or corrects
only with `--send`. `Tools/GameCenter/generate-art.js` paints the achievement
images with Codex. A game runs each through a two-line script in its own Game
Center directory, beside its `achievements.json`;
[`Tools/GameCenter/README.md`](Tools/GameCenter/README.md) has the layout and
the rules it keeps. A game that keeps its achievements only in App Store
Connect needs neither.

## Screen captures

`Tools/Capture` films games for their store pages. `capture.js` shoots a
game's screens on an emulator or a simulator, in every language, from the
game's `capture.json` and its own hooks (a patch script that wires launch
arguments into a scratch copy, never the repository), checks a set against
Play's and the App Store's rules and draws contact sheets. `apple.js` is the
simulator, Mac and session plumbing a game's own recording tools bind to it
(previews, trailers, laid-out screenshots), with `mac-record.swift` for the
Mac app's window, and `parity-pair.sh` compares one state on an emulator and
a simulator. Games run them through shims at their old paths;
[`Tools/Capture/README.md`](Tools/Capture/README.md) has the settings and
commands.

## Releases

`Tools/Release/` holds every game's nightly release and its build number.
`nightly.js` ships one build, when PRs were merged since the last, with one
build number to TestFlight and to Play's internal and closed testing (through
`Tools/Play/play.js`); `version.js` works out that number, one past the
highest the project, App Store Connect and Play have taken, and bumps the
version once it has an approved release. Each game runs them through small
shims with its settings in `Tools/Release/release.json`;
[`Tools/Release/README.md`](Tools/Release/README.md) has the settings, the
steps and the rules.

## Signing

Keystores live in 1Password, never in a repository or a loose file. Each is
one item in the `Game Signing` vault (`SIGNING_VAULT` names another): the
keystore file (`keystore`), its password (`password`), alias (`alias`) and
certificate SHA-1 (`sha1`, what Google's consoles ask for).
`Scripts/signing.sh` reads and writes them through the 1Password CLI, which
signs in through the 1Password app (Settings → Developer → Integrate with
1Password CLI). So that builds never stop for Touch ID, reads go through a
service account that can only read that vault, when there is one: its token
in `OP_SERVICE_ACCOUNT_TOKEN`, or in the macOS Keychain under the service
`op-service-account-game-signing` (`SIGNING_TOKEN_SERVICE` names another).
`store` always signs in through the app, as it writes:

```bash
Scripts/signing.sh store "<Game> Android Upload Key" upload.jks   # password from SIGNING_PASSWORD, or asked
Scripts/signing.sh sha1 "<Game> Android Upload Key"
Scripts/signing.sh fetch "<Game> Android Upload Key" build/signing/upload.jks   # checks the SHA-1
Scripts/signing.sh debug   # ~/.android/debug.keystore from "Android Debug Keystore", only when missing
```

A game's `build.gradle.kts` (as `Templates/App` has it) fetches its key only
when a release build runs and deletes it when the build ends, failed or not
(a build service closing); a build killed before then leaves it for the next
non-release build to delete. Debug builds ask 1Password only when the shared
debug keystore is missing, so they don't stop for Touch ID:

```kotlin
val uploadItem = "<Game> Android Upload Key"
val signingScript = file("../../spritekit-android/Scripts/signing.sh").path
fun signing(vararg args: String): String =
    providers.exec { commandLine(signingScript, *args) }.standardOutput.asText.get().trim()
val signsRelease = gradle.startParameter.taskNames.any { "Release" in it }
val uploadKeystore = layout.buildDirectory.file("signing/upload.jks").get().asFile
if (!signsRelease) {
    uploadKeystore.delete()   // left by a release build that was killed
    signing("debug")
}

abstract class ForgetUploadKey : org.gradle.api.services.BuildService<ForgetUploadKey.Params>, AutoCloseable {
    interface Params : org.gradle.api.services.BuildServiceParameters {
        val key: RegularFileProperty
    }
    override fun close() {
        parameters.key.get().asFile.delete()
    }
}
if (signsRelease) {
    gradle.sharedServices.registerIfAbsent("forgetUploadKey", ForgetUploadKey::class) {
        parameters.key.set(uploadKeystore)
    }.get()
}

android {
    signingConfigs {
        if (signsRelease) create("upload") {
            signing("fetch", uploadItem, uploadKeystore.path)
            storeFile = uploadKeystore
            keyAlias = signing("alias", uploadItem)
            storePassword = signing("password", uploadItem)
            keyPassword = storePassword
        }
    }
    buildTypes { release { signingConfig = signingConfigs.findByName("upload") } }
}
```

## Contributing

See `CONTRIBUTING.md`.
