# The app template

The Android app a game ships: a Gradle project whose one activity extends
the runtime's `SpriteKitActivity` (SDL's activity, with the Java half of
every platform service the runtime talks to over its platform channel,
`Sources/PlatformShim/PlatformChannel.swift`). Everything above the GL
context is the game's Swift, in `libAndroidShell.so`.

The Java lives in the runtime, as Android library modules the game's Gradle
project builds in place from the submodule; the game keeps only its own app
module: its manifest and IDs, its resources, and what it adds (links, a
content provider, services of its own).

```
Library/                         the runtime's Android library (Gradle modules)
  spritekit/                     SpriteKitActivity, PlatformServices, device,
                                 Play Games, Play In-App Review, the share
                                 sheet's FileProvider; SDL's Java, compiled
                                 from Vendor/SDL
  spritekit-billing/             Play Billing
  spritekit-notifications/       local notifications (its own README)
Templates/App/
  base/                          the app every game starts from (copy it to
                                 <game>/Android/App)
```

## The library

Package `com.spritekit.platform` (and `.billing`, `.notifications`), every
class's name as the template's copies had it, so a game's Java that named
them changes only its imports.

| Module | Class | What it does |
| --- | --- | --- |
| `spritekit` | `SpriteKitActivity` | SDL's activity: launch arguments in debuggable builds, the environment the runtime reads (below), Back on Android 13 and later, the safe area as iOS gives it, links (`gameLink`, held until the shell can take them, a cold start's as `-LaunchLink`), the share sheet (`shareFile`), Paste over a text field (`offerPaste`), the platform channel's JNI |
| | `PlatformServices`, `PlatformService` | The channel's Java end: a registry of services by name, dispatching `service.method` calls and queueing events (`post`) |
| | `DeviceServices` | `device`: haptics, battery saver, audio focus, the status bar, the app's settings page (`openAppSettings`), the battery (`battery`), the connection (`connection`, with the app's `ACCESS_NETWORK_STATE`), JPEG and PNG re-encoding (`jpegToPng`, `pngToJpeg`) |
| | `AudioFocusPolicy` (+ its test) | When to ask for audio focus, as an ambient iOS session behaves |
| | `PlayGamesServices` (+ `ScorePagingTest`) | `games`: sign-in, achievements, leaderboards (submitting, loading them and their scores, showing them at a time span and collection), the player, Saved Games |
| | `PlayReview` | `review`: Play In-App Review, behind `SKStoreReviewController` |
| `spritekit-billing` | `PlayBilling` | `billing`: one-time products (prices, purchases, acknowledgement, restore) and consumables (`consume`, each purchase's `quantity`) |
| `spritekit-notifications` | `PlatformNotifications`, two receivers | `notifications`: `UNUserNotificationCenter`'s Java ([its README](../../Library/spritekit-notifications/README.md)) |

The `spritekit` module's manifest brings the share sheet's `FileProvider`
(authority `<applicationId>.files`, the cache) and Play Games' `APP_ID`; its
resources an empty `game_services_project_id`, and `spritekit-billing`'s an
empty `play_license_key`, which the app's build replaces with its own
(`resValue`). `spritekit-notifications`' manifest brings its permissions and
receivers, so only a game that depends on it has them; likewise Play
Billing's `BILLING` permission comes only with `spritekit-billing`.

On its own, the library builds and tests with its own wrapper:

```bash
cd Library
./gradlew :spritekit:assembleDebug :spritekit-billing:assembleDebug \
    :spritekit-notifications:assembleDebug :spritekit:testDebugUnitTest
```

It compiles SDL's Java from `Vendor/SDL`, which `Scripts/build-sdl.sh`
fetches; until then its build stops with the command to run. Included in a
game, it builds into the game's `build/spritekit/`, leaving the submodule
clean.

### What a game overrides

`MainActivity extends SpriteKitActivity` and overrides what it needs:

| Hook | Default | A game overrides it to |
| --- | --- | --- |
| `addServices(PlatformServices)` | nothing beyond `device`, `games`, `review` | add `PlayBilling`, `PlatformNotifications`, or a service of its own (`services.add(name, service)`, a `PlatformService`); a name already there is replaced |
| `gameLink(Intent)` | a `VIEW` intent's URI | read its links: map a web page's URL to its own scheme, or ignore what isn't its own |
| `shareUri(File)` | androidx's `FileProvider` at `<applicationId>.files` | hand the share sheet's file out through a provider of its own |
| `logTag()` | the app's label | log under another tag (`PlatformServices.tag()`) |
| `getLibraries()` | `SDL3`, `AndroidShell` | load another library first |

### What the Java side hands the runtime

`SpriteKitActivity.loadLibraries` sets these before the Swift libraries
load, and the shim reads them from the environment:

| Variable | Value | Read by |
| --- | --- | --- |
| `SKA_VERSION_NAME`, `SKA_VERSION_CODE` | The APK's `versionName` and `versionCode` | `Bundle.main.infoDictionary` |
| `SKA_DEVICE_MODEL` | Maker and model, "Google Pixel 9" | `AndroidDevice.current.model` |
| `SKA_OS_VERSION` | `Build.VERSION.RELEASE`, "17" | `AndroidDevice.current.osVersion` |
| `SKA_EMULATOR` | `1` on an emulator, else `0` | `AndroidDevice.current.isEmulator`, `LaunchDefaults.onEmulator` |
| `SKA_BETA` | `1` in a beta build (`-Pgame.beta`, through `build.json` in the assets), else `0` | `BetaBuild.current`, `LaunchDefaults.outsideBeta` |
| `SWIFT_DETERMINISTIC_HASHING` | `1` with `-FixedFrameStep` (debug builds) | Swift's `Dictionary` and `Set` |

And the shell calls these on the activity through JNI, by name, so they
keep their names and signatures:

| Method | Called from | Does |
| --- | --- | --- |
| `shareFile(String path, String mime, String text)` | `SystemShare.sheet` (`ska_share_file`) | `ACTION_SEND` through the chooser, the file as a `content://` URI (`shareUri`), `text` (may be null) as `EXTRA_TEXT` |
| `offerPaste(float x, float y)` | `TextInput.offerPaste` (`ska_offer_paste`), on a long press in a text field | A Paste button over that point (view pixels); picking it hands the clipboard's text back through `nativePaste` |
| `nativesRegistered()` | `ska_register_natives` | Marks `nativeOpenLink`, `nativePaste`, `nativeKeyboard` as registered, and hands over the links held meanwhile |
| `platformCall(String, byte[])`, `platformDrain()` | `PlatformChannel` | The platform channel (`PlatformServices`) |

The natives (`nativeOpenLink`, `nativePaste`, `nativeKeyboard`,
`nativePlatformEventsReady`) and the `nativePlatformRegistered` flag are
declared on `com.spritekit.platform.SpriteKitActivity`, and the shell
registers them there (`ska_natives_class` in `Shell/Sources/CAndroidShell`),
or on the activity's own class for an app whose activity still declares them
itself.

## `base/`

| File | What it does |
| --- | --- |
| `settings.gradle.kts`, `build.gradle.kts`, `gradle.properties`, `gradlew*`, `gradle/` | The Gradle project and wrapper, including the library's modules from `../spritekit-android/Library`; SDK levels in `gradle.properties` |
| `app/build.gradle.kts` | The app: the game's assets staged into the APK, version from the Xcode project, the beta flag, signing, Play Games' ID and the licence key (`resValue`), the library modules it uses, and the guards that stop an APK with no native libraries or no art |
| `app/src/main/AndroidManifest.xml` | GLES 3, the vibrator, SDL's activity settings; the library's entries are merged in |
| `MainActivity.java` | `SpriteKitActivity`, adding Play Billing (`addServices`) |
| `res/` | The app's name, a black launch theme with no splash icon, a placeholder launcher icon |

## What a game changes

1. **Placeholders.** Replace each, everywhere under the copy:

   | Placeholder | With |
   | --- | --- |
   | `PACKAGE_NAME` | The iOS bundle ID (`com.example.game`): the application ID, the namespace and `MainActivity`'s `package` line |
   | `PACKAGE_PATH` | The same as a path: move `app/src/main/java/PACKAGE_PATH/` to `app/src/main/java/com/example/game/` |
   | `APP_NAME` | The game's name (the launcher label, the Gradle project) |
   | `XCODE_PROJECT` | The Xcode project's name, whose `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` become the version name and code |
   | `GAME_SIGNING_ITEM` | The upload key's 1Password item (`<Game> Android Upload Key`), stored with `Scripts/signing.sh store` (README, "Signing") |

   The Gradle properties are under `game.` (`-Pgame.abis=arm64-v8a`,
   `-Pgame.beta=true|false`, `-Pgame.playGamesAppId=…`,
   `-Pgame.playLicenseKey=…`). A release build must pass `game.beta`; a
   debug build is a beta unless it says otherwise.
2. **Assets.** `app/build.gradle.kts` stages, under the APK's assets:

   | From | To | Read by |
   | --- | --- | --- |
   | `<game>/Android/Assets` (packed art) | the root | `AssetIndex` |
   | `Assets/Fonts/*.ttf`, `*.otf` | `fonts/` | `Shell.start(fonts:)`, `Bundle.main` |
   | `Assets/Music`, `Assets/SFX` | `audio/Music`, `audio/SFX` | `AudioAssets` |
   | `Assets/*.json`, Play Games' mapping | `resources/` | `Bundle.main` |
   | `Assets/*.lproj/*.strings`, `*.stringsdict` | `lproj/` | `Bundle.main` |

   `fonts/` and `resources/` are `ResourceBundle.defaultFolder`, the rule
   `Shell.start` uses unless given another. Point the sources at where the
   game keeps its files; a game that stages a resource anywhere else passes
   `Shell.start(resourceFolder:)` a rule that names the folder for each
   name and extension. The art is packed by
   `Tools/Art/xcassets-art.js` (the runtime README's "Packing art from an
   asset catalog").
3. **Icon.** Replace the placeholder (`res/drawable/ic_launcher_*.xml`,
   `res/mipmap/`, `res/mipmap-anydpi-v26/`) with the game's: PNGs in
   `res/mipmap-*dpi` and an adaptive icon in `mipmap-anydpi-v26`.
4. **Services.** A game that sells nothing drops `spritekit-billing` from
   `app/build.gradle.kts` and its line in `MainActivity.addServices`; one
   without Play Games keeps `games` (with no project ID it answers "signed
   out" at once). Local notifications: depend on `spritekit-notifications`
   and add `PlatformNotifications` (its README). A service of the game's own
   is a `PlatformService` added under its name.
5. **Links.** A game that opens links adds its intent filters to the
   manifest, and overrides `gameLink` if it reads them other than as a
   `VIEW` intent's URI. `SpriteKitActivity` hands a cold start's link to
   the game as `-LaunchLink <link>` (`LaunchLinks.launchLinkArgument`), and
   a running game's to `nativeOpenLink`; either way a new intent becomes the
   activity's (`setIntent`, which a notification tap is read from).
6. **Play Games' IDs.** The build reads
   `<game>/Tools/Play/PlayGames/PlayGamesAchievements.json` (the project ID,
   and each achievement's and leaderboard's Play ID by its Game Center ID)
   into the APK, and the project ID into `game_services_project_id`, which
   the library's manifest names as Play Games' `APP_ID`. Without it,
   progress, achievements and scores stay on the device.

The runtime's scripts fill in the rest: `Scripts/build-sdl.sh` fetches SDL
into `Vendor/SDL`, whose Java the library compiles in place, and copies
`libSDL3.so` into `app/src/main/jniLibs/`, and `Scripts/build-shell.sh` puts
the game's `libAndroidShell.so` beside it. Keep `jniLibs/` out of git.
Until both are there, and the art is packed, `assembleDebug` and the other
packaging tasks stop with the command to run; `./gradlew testDebugUnitTest`
(the library's tests too) needs only SDL's Java.

## Moving a copied app onto the library

An app copied from the template before the library keeps the Java it
copied. To move it over:

1. Add the library's modules to `settings.gradle.kts` (as `base/` does),
   `id("com.android.library") version "<AGP>" apply false` to the root
   build, and `implementation(project(":spritekit"))` (and
   `:spritekit-billing`, `:spritekit-notifications` as it uses them) to the
   app, in place of the Billing, Play Games, Review and androidx
   dependencies and `testImplementation("junit…")`.
2. Delete its `PlatformServices`, `DeviceServices`, `AudioFocusPolicy`,
   `PlayGamesServices`, `PlayReview`, `PlayBilling`, `PlatformNotifications`
   and the two receivers, their tests, `res/xml/shared_files.xml` and SDL's
   copied Java (`app/src/main/java/org/libsdl/`, which `build-sdl.sh` stops
   copying once the settings include the library).
3. Make `MainActivity` extend `SpriteKitActivity`, keeping only what it adds:
   services in `addServices`, its links in `gameLink`, its provider in
   `shareUri`; its own Java imports `com.spritekit.platform` and logs under
   `PlatformServices.tag()` (once `PlatformServices.TAG`).
4. Drop the manifest's `FileProvider`, Play Games' `APP_ID` meta-data and
   the notifications' receivers and permissions, which the library brings.
5. Turn `buildConfigField("String", "PLAY_LICENSE_KEY", …)` into
   `resValue("string", "play_license_key", …)` (and `buildConfig = true` can
   go), and write the beta flag as `build.json` at the assets' root.

## The protocol

Each service's calls and events are in its class's comment, and on the Swift
side in `Sources/PlatformShim` (`PlayBilling`, `PlayGamesAchievements`,
`PlayGamesLeaderboards`, `PlaySavedGamesCloud`, `PlayInAppReview`) and the
runtime README's "The platform layer".
