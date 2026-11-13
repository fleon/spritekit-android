plugins {
    id("com.android.application")
}

val abis = listOf("arm64-v8a", "x86_64")

// Two things are staged into the APK out of the repository's own `Assets`,
// each under a prefix of its own so the packed art keeps the assets root.
//
// Both are plain paths rather than `Provider<Directory>`: AGP refuses a
// provider in `assets.srcDirs`, because it cannot tell generated output from
// checked-in files and the task dependency would not carry — which is what
// the `MergeSourceSetFolders` wiring at the foot of this file does by hand.

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
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            // The packed art: atlas pages, the whole tiling pages and
            // index.json, produced by `npm run art -- --android`. Gitignored
            // and about 100 MB, so it is referenced where it is built rather
            // than copied into the Gradle project.
            //
            // Beside it, the fonts and the audio, each staged by a task
            // below. Separate roots rather than one tree: the art's
            // directory is a build output that `npm run art -- --android`
            // rewrites wholesale, so nothing else may live inside it.
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
        noCompress += listOf("png", "json", "ttf", "m4a", "wav", "ogg", "mp3")
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

    buildTypes {
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

val stageFonts = tasks.register<Copy>("stageFonts") {
    from(layout.projectDirectory.dir("../../../Assets/Fonts")) {
        include("*.ttf")
        into("fonts")
    }
    into(layout.projectDirectory.dir(stagedFonts))
}

// Both staging tasks have to run before AGP merges the asset folders, and
// AGP will not infer it from `assets.srcDirs` alone (see the note there).
tasks.withType<com.android.build.gradle.tasks.MergeSourceSetFolders>().configureEach {
    dependsOn(stageFonts, stageAudio)
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