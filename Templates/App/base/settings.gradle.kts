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

rootProject.name = "APP_NAME"
include(":app")

// The runtime's Android library, built in place from the submodule: the
// activity and the Java half of every platform service. The app depends on
// the modules it uses (app/build.gradle.kts).
val runtimeLibrary = file("../spritekit-android/Library")
for (module in listOf("spritekit", "spritekit-billing", "spritekit-notifications")) {
    include(":$module")
    project(":$module").projectDir = runtimeLibrary.resolve(module)
}
