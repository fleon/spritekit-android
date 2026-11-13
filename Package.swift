// swift-tools-version: 6.0
import PackageDescription

// The Android port's SpriteKit compatibility layer.
//
// On Apple platforms SpriteKitShim is a no-op that re-exports the real
// SpriteKit, so the game's presentation code compiles unchanged on both
// sides. On Android it provides its own implementation of the SpriteKit
// surface the game actually uses.
//
// This package builds and tests on macOS as well as cross-compiling, so the
// layer can be developed with a normal edit-test loop rather than only on a
// device. The module-name shims (SpriteKit, UIKit, CoreGraphics, CoreText)
// live in Compat/ instead, because a target named CoreGraphics cycles with
// the system module when the package is built on a Mac.
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM")
let v5 = SwiftSetting.swiftLanguageMode(.v5)

let package = Package(
    name: "SwitchlingsAndroid",
    products: [
        .library(name: "SpriteKitShim", targets: ["SpriteKitShim"]),
        .library(name: "GLESRenderer", targets: ["GLESRenderer"]),
    ],
    targets: [
        .target(
            name: "SpriteKitShim",
            path: "Sources/SpriteKitShim",
            swiftSettings: [v5, shimDefine]
        ),
        // The renderer that consumes a DrawList. Its pure parts — shader
        // translation, batching decisions — build and test on the Mac; the
        // GL calls themselves are Android-only and come behind them.
        .target(
            name: "GLESRenderer",
            dependencies: ["SpriteKitShim"],
            path: "Sources/GLESRenderer",
            swiftSettings: [v5, shimDefine]
        ),
        .testTarget(
            name: "SpriteKitShimTests",
            dependencies: ["SpriteKitShim"],
            path: "Tests/SpriteKitShimTests",
            swiftSettings: [v5, shimDefine]
        ),
        .testTarget(
            name: "GLESRendererTests",
            dependencies: ["GLESRenderer"],
            path: "Tests/GLESRendererTests",
            swiftSettings: [v5, shimDefine]
        ),
    ]
)
