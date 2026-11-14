plugins {
    id("com.android.application")
}

val abis = listOf("arm64-v8a", "x86_64")

// Three things are staged into the APK out of the repository's own `Assets`,
// each under a prefix of its own so the packed art keeps the assets root.
//
// All three are plain paths rather than `Provider<Directory>`: AGP refuses a
// provider in `assets.srcDirs`, because it cannot tell generated output from
// checked-in files and the task dependency would not carry — which is what
// the `MergeSourceSetFolders` wiring at the foot of this file does by hand.
//
// The art, the fonts and the audio go into the debug APK's base only. A
// release bundle carries them in the `content` install-time asset pack
// (`../content`), which keeps the base under Google Play's 200 MB a device.

// The fonts, under `assets/fonts/`. Only the faces the text stack registers:
// pointing the source set at the whole of `Assets/Fonts` would drag in the
// levels, the music and the sound effects too.
val stagedFonts = "build/generated/fontAssets"

// The soundtrack and the sound effects, under `assets/audio/` — the same
// bytes the Apple build bundles, not a second encoding.
val audioAssets = "build/generatedAudio"
val stageAudio = tasks.register<Copy>("stageAudio") {
    into(layout.buildDirectory.dir("generatedAudio/audio"))
    from(rootProject.file("../../Assets/Music")) { into("Music") }
    from(rootProject.file("../../Assets/SFX")) { into("SFX") }
}

// The levels, under `assets/levels/`. They live in the repo at
// Assets/Levels, beside the Apple build's own copy; a `levels/` folder of
// their own keeps Worlds.json from landing next to the art's index.json.
val levelAssets = "build/generated/levelAssets"
val stageLevelAssets = tasks.register<Sync>("stageLevelAssets") {
    from(rootProject.file("../../Assets/Levels")) { include("*.json") }
    if (playGamesFile.exists()) from(playGamesFile)
    into(file("$levelAssets/levels"))
}

// Each language's strings, under `assets/lproj/<language>.lproj/`: what
// `Localization` opens with `Bundle(path:)`, as on Apple. Only the `.strings`
// files: the launch storyboard in Base.lproj is Apple's alone.
val stringAssets = "build/generated/stringAssets"
val stageStrings = tasks.register<Sync>("stageStrings") {
    from(rootProject.file("../../Assets")) {
        include("*.lproj/*.strings")
    }
    into(file("$stringAssets/lproj"))
}

// Play Games Services: the game's project ID and its achievements' IDs, both
// written by `Tools/Play/games.js` once the achievements exist on Play. The
// file goes into the APK beside the levels (`Bundle.main`'s `.json` folder),
// and the ID into the manifest's APP_ID. With no file, or no ID in it, the
// build has no Play Games: sign-in answers "no" at once and the game keeps
// achievements and saved data on the device.
val playGamesFile = rootProject.file("../../Tools/Play/PlayGames/PlayGamesAchievements.json")
val playGamesAppId: String = (findProperty("switchlings.playGamesAppId") as String?)
    ?: if (playGamesFile.exists()) {
        ((groovy.json.JsonSlurper().parse(playGamesFile) as Map<*, *>)["applicationId"] as String?) ?: ""
    } else ""

// The upload key, which signs what goes to Play (Play re-signs it with the
// app signing key). It lives outside every checkout and its password lives in
// the macOS Keychain, never in a file:
//
//     ~/.config/switchlings/android/upload.jks
//     security find-generic-password -s switchlings-android-upload -a upload -w
//
// CI passes both in the environment instead (SWITCHLINGS_UPLOAD_KEYSTORE,
// SWITCHLINGS_UPLOAD_PASSWORD). With neither, a release build is unsigned.
val uploadKeystore = file(System.getenv("SWITCHLINGS_UPLOAD_KEYSTORE")
    ?: "${System.getProperty("user.home")}/.config/switchlings/android/upload.jks")
fun uploadPassword(): String? = System.getenv("SWITCHLINGS_UPLOAD_PASSWORD") ?: runCatching {
    providers.exec {
        commandLine("security", "find-generic-password", "-s", "switchlings-android-upload", "-a", "upload", "-w")
        isIgnoreExitValue = true
    }.standardOutput.asText.get().trim().ifEmpty { null }
}.getOrNull()

