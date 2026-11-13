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
        .library(name: "PlatformShim", targets: ["PlatformShim"]),
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
        // The platform ring: the Android stand-ins for the Apple services
        // the game's managers sit on — AVFoundation, iCloud's key-value
        // store, StoreKit and GameKit. Only the parts with no device in
        // them live here, which is most of each: the merge saved data
        // depends on, what the full game being owned means, which
        // achievements have moved. The device half (SDL audio, a Play
        // service) is behind a protocol each, so this whole target builds
        // and tests on the Mac.
        // The AVFoundation stand-ins share films are written through take
        // the shim's CoreVideo pixel buffers, hence the dependency.
        .target(
            name: "PlatformShim",
            dependencies: ["SpriteKitShim"],
            path: "Sources/PlatformShim",
            swiftSettings: [v5, shimDefine]
        ),
        .testTarget(
            name: "PlatformShimTests",
            dependencies: ["PlatformShim", "SpriteKitShim"],
            path: "Tests/PlatformShimTests",
            swiftSettings: [v5, shimDefine]
        ),
        .testTarget(
            name: "SpriteKitShimTests",
            dependencies: ["SpriteKitShim"],
            path: "Tests/SpriteKitShimTests",
            swiftSettings: [v5, shimDefine]
        ),
        // The rig runtime, run against the real rigs in Assets/Rigs.
        //
        // RigData.swift and RigPose.swift are symlinked in rather than
        // depended on: they are pure Foundation and CoreGraphics, so on the
        // host they compile against the system's own and need neither the
        // shim nor a device. A test target is also the one place a game
        // source can live in this package without the Android build trying
        // to compile it — `swift build` does not build test targets, and
        // `import CoreGraphics` has nothing to resolve to there. The real
        // Android build of these two files is Compat/.
        .testTarget(
            name: "RigRuntimeTests",
            path: "Tests/RigRuntimeTests",
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
