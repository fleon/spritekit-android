plugins {
    id("com.android.application")
}

// Both ABIs unless `-Pswitchlings.abis=arm64-v8a` asks for fewer: a quick
// build for the Apple Silicon emulators (Android/Scripts/parity.js), which
// needs only that ABI's `Scripts/build-shell.sh` run.
val abis = (findProperty("switchlings.abis") as String?)?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() }
    ?: listOf("arm64-v8a", "x86_64")

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
// Then Android's own words (`Android/Strings`, see its README) replace the
// game's for the few keys where Android names a thing differently: the
// Haptics setting is "Vibration" here.
val androidStrings = rootProject.file("../Strings")
val stageStrings = tasks.register<Sync>("stageStrings") {
    from(rootProject.file("../../Assets")) {
        include("*.lproj/*.strings")
    }
    into(file("$stringAssets/lproj"))
    inputs.dir(androidStrings)
    doLast {
        val line = Regex("""^\s*"([^"]+)"\s*=.*;\s*$""")
        androidStrings.walkTopDown().filter { it.isFile && it.extension == "strings" && it.name != "Android.strings" }.forEach { override ->
            val target = file("$stringAssets/lproj/${override.parentFile.name}/${override.name}")
            if (!target.exists()) throw GradleException("Android/Strings: no ${override.parentFile.name}/${override.name} in the game's strings")
            val replacements = override.readLines().mapNotNull { l -> line.matchEntire(l)?.let { it.groupValues[1] to l } }.toMap()
            val seen = mutableSetOf<String>()
            val merged = target.readLines().map { l ->
                val key = line.matchEntire(l)?.groupValues?.get(1)
                if (key != null && key in replacements) { seen += key; replacements.getValue(key) } else l
            }
            val missing = replacements.keys - seen
            if (missing.isNotEmpty()) throw GradleException("Android/Strings: ${override.parentFile.name} overrides keys the game doesn't have: $missing")
            target.writeText(merged.joinToString("\n", postfix = "\n"))
        }
        // Words only Android says (the pre-registration reward's notice):
        // `Android.strings` adds its keys to the language's Localizable.strings,
        // and stops the build if the game already has one of them, or if a
        // language lacks a key the English file has.
        val additions = androidStrings.walkTopDown().filter { it.isFile && it.name == "Android.strings" }.toList()
        fun keys(file: File) = file.readLines().mapNotNull { l -> line.matchEntire(l)?.groupValues?.get(1) }.toSet()
        val english = additions.firstOrNull { it.parentFile.name == "Base.lproj" }?.let(::keys).orEmpty()
        additions.forEach { addition ->
            val target = file("$stringAssets/lproj/${addition.parentFile.name}/Localizable.strings")
            if (!target.exists()) throw GradleException("Android/Strings: no ${addition.parentFile.name}/Localizable.strings in the game's strings")
            val added = keys(addition)
            val clashing = added intersect keys(target)
            if (clashing.isNotEmpty()) throw GradleException("Android/Strings: ${addition.parentFile.name}/Android.strings adds keys the game already has: $clashing")
            val missing = english - added
            if (missing.isNotEmpty()) throw GradleException("Android/Strings: ${addition.parentFile.name}/Android.strings lacks $missing")
            target.appendText("\n" + addition.readText().trimEnd() + "\n")
        }
    }
}

// Whether this build is a beta, for Play's testing tracks (internal, closed
// and open): it plays the Level Designer's live level feed and posts each
// clear to its solve log (`DesignerFeed`, `PlaytestLog`), as every Apple
// build does during the beta. Play can't tell an app which track installed
// it, so it's chosen here:
//
//     ./gradlew bundleRelease -Pswitchlings.beta=true    # internal, closed, open
//     ./gradlew bundleRelease -Pswitchlings.beta=false   # production
//
// A release build must say which (`checkBetaChoice`); a debug build is a beta
// unless told otherwise. It lands in the base module's assets as
// `SwitchlingsBuild.json`, which `MainActivity` reads at launch and
// `Tools/Play/play.js release` checks before it uploads to a testing track.
// A production release is its own `false` build, never a promotion from a
// testing track. All of it comes out before the store release.
val betaChoice = (findProperty("switchlings.beta") as String?)?.trim()
val isBeta = when (betaChoice) {
    null, "true" -> true
    "false" -> false
    else -> throw GradleException("-Pswitchlings.beta is true or false, not \"$betaChoice\"")
}
val buildInfoAssets = "build/generated/buildInfoAssets"
val stageBuildInfo = tasks.register("stageBuildInfo") {
    val beta = isBeta
    val out = file("$buildInfoAssets/SwitchlingsBuild.json")
    inputs.property("beta", beta)
    outputs.file(out)
    doLast {
        out.parentFile.mkdirs()
        out.writeText("{\"beta\": $beta}\n")
    }
}
val checkBetaChoice = tasks.register("checkBetaChoice") {
    val chosen = betaChoice != null
    doFirst {
        if (!chosen) throw GradleException(
            "A release build must say whether it's a beta:\n" +
                "    -Pswitchlings.beta=true    for Play's testing tracks (internal, closed, open)\n" +
                "    -Pswitchlings.beta=false   for production, which is never promoted from a testing track"
        )
    }
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

// One build setting from the iOS app's Xcode project, which every target
// shares (the app, the stickers and Top Shelf carry the same values).
fun appleVersion(setting: String): String {
    val project = rootProject.file("../../Switchlings.xcodeproj/project.pbxproj").readText()
    val values = Regex("""\b$setting = ([^;]+);""").findAll(project).map { it.groupValues[1].trim('"', ' ') }.toSet()
    return values.singleOrNull() ?: error("$setting isn't one value in the Xcode project: $values")
}

android {
    namespace = "com.fleon.switchlings"
    compileSdk = property("switchlings.compileSdk").toString().toInt()

    defaultConfig {
        applicationId = "com.fleon.switchlings"
        minSdk = property("switchlings.minSdk").toString().toInt()
        targetSdk = property("switchlings.targetSdk").toString().toInt()
        // The same version and build as the iOS app: MARKETING_VERSION and
        // CURRENT_PROJECT_VERSION in the Xcode project (`Build N` bumps it).
        // `-Pswitchlings.versionCode` / `versionName` override them.
        versionCode = ((findProperty("switchlings.versionCode") as String?) ?: appleVersion("CURRENT_PROJECT_VERSION")).toInt()
        versionName = (findProperty("switchlings.versionName") as String?) ?: appleVersion("MARKETING_VERSION")
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
            assets.srcDirs(levelAssets, stringAssets, buildInfoAssets)
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
    dependsOn(stageFonts, stageAudio, stageLevelAssets, stageStrings, stageBuildInfo)
}
// A release build's lint reads the asset folders too.
tasks.matching { it.name.contains("lint", ignoreCase = true) }.configureEach {
    dependsOn(stageFonts, stageAudio, stageLevelAssets, stageStrings, stageBuildInfo)
}
// Every release build names its beta choice (above).
tasks.matching { it.name == "preReleaseBuild" }.configureEach { dependsOn(checkBetaChoice) }
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