android {
    namespace = "com.fleon.switchlings"
    compileSdk = property("switchlings.compileSdk").toString().toInt()

    defaultConfig {
        applicationId = "com.fleon.switchlings"
        minSdk = property("switchlings.minSdk").toString().toInt()
        targetSdk = property("switchlings.targetSdk").toString().toInt()
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += abis }

        // Play Games' project ID, a string resource because the manifest's
        // APP_ID must name one (a bare number would be read as a float).
        resValue("string", "game_services_project_id", playGamesAppId)
        // The app's licence key from Play Console (Monetization setup), to
        // check Play's signature on each purchase. Public, not a secret;
        // empty skips the check.
        buildConfigField("String", "PLAY_LICENSE_KEY",
            "\"" + ((findProperty("switchlings.playLicenseKey") as String?) ?: "") + "\"")
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Release bundles carry the art, the fonts and the audio in an
    // install-time asset pack, which Play installs with the app as one more
    // split APK: `AAssetManager` finds every file at the same path as when it
    // sat in the base.
    assetPacks += listOf(":content")

    sourceSets {
        getByName("main") {
            // The levels and the strings, each staged by a task below: small,
            // and in the base of every build.
            assets.srcDirs(levelAssets, stringAssets)
        }
        getByName("debug") {
            // The packed art: atlas pages, the whole tiling pages and
            // index.json, produced by `npm run art -- --android`. Gitignored
            // and about 100 MB, so it is referenced where it is built rather
            // than copied into the Gradle project.
            //
            // Beside it, the fonts and the audio, each staged by a task
            // below. Separate roots rather than one tree: the art's directory
            // is a build output that `npm run art -- --android` rewrites
            // wholesale, so nothing else may live inside it.
            //
            // Only in debug: an APK Gradle builds has no asset packs, so the
            // debug APK carries in its base what a release bundle carries in
            // the `content` pack.
            assets.srcDirs("../../Assets", stagedFonts, audioAssets)
        }
    }

    androidResources {
        // Store the pages rather than deflating them. They are already PNG,
        // so compressing again buys nothing, and a stored asset can be read
        // straight out of the mapped APK instead of being inflated first.
        //
        // The fonts are stored for a sharper reason: FreeType reads the 50 MB
        // variable face whole, and a deflated asset has to be inflated into a
        // second buffer first.
        //
        // The audio for a sharper one again: MediaCodec decodes the
        // soundtrack from a file descriptor into the APK rather than a copy
        // on the device, and only a stored asset has one
        // (`AAsset_openFileDescriptor` fails on a deflated asset). Keep m4a
        // here if the music ever moves container — ogg and mp3 are listed
        // for that day.
        noCompress += listOf("png", "json", "ttf", "m4a", "wav", "ogg", "mp3", "strings")
    }

    packaging {
        jniLibs {
            // The .so files are cross-compiled and already stripped by
            // Android/Scripts/build-{sdl,shell}.sh. Telling AGP to keep their
            // symbols stops it running its own strip step, which would want
            // an NDK installed under the SDK just to redo work already done.
            keepDebugSymbols += "**/*.so"
        }
    }

    signingConfigs {
        if (uploadKeystore.exists()) {
            create("upload") {
                storeFile = uploadKeystore
                storeType = "PKCS12"
                keyAlias = "upload"
                // Read only when a release is actually signed.
                val password = uploadPassword()
                storePassword = password
                keyPassword = password
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("upload")
        }
        debug {
            isJniDebuggable = true
            // An optional suffix on the package name, so two debug builds
            // can be installed at once:
            //
            //     ./gradlew assembleDebug -Pswitchlings.applicationIdSuffix=.audio
            //     adb shell am start -n com.fleon.switchlings.audio/com.fleon.switchlings.MainActivity
            //
            // Worth having because several people (or sessions) share one
            // emulator while the port is being built, and an install
            // otherwise replaces whatever was there — including a run
            // somebody is in the middle of reading the log of. Empty by
            // default, so a plain build is unchanged.
            applicationIdSuffix = (findProperty("switchlings.applicationIdSuffix") as String?) ?: ""
        }
    }
}

dependencies {
    // Google Play Billing: the full game's price, purchase and restore.
    implementation("com.android.billingclient:billing:9.1.0")
    // Play Games Services v2: sign-in, achievements, the player, Saved Games.
    implementation("com.google.android.gms:play-services-games-v2:22.1.0")
}

val stageFonts = tasks.register<Copy>("stageFonts") {
    from(layout.projectDirectory.dir("../../../Assets/Fonts")) {
        include("*.ttf")
        into("fonts")
    }
    into(layout.projectDirectory.dir(stagedFonts))
}

// Every staging task has to run before AGP merges the asset folders, and
// AGP will not infer it from `assets.srcDirs` alone (see the note there).
tasks.withType<com.android.build.gradle.tasks.MergeSourceSetFolders>().configureEach {
    dependsOn(stageFonts, stageAudio, stageLevelAssets, stageStrings)
}
// A release build's lint reads the asset folders too.
tasks.matching { it.name.contains("lint", ignoreCase = true) }.configureEach {
    dependsOn(stageFonts, stageAudio, stageLevelAssets, stageStrings)
}
// The asset pack's plugin publishes its folder with no task behind it, so
// whatever packs it into a bundle has to wait for the folder to be staged.
tasks.matching { it.name.startsWith("assetPack") }.configureEach {
    dependsOn(":content:stageContent")
}

// An APK with no Swift in it still installs and still launches — and then
// dies in the linker with nothing useful in logcat. Fail here instead.
val checkNativeLibraries = tasks.register("checkNativeLibraries") {
    val jniLibs = layout.projectDirectory.dir("src/main/jniLibs")
    doFirst {
        val missing = abis.filter { !jniLibs.dir(it).file("libAndroidShell.so").asFile.exists() }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "No libAndroidShell.so for ${missing.joinToString(", ")}.\n" +
                    "Build the native side first:\n" +
                    "    Android/Scripts/build-sdl.sh && Android/Scripts/build-shell.sh"
            )
        }
    }
}

tasks.named("preBuild") { dependsOn(checkNativeLibraries) }
// A debug bundle would carry the art twice, in the debug APK's base and in
// the `content` pack, which bundletool refuses with a puzzling "Both modules
// contain asset entry". Say what to do instead.
tasks.matching { it.name == "packageDebugBundle" }.configureEach {
    doFirst {
        throw GradleException(
            "A debug bundle is not built: the debug APK carries the art in its base, a bundle in the " +
                "`content` asset pack.\nBuild `assembleDebug` for an APK, or `bundleRelease` for Play."
        )
    }
}
