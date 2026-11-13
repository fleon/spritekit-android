// swift-tools-version: 6.0
import PackageDescription

// Android-only. Do not build this package on a Mac: it declares targets named
// CoreGraphics and UIKit, which exist to take those module names where the
// system has none. On macOS they cycle with the real modules.
//
// What this package is for: compiling the game's own presentation sources,
// unmodified, against the shim. GameCompat's files are symlinks into Source/,
// so a build here is a test of the real code rather than of a copy.
//
//   swift build --swift-sdk swift-6.4.2-RELEASE_android \
//               --triple aarch64-unknown-linux-android23
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM")
let v5 = SwiftSetting.swiftLanguageMode(.v5)

let package = Package(
    name: "SwitchlingsCompat",
    products: [
        .library(name: "GameCompat", targets: ["GameCompat"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(path: "../../Macros"),
    ],
    targets: [
        // Each of these exists only to own a module name the game imports.
        .target(name: "SpriteKit",
                dependencies: [.product(name: "SpriteKitShim", package: "Android"), "simd"],
                path: "Sources/SpriteKit", swiftSettings: [v5, shimDefine]),
        .target(name: "UIKit",
                dependencies: [.product(name: "SpriteKitShim", package: "Android"), "simd"],
                path: "Sources/UIKit", swiftSettings: [v5, shimDefine]),
        .target(name: "CoreText",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/CoreText", swiftSettings: [v5, shimDefine]),
        .target(name: "CoreGraphics",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/CoreGraphics", swiftSettings: [v5, shimDefine]),
        .target(name: "QuartzCore",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/QuartzCore", swiftSettings: [v5, shimDefine]),
        .target(name: "os",
                path: "Sources/os", swiftSettings: [v5, shimDefine]),
        // Not a passthrough: Android has no Accelerate, so this one has the
        // free-function spelling of the SIMD maths in it. It also re-exports
        // the shim, whose matrix types `SKUniform` takes.
        .target(name: "simd",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/simd", swiftSettings: [v5, shimDefine]),

        .target(
            name: "GameCompat",
            dependencies: [
                .product(name: "SpriteKitShim", package: "Android"),
                .product(name: "PlatformShim", package: "Android"),
                .product(name: "Macros", package: "Macros"),
                "SpriteKit", "UIKit", "CoreText", "CoreGraphics", "QuartzCore", "os", "simd",
            ],
            path: "Sources/GameCompat",
            swiftSettings: [v5, shimDefine]
        ),
    ]
)
