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
| `app/build.gradle.kts` | The app: the game's assets staged into the APK, version from the Xcode project, signing, Play Games' ID, the licence key, the dependencies |
| `app/src/main/AndroidManifest.xml` | GLES 3, the vibrator, SDL's activity settings, Play Games' `APP_ID` |
| `MainActivity.java` | SDL's activity: launch arguments in debuggable builds, Back on Android 13 and later, the safe area as iOS gives it, the platform channel's two JNI calls |
| `PlatformServices.java` | The channel's Java end: dispatches `service.method` calls and queues events |
| `DeviceServices.java` | `device`: haptics, battery saver, audio focus, the status bar |
| `AudioFocusPolicy.java` (+ its test) | When to ask for audio focus, as an ambient iOS session behaves |
| `PlayBilling.java` | `billing`: one-time products (prices, purchases, acknowledgement, restore) |
| `PlayGamesServices.java` | `games`: sign-in, achievements, leaderboards, the player, Saved Games |
| `PlayReview.java` | `review`: Play In-App Review, behind `SKStoreReviewController` |
| `res/` | The app's name, a black launch theme with no splash icon |

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
   `-Pgame.playGamesAppId=…`, `-Pgame.playLicenseKey=…`).
2. **Assets.** `app/build.gradle.kts` stages the game's `Assets/Fonts`,
   `Assets/Music`, `Assets/SFX`, the `.json` files at the top of `Assets` and
   each `.lproj`'s `.strings`, plus the packed art in `<game>/Android/Assets`
   (`Tools/Art/xcassets-art.js`). Point those at where the game keeps them.
3. **Icon.** Add `res/mipmap-*` launcher icons (`ic_launcher`,
   `ic_launcher_round`, and an adaptive icon in `mipmap-anydpi-v26`).
4. **Services.** Remove what the game doesn't use: a game that sells nothing
   deletes `PlayBilling.java`, its four lines in `PlatformServices` and the
   Billing Library dependency; one without Play Games keeps
   `PlayGamesServices` (with no project ID it answers "signed out" at once).
   Add a feature folder's files for anything more.
5. **Play Games' IDs.** The build reads
   `<game>/Tools/Play/PlayGames/PlayGamesAchievements.json` (the project ID,
   and each achievement's and leaderboard's Play ID by its Game Center ID)
   into the APK, and the project ID into the manifest. Without it, progress,
   achievements and scores stay on the device.

The runtime's scripts fill in the rest: `Scripts/build-sdl.sh` copies SDL's
Java into `app/src/main/java/org/libsdl/app/` and `libSDL3.so` into
`app/src/main/jniLibs/`, and `Scripts/build-shell.sh` puts the game's
`libAndroidShell.so` beside it. Keep those two folders out of git.

## The protocol

Each service's calls and events are in its class's comment, and on the Swift
side in `Sources/PlatformShim` (`PlayBilling`, `PlayGamesAchievements`,
`PlayGamesLeaderboards`, `PlaySavedGamesCloud`, `PlayInAppReview`) and the
README's sections on each.
