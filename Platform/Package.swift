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
        .library(name: "PlatformDevice", targets: ["PlatformDevice"]),
        .library(name: "PlatformSync", targets: ["PlatformSync"]),
        .library(name: "PlatformAndroid", targets: ["PlatformAndroid"]),
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
        .testTarget(
            name: "PlatformCoreTests",
            dependencies: ["PlatformCore"],
            swiftSettings: settings
        ),
        // Haptic feedback and its switch, rating prompts and the play time
        // they may wait for.
        .target(
            name: "PlatformDevice",
            dependencies: [
                .product(name: "PlatformServices", package: "spritekit-android"),
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformDeviceTests",
            dependencies: ["PlatformDevice"],
            swiftSettings: settings
        ),
        // Saved data kept the same on the player's devices: the sync
        // manager over `SyncEngine`, and iCloud's key-value store as its
        // cloud on Apple platforms.
        .target(
            name: "PlatformSync",
            dependencies: [
                .product(name: "PlatformServices", package: "spritekit-android"),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformSyncTests",
            dependencies: ["PlatformSync"],
            swiftSettings: settings
        ),
        // Android's wiring: Play Games, Play Billing, Saved Games and the
        // device, handed to the receivers a game names. Its sources are
        // all `SPRITEKIT_SHIM`, so Apple builds compile it empty.
        .target(
            name: "PlatformAndroid",
            dependencies: [
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformAndroidTests",
            dependencies: [
                "PlatformAndroid",
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
            ],
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
