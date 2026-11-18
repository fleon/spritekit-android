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
        .library(name: "PlatformGameCenter", targets: ["PlatformGameCenter"]),
        .library(name: "PlatformStore", targets: ["PlatformStore"]),
        .library(name: "PlatformAudio", targets: ["PlatformAudio"]),
        .library(name: "PlatformInput", targets: ["PlatformInput"]),
        .library(name: "PlatformDisplay", targets: ["PlatformDisplay"]),
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
        // Focus for the Apple TV remote, gamepads and the Mac's pointer,
        // moving between a scene's controls; gamepads (GameController on
        // Apple, the shell's `GamepadEvents` on Android); the keyboard's
        // and the Menu button's scene protocols.
        .target(
            name: "PlatformInput",
            dependencies: [
                "PlatformCore",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        // The frame-rate and graphics settings, with Auto, and on Apple the
        // controller that applies them to the game's view.
        .target(
            name: "PlatformDisplay",
            dependencies: [
                "PlatformCore",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformInputTests",
            dependencies: ["PlatformInput"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformDisplayTests",
            dependencies: ["PlatformDisplay"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformCoreTests",
            dependencies: ["PlatformCore"],
            swiftSettings: settings
        ),
        // Sound effects and the soundtrack: one manager over
        // `AudioBackend`, with AVAudioEngine's backend on Apple platforms;
        // Android's shell hands the manager its own.
        .target(
            name: "PlatformAudio",
            dependencies: [
                "PlatformCore",
                .product(name: "PlatformServices", package: "spritekit-android"),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformAudioTests",
            dependencies: ["PlatformAudio"],
            swiftSettings: settings
        ),
        // Game Center: sign-in, achievements reported as they move, scores,
        // the dashboard. GameKit on Apple; Play Games (PlatformShim) on
        // Android.
        .target(
            name: "PlatformGameCenter",
            dependencies: [
                .product(name: "PlatformServices", package: "spritekit-android"),
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformGameCenterTests",
            dependencies: ["PlatformGameCenter"],
            swiftSettings: settings
        ),
        // In-app purchases: what's owned and since when, prices, buying,
        // consumables. StoreKit 2 on Apple; Play Billing (PlatformShim) on
        // Android.
        .target(
            name: "PlatformStore",
            dependencies: [
                .product(name: "PlatformServices", package: "spritekit-android"),
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformStoreTests",
            dependencies: ["PlatformStore"],
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
