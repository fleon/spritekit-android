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
        .library(name: "GameKit", targets: ["GameKit"]),
        .library(name: "Network", targets: ["Network"]),
        .library(name: "Metal", targets: ["Metal"]),
        .library(name: "CoreVideo", targets: ["CoreVideo"]),
        .library(name: "AVFoundation", targets: ["AVFoundation"]),
        .library(name: "os", targets: ["os"]),
        .library(name: "simd", targets: ["simd"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .target(name: "SpriteKit",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android"), "simd"],
                path: "Sources/SpriteKit", swiftSettings: [v5, shimDefine]),
        .target(name: "UIKit",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android"), "simd"],
                path: "Sources/UIKit", swiftSettings: [v5, shimDefine]),
        .target(name: "CoreText",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android")],
                path: "Sources/CoreText", swiftSettings: [v5, shimDefine]),
        .target(name: "CoreGraphics",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android")],
                path: "Sources/CoreGraphics", swiftSettings: [v5, shimDefine]),
        .target(name: "CoreImage",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android")],
                path: "Sources/CoreImage", swiftSettings: [v5, shimDefine]),
        .target(name: "QuartzCore",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android")],
                path: "Sources/QuartzCore", swiftSettings: [v5, shimDefine]),
        .target(name: "StoreKit",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android"), .product(name: "PlatformShim", package: "spritekit-android")],
                path: "Sources/StoreKit", swiftSettings: [v5, shimDefine]),
        .target(name: "CryptoKit",
                dependencies: [.product(name: "PlatformShim", package: "spritekit-android")],
                path: "Sources/CryptoKit", swiftSettings: [v5, shimDefine]),
        // Two a game may import to describe the player and the network.
        .target(name: "GameKit",
                path: "Sources/GameKit", swiftSettings: [v5, shimDefine]),
        .target(name: "Network",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android")],
                path: "Sources/Network", swiftSettings: [v5, shimDefine]),
        // The three a game writing video and audio files imports.
        .target(name: "Metal",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android")],
                path: "Sources/Metal", swiftSettings: [v5, shimDefine]),
        .target(name: "CoreVideo",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android")],
                path: "Sources/CoreVideo", swiftSettings: [v5, shimDefine]),
        .target(name: "AVFoundation",
                dependencies: [
                    .product(name: "SpriteKitShim", package: "spritekit-android"),
                    .product(name: "PlatformShim", package: "spritekit-android"),
                ],
                path: "Sources/AVFoundation", swiftSettings: [v5, shimDefine]),
        .target(name: "os",
                path: "Sources/os", swiftSettings: [v5, shimDefine]),
        // Not a passthrough: Android has no Accelerate, so this one has the
        // free-function spelling of the SIMD maths in it. It also re-exports
        // the shim, whose matrix types `SKUniform` takes.
        .target(name: "simd",
                dependencies: [.product(name: "SpriteKitShim", package: "spritekit-android")],
                path: "Sources/simd", swiftSettings: [v5, shimDefine]),
    ]
)
