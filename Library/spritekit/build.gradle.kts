plugins {
    id("com.android.library")
}

// SDL's Android glue (the activity, the GL surface, input, audio), compiled
// here straight from the pinned SDL checkout that Scripts/build-sdl.sh
// fetches: SpriteKitActivity extends SDL's activity.
val sdlJava = file("../../Vendor/SDL/android-project/app/src/main/java")

// In the including project's build directory, so a game that builds this in
// place from its submodule leaves the submodule clean.
layout.buildDirectory = rootProject.layout.buildDirectory.dir("spritekit/${project.name}")

android {
    namespace = "com.spritekit.platform"
    compileSdk = 36

    defaultConfig {
        // The runtime's floor; a game's own may be higher.
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.directories += sdlJava.path
        }
    }
}

dependencies {
    // Play Games Services v2: sign-in, achievements, leaderboards, Saved Games.
    implementation("com.google.android.gms:play-services-games-v2:22.1.0")
    // Play In-App Review, behind SKStoreReviewController.
    implementation("com.google.android.play:review:2.0.2")
    // FileProvider, which hands the share sheet a file from the cache.
    implementation("androidx.core:core:1.15.0")
    // The Java side's decisions, on the JVM (`testDebugUnitTest`).
    testImplementation("junit:junit:4.13.2")
}

val checkSdlJava = tasks.register("checkSdlJava") {
    val found = sdlJava.resolve("org/libsdl/app/SDLActivity.java").exists()
    doFirst {
        if (!found) throw GradleException(
            "No SDL Java at $sdlJava: fetch SDL first, from the game's root:\n" +
                "    Android/spritekit-android/Scripts/build-sdl.sh arm64-v8a"
        )
    }
}
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(checkSdlJava) }
