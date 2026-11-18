plugins {
    id("com.android.library")
}

layout.buildDirectory = rootProject.layout.buildDirectory.dir("spritekit/${project.name}")

android {
    namespace = "com.spritekit.platform.notifications"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // Its services implement the core's PlatformService.
    api(project(":spritekit"))
}
