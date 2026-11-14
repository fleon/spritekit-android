plugins {
    id("com.android.asset-pack")
}

// The install-time asset pack: the packed art, the fonts and the audio, which
// together are most of the game's size. A release bundle carries them here
// rather than in the base module, whose download Google Play caps at 200 MB a
// device; Play installs an install-time pack with the app, as one more split
// APK, so `AAssetManager` (and SDL_LoadFile over it) finds every file at the
// same path as before. The debug APK still carries them in its base (the app's
// `debug` source set), since an APK built by Gradle has no packs.
assetPack {
    packName.set("content")
    dynamicDelivery {
        deliveryType.set("install-time")
    }
}

// The plugin reads `src/main/assets` and nothing else, so the pack is staged
// there (gitignored) from where each part is built. The app's bundle task
// depends on this (see the foot of app/build.gradle.kts): the plugin publishes
// the folder with no task behind it.
val stageContent = tasks.register<Sync>("stageContent") {
    // The art, from `npm run art -- --android`: atlas pages, the whole
    // pages, index.json and the rigs.
    from(rootProject.file("../Assets"))
    // The three faces the text stack registers.
    from(rootProject.file("../../Assets/Fonts")) {
        include("*.ttf")
        into("fonts")
    }
    // The soundtrack and the sound effects.
    from(rootProject.file("../../Assets/Music")) { into("audio/Music") }
    from(rootProject.file("../../Assets/SFX")) { into("audio/SFX") }
    into(layout.projectDirectory.dir("src/main/assets"))
}
