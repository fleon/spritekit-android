plugins {
    id("com.android.application")
}

val abis = listOf("arm64-v8a", "x86_64")

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
            assets.srcDirs("../../Assets")
        }
    }

    androidResources {
        // Store the pages rather than deflating them. They are already PNG,
        // so compressing again buys nothing, and a stored asset can be read
        // straight out of the mapped APK instead of being inflated first.
        noCompress += listOf("png", "json")
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
