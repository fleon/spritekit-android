# The app template

The Android app a game on this runtime ships: a Gradle project whose one
activity is SDL's, with the Java half of every platform service the runtime
talks to over its platform channel (`Sources/PlatformShim/PlatformChannel.swift`).
Everything above the GL context is the game's Swift, in `libAndroidShell.so`.

```
Templates/App/
  base/            the app every game starts from (copy it to <game>/Android/App)
  <feature>/       a service only some games need, with its own README
                   (notifications/, …): copy its files in and wire it up
```

## `base/`

| File | What it does |
| --- | --- |
| `settings.gradle.kts`, `build.gradle.kts`, `gradle.properties`, `gradlew*`, `gradle/` | The Gradle project and wrapper; SDK levels in `gradle.properties` |
| `app/build.gradle.kts` | The app: the game's assets staged into the APK, version from the Xcode project, the beta flag, signing, Play Games' ID, the licence key, the dependencies, and the guards that stop an APK with no native libraries or no art |
| `app/src/main/AndroidManifest.xml` | GLES 3, the vibrator, SDL's activity settings, the share sheet's `FileProvider`, Play Games' `APP_ID` |
| `MainActivity.java` | SDL's activity: launch arguments in debuggable builds, the environment the runtime reads (below), Back on Android 13 and later, the safe area as iOS gives it, the share sheet (`shareFile`), Paste over a text field (`offerPaste`), the platform channel's two JNI calls |
| `PlatformServices.java` | The channel's Java end: dispatches `service.method` calls and queues events |
| `DeviceServices.java` | `device`: haptics, battery saver, audio focus, the status bar |
| `AudioFocusPolicy.java` (+ its test) | When to ask for audio focus, as an ambient iOS session behaves |
| `PlayBilling.java` | `billing`: one-time products (prices, purchases, acknowledgement, restore) |
| `PlayGamesServices.java` | `games`: sign-in, achievements, leaderboards, the player, Saved Games |
| `PlayReview.java` | `review`: Play In-App Review, behind `SKStoreReviewController` |
| `res/` | The app's name, a black launch theme with no splash icon, a placeholder launcher icon, the `FileProvider`'s paths (`xml/shared_files.xml`: the cache) |

### What the Java side hands the runtime

`MainActivity.loadLibraries` sets these before the Swift libraries load,
and the shim reads them from the environment:

| Variable | Value | Read by |
| --- | --- | --- |
| `SKA_VERSION_NAME`, `SKA_VERSION_CODE` | The APK's `versionName` and `versionCode` | `Bundle.main.infoDictionary` |
| `SKA_DEVICE_MODEL` | Maker and model, "Google Pixel 9" | `AndroidDevice.current.model` |
| `SKA_OS_VERSION` | `Build.VERSION.RELEASE`, "17" | `AndroidDevice.current.osVersion` |
| `SKA_EMULATOR` | `1` on an emulator, else `0` | `AndroidDevice.current.isEmulator`, `LaunchDefaults.onEmulator` |
| `SKA_BETA` | `1` in a beta build (`-Pgame.beta`, through `build.json` in the assets), else `0` | `BetaBuild.current`, `LaunchDefaults.outsideBeta` |
| `SWIFT_DETERMINISTIC_HASHING` | `1` with `-FixedFrameStep` (debug builds) | Swift's `Dictionary` and `Set` |

And the shell calls these on the activity through JNI:

| Method | Called from | Does |
| --- | --- | --- |
| `shareFile(String path, String mime, String text)` | `SystemShare.sheet` (`ska_share_file`) | `ACTION_SEND` through the chooser, the file as a `content://` URI from androidx's `FileProvider` (authority `<applicationId>.files`), `text` (may be null) as `EXTRA_TEXT` |
| `offerPaste(float x, float y)` | `TextInput.offerPaste` (`ska_offer_paste`), on a long press in a text field | A Paste button over that point (view pixels); picking it hands the clipboard's text back through `nativePaste` |
| `nativesRegistered()` | `ska_register_natives` | Marks `nativeOpenLink`, `nativePaste`, `nativeKeyboard` as registered |
| `platformCall(String, byte[])`, `platformDrain()` | `PlatformChannel` | The platform channel (`PlatformServices`) |

## What a game changes

1. **Placeholders.** Replace each, everywhere under the copy:

   | Placeholder | With |
   | --- | --- |
   | `PACKAGE_NAME` | The iOS bundle ID (`com.example.game`): the application ID, the namespace and every `.java` file's `package` line |
   | `PACKAGE_PATH` | The same as a path: move `app/src/main/java/PACKAGE_PATH/` to `app/src/main/java/com/example/game/`, and the test folder alike |
   | `APP_NAME` | The game's name (the launcher label, the Gradle project, the log tag) |
   | `XCODE_PROJECT` | The Xcode project's name, whose `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` become the version name and code |
   | `GAME_KEY` | A short key for the upload keystore's folder and Keychain item (`~/.config/GAME_KEY/android/upload.jks`) |

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
   | `Assets/*.lproj/*.strings` | `lproj/` | `Bundle.main` |

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
4. **Services.** Remove what the game doesn't use: a game that sells nothing
   deletes `PlayBilling.java`, its four lines in `PlatformServices` and the
   Billing Library dependency; one without Play Games keeps
   `PlayGamesServices` (with no project ID it answers "signed out" at once).
   Add a feature folder's files for anything more: each folder's README says
   what to copy and how to wire it into `PlatformServices`, the manifest and
   `MainActivity` (local notifications: `notifications/README.md`).
5. **Links.** A game that opens links adds its intent filters to the
   manifest, adds a cold start's link to `getArguments` as
   `-LaunchLink <link>` (`LaunchLinks.launchLinkArgument`), and hands a
   running game's to `nativeOpenLink` from `onNewIntent`. The base opens
   none.
6. **Play Games' IDs.** The build reads
   `<game>/Tools/Play/PlayGames/PlayGamesAchievements.json` (the project ID,
   and each achievement's and leaderboard's Play ID by its Game Center ID)
   into the APK, and the project ID into the manifest. Without it, progress,
   achievements and scores stay on the device.

The runtime's scripts fill in the rest: `Scripts/build-sdl.sh` copies SDL's
Java into `app/src/main/java/org/libsdl/app/` and `libSDL3.so` into
`app/src/main/jniLibs/`, and `Scripts/build-shell.sh` puts the game's
`libAndroidShell.so` beside it. Keep those two folders out of git. Until
both are there, and the art is packed, `assembleDebug` and the other
packaging tasks stop with the command to run; `./gradlew testDebugUnitTest`
needs only SDL's Java.

## The protocol

Each service's calls and events are in its class's comment, and on the Swift
side in `Sources/PlatformShim` (`PlayBilling`, `PlayGamesAchievements`,
`PlayGamesLeaderboards`, `PlaySavedGamesCloud`, `PlayInAppReview`) and the
runtime README's "The platform layer".
