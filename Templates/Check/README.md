# The template check

A stand-in game, the least a game needs to build from `Templates/Game` and
`Templates/App/base`: a `Source/` folder with the scene and splash style the
game template's controller names, and an asset catalog with the splash's
logo.

`Scripts/check-template.sh` lays it out as a game would be (`Source/`,
`Android/spritekit-android`, `Android/Game`, `Android/App`), fills in the
templates' placeholders, packs the art, and builds the debug APK. The CI
then installs that APK on an emulator and waits for the scene's message in
logcat (`TitleScene.shownMessage`).

```bash
Scripts/check-template.sh x86_64      # the APK for an x86_64 emulator
Scripts/check-template.sh             # every ABI the app ships
```

It needs what `Scripts/build-shell.sh` does (`Vendor/build.sh android`,
and the NDK and Swift SDK), JDK 17 and the Android SDK, and an
`~/.android/debug.keystore`.
