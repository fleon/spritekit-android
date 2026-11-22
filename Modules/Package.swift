// swift-tools-version: 6.2
import PackageDescription

// Android-only. Do not build this package on a Mac: it declares targets named
// CoreGraphics and UIKit, which exist to take those module names where the
// system has none. On macOS they cycle with the real modules.
//
// What this package is for: a game's sources keep `import SpriteKit`,
// `import UIKit`, `import CoreGraphics` and the rest, unedited. On Android no
// system module answers those names, so these targets do, each re-exporting
// the shim (and the platform layer where Apple's module has a service in it).
// A game's own package depends on the products it imports.
//
//   swift build --swift-sdk swift-6.4.2-RELEASE_android \
//               --triple aarch64-unknown-linux-android23
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM")
let v5 = SwiftSetting.swiftLanguageMode(.v5)
let shim = Target.Dependency.product(name: "SpriteKitShim", package: "spritekit-android")
let platform = Target.Dependency.product(name: "PlatformShim", package: "spritekit-android")
let services = Target.Dependency.product(name: "PlatformServices", package: "spritekit-android")

/// A module-name target: `Sources/<name>`, in Swift 5 with the shim's define.
func module(_ name: String, _ dependencies: [Target.Dependency]) -> Target {
    .target(name: name, dependencies: dependencies, path: "Sources/\(name)", swiftSettings: [v5, shimDefine])
}

let package = Package(
    name: "SpriteKitAndroidModules",
    products: [
        .library(name: "SpriteKit", targets: ["SpriteKit"]),
        .library(name: "UIKit", targets: ["UIKit"]),
        .library(name: "CoreText", targets: ["CoreText"]),
        .library(name: "CoreGraphics", targets: ["CoreGraphics"]),
        .library(name: "CoreImage", targets: ["CoreImage"]),
        .library(name: "QuartzCore", targets: ["QuartzCore"]),
        .library(name: "StoreKit", targets: ["StoreKit"]),
        .library(name: "CryptoKit", targets: ["CryptoKit"]),
        .library(name: "Security", targets: ["Security"]),
        .library(name: "GameKit", targets: ["GameKit"]),
        .library(name: "GameplayKit", targets: ["GameplayKit"]),
        .library(name: "Network", targets: ["Network"]),
        .library(name: "Metal", targets: ["Metal"]),
        .library(name: "CoreVideo", targets: ["CoreVideo"]),
        .library(name: "AVFoundation", targets: ["AVFoundation"]),
        .library(name: "os", targets: ["os"]),
        .library(name: "simd", targets: ["simd"]),
        .library(name: "UserNotifications", targets: ["UserNotifications"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        module("SpriteKit", [shim, "simd"]),
        module("UIKit", [shim, "simd"]),
        module("CoreText", [shim]),
        module("CoreGraphics", [shim]),
        module("CoreImage", [shim]),
        module("QuartzCore", [shim]),
        module("StoreKit", [shim, platform]),
        module("CryptoKit", [platform]),
        module("Security", [shim, platform]),
        // Two a game may import to describe the player and the network.
        module("GameKit", [shim, platform]),
        // Empty: the SpriteKit template's unused `import GameplayKit`.
        module("GameplayKit", []),
        module("Network", [shim]),
        // The three a game writing video and audio files imports.
        module("Metal", [shim]),
        module("CoreVideo", [shim]),
        module("AVFoundation", [shim, platform]),
        module("os", [services]),
        // Not a passthrough: Android has no Accelerate, so this one has the
        // free-function spelling of the SIMD maths in it. It also re-exports
        // the shim, whose matrix types `SKUniform` takes.
        module("simd", [shim]),
        // Local notifications (`UNUserNotificationCenter`), from the
        // platform layer.
        module("UserNotifications", [platform]),
        // Compile-only checks, built with the rest by Scripts/check-android.sh:
        // game code calling GameKit in each language mode a game may use,
        // which must compile here as it does against Apple's.
        .target(name: "GameKitSwift6", dependencies: ["GameKit", "UIKit"],
                path: "Checks/GameKitSwift6", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "GameKitSwift5", dependencies: ["GameKit", "UIKit"],
                path: "Checks/GameKitSwift5", swiftSettings: [v5]),
        .target(name: "GameKitMainActor", dependencies: ["GameKit", "UIKit"],
                path: "Checks/GameKitMainActor", swiftSettings: [v5, .defaultIsolation(MainActor.self)]),
    ]
)
