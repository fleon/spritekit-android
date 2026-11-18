// The library on its own, for its checks (`./gradlew :spritekit:assembleDebug
// :spritekit:testDebugUnitTest`). A game's Gradle project includes the same
// modules in place from its submodule instead (Templates/App/README.md).
pluginManagement {
    repositories {
        google()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "spritekit-library"
include(":spritekit", ":spritekit-billing", ":spritekit-notifications")
