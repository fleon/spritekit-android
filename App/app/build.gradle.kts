plugins {
    id("com.android.application")
}

val abis = listOf("arm64-v8a", "x86_64")

// The game's fonts, staged into the APK under `assets/fonts/`.
//
// They live in the repository's own `Assets/Fonts` beside everything else
// the Apple build ships, and they are the only part of that directory
// Android wants — pointing the asset source set at the whole of it would
// drag in the levels, the music and the sound effects as well. So one copy
// task picks out the three faces the text stack registers.
//
// A plain path rather than a `Provider<Directory>`: AGP refuses a provider
// in `assets.srcDirs` because the task dependency would not carry, which is
// exactly what the `MergeSourceSetFolders` wiring below does by hand.
val stagedFonts = "build/generated/fontAssets"

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
            assets.srcDirs("../../Assets", stagedFonts)
        }
    }

    androidResources {
        // Store the pages rather than deflating them. They are already PNG,
        // so compressing again buys nothing, and a stored asset can be read
        // straight out of the mapped APK instead of being inflated first.
        // The fonts are stored for a sharper reason: FreeType reads the 50 MB
        // variable face whole, and a deflated asset has to be inflated into a
        // second buffer first.
        noCompress += listOf("png", "json", "ttf")
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

tasks.withType<com.android.build.gradle.tasks.MergeSourceSetFolders>().configureEach {
    dependsOn(stageFonts)
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
