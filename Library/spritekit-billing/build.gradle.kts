plugins {
    id("com.android.library")
}

layout.buildDirectory = rootProject.layout.buildDirectory.dir("spritekit/${project.name}")

android {
    namespace = "com.spritekit.platform.billing"
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
    // Google Play Billing: one-time products' prices, purchases and restores,
    // and consumables.
    implementation("com.android.billingclient:billing:9.1.0")
}
