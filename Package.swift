// swift-tools-version: 6.2
import PackageDescription

// SpriteKit for Android: the scene graph, the renderer's GL-free half and the
// platform layer.
//
// On Apple platforms SpriteKitShim is a no-op that re-exports the real
// SpriteKit, CoreGraphics and UIKit, so code that builds on both sides (the
// toolkit in Platform/) imports it alone. On Android, and on a Mac host for
// the tests, it provides its own implementation of the SpriteKit surface the
// games use, which `SPRITEKIT_SHIM` selects.
//
// This package builds and tests on macOS as well as cross-compiling, so the
// layer can be developed with a normal edit-test loop rather than only on a
// device. The module-name targets (SpriteKit, UIKit, CoreGraphics, …) live in
// Modules/ instead, because a target named CoreGraphics cycles with the
// system module when the package is built on a Mac; the shell (Shell/) and
// the text stack (Text/) are packages of their own for the reasons in their
// manifests.
//
// A game depends on these packages by path, with this repository checked
// out as a submodule named `spritekit-android` (a package's identity is its
// directory's name, so the name matters: manifests here refer to this
// package as "spritekit-android").
// Where the shim stands in for Apple's frameworks, as in Platform/: a native
// macOS build is the host the tests run on; iPhone, iPad, Apple TV and the
// Mac app (Catalyst) build the passthrough.
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM", .when(platforms: [.android, .linux, .macOS]))
let v5 = SwiftSetting.swiftLanguageMode(.v5)
// SpriteKit's nodes and UIKit's views are main-actor isolated, as on Apple
// (they descend from `UIResponder`), so the tests that build scenes run on
// the main actor too.
let testIsolation = SwiftSetting.defaultIsolation(MainActor.self)

let package = Package(
    name: "SpriteKitAndroid",
    products: [
        .library(name: "SpriteKitShim", targets: ["SpriteKitShim"]),
        .library(name: "GLESRenderer", targets: ["GLESRenderer"]),
        .library(name: "PlatformShim", targets: ["PlatformShim"]),
        .library(name: "PlatformServices", targets: ["PlatformServices"]),
    ],
    targets: [
        // What a game's services stand on, on every platform: the
        // protocols its audio, achievements, purchases and saved data sit
        // on, the merge synced saved data uses, and the render-scale
        // governor. Plain Foundation, with no shim in it, so Apple builds
        // (through Platform/) share it as Android's do.
        .target(
            name: "PlatformServices",
            path: "Sources/PlatformServices",
            swiftSettings: [v5]
        ),
        .target(
            name: "SpriteKitShim",
            dependencies: ["PlatformServices"],
            path: "Sources/SpriteKitShim",
            swiftSettings: [v5, shimDefine]
        ),
        // The renderer that consumes a DrawList. Its pure parts — shader
        // translation, batching decisions — build and test on the Mac; the
        // GL calls themselves are Android-only and come behind them.
        // PNG's row filters undone in C, so a debug build doesn't spend
        // seconds an image in unoptimised Swift (`PNGRows`).
        .target(name: "CPixelRows", path: "Sources/CPixelRows"),
        .target(
            name: "GLESRenderer",
            dependencies: ["SpriteKitShim", "PlatformServices", "CPixelRows"],
            path: "Sources/GLESRenderer",
            swiftSettings: [v5, shimDefine]
        ),
        // The platform layer: the Android stand-ins for the Apple services a
        // game's managers sit on — AVFoundation, iCloud's key-value store,
        // StoreKit and GameKit. Only the parts with no device in them live
        // here, which is most of each: the merge saved data depends on,
        // purchases and their acknowledgement, which achievements have
        // moved. The device half (SDL audio, a Play service) is behind a
        // protocol each, so this whole target builds and tests on the Mac.
        // The AVFoundation stand-ins videos are written through take
        // the shim's CoreVideo pixel buffers, hence the dependency.
        .target(
            name: "PlatformShim",
            dependencies: ["SpriteKitShim", "PlatformServices"],
            path: "Sources/PlatformShim",
            swiftSettings: [v5, shimDefine]
        ),
        // What the host tests share (scratch defaults, `near`); no product.
        .target(
            name: "RuntimeTestSupport",
            path: "Tests/RuntimeTestSupport",
            swiftSettings: [v5]
        ),
        .testTarget(
            name: "PlatformShimTests",
            dependencies: ["PlatformShim", "SpriteKitShim", "RuntimeTestSupport"],
            path: "Tests/PlatformShimTests",
            swiftSettings: [v5, shimDefine, testIsolation]
        ),
        .testTarget(
            name: "SpriteKitShimTests",
            dependencies: ["SpriteKitShim", "RuntimeTestSupport"],
            path: "Tests/SpriteKitShimTests",
            swiftSettings: [v5, shimDefine, testIsolation]
        ),
        .testTarget(
            name: "GLESRendererTests",
            dependencies: ["GLESRenderer", "RuntimeTestSupport"],
            path: "Tests/GLESRendererTests",
            swiftSettings: [v5, shimDefine, testIsolation]
        ),
    ]
)
