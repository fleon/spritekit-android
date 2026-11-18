// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

// The platform code every SpriteKit game shares on Apple platforms and on
// Android alike: what's game-agnostic in a game's helpers and managers, so a
// fix reaches every game and no game keeps its own copy.
//
// On iPhone, iPad, Apple TV and the Mac (Catalyst) it builds against Apple's
// own SpriteKit, UIKit and services; on Android, and on a Mac host for its
// tests, against this repository's shim, which `SPRITEKIT_SHIM` selects. So a
// source file here imports
//
//     #if SPRITEKIT_SHIM
//     import SpriteKitShim
//     #else
//     import SpriteKit
//     import UIKit
//     #endif
//
// and never the module-name targets in Modules/, which collide with Apple's
// frameworks.
//
// A game adds this package to its Xcode project as a local package
// (`<submodule>/Platform`) and to its Android package by path; it reaches
// the runtime as `..`, so both resolve the one `spritekit-android` package.

// Where the shim stands in for Apple's frameworks. A native macOS build is
// the host the tests run on; the Mac app is Catalyst, which is Apple's own.
let shimPlatforms: [Platform] = [.android, .linux, .macOS]
let onShim = TargetDependencyCondition.when(platforms: shimPlatforms)
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM", .when(platforms: shimPlatforms))
let v5 = SwiftSetting.swiftLanguageMode(.v5)
// As the games compile: their own code is main-actor isolated unless it says
// otherwise, so code moved here type-checks as it did there.
let mainActor = SwiftSetting.defaultIsolation(MainActor.self)
let settings = [v5, shimDefine, mainActor]

let package = Package(
    name: "SpriteKitPlatform",
    platforms: [.iOS(.v15), .tvOS(.v15), .macCatalyst(.v15), .macOS(.v13)],
    products: [
        .library(name: "Macros", targets: ["Macros"]),
        .library(name: "PlatformCore", targets: ["PlatformCore"]),
        .library(name: "PlatformRigs", targets: ["PlatformRigs"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0"),
    ],
    targets: [
        // `@NSCodingUnsupported`, for nodes only ever made in code.
        .macro(
            name: "MacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(name: "Macros", dependencies: ["MacrosPlugin"]),
        // The shorthands and small pieces every game's code leans on:
        // geometry, timing curves and eased actions, seeded randomness.
        // `PlatformServices` (the render-scale governor, the service
        // protocols) comes with it.
        .target(
            name: "PlatformCore",
            dependencies: [
                .product(name: "PlatformServices", package: "spritekit-android"),
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        // Spine skeletons played and drawn: the runtime (`RigData`, `RigPose`,
        // spine-core 4.2 with spine-c 3.6's ways), their meshes as SpriteKit
        // draws them (`RigMeshNode`) and the node that plays one (`RigNode`).
        .target(
            name: "PlatformRigs",
            dependencies: [
                "PlatformCore",
                "Macros",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformRigsTests",
            dependencies: ["PlatformRigs"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformCoreTests",
            dependencies: ["PlatformCore"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "MacrosTests",
            dependencies: [
                "MacrosPlugin",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
