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
        .library(name: "PlatformAudio", targets: ["PlatformAudio"]),
        .library(name: "PlatformInput", targets: ["PlatformInput"]),
        .library(name: "PlatformDisplay", targets: ["PlatformDisplay"]),
        .library(name: "PlatformDevice", targets: ["PlatformDevice"]),
        .library(name: "PlatformSync", targets: ["PlatformSync"]),
        .library(name: "PlatformAndroid", targets: ["PlatformAndroid"]),
        .library(name: "PlatformAndroidHost", targets: ["PlatformAndroidHost"]),
        .library(name: "PlatformSprite", targets: ["PlatformSprite"]),
        .library(name: "PlatformGameCenter", targets: ["PlatformGameCenter"]),
        .library(name: "PlatformStore", targets: ["PlatformStore"]),
        .library(name: "PlatformShare", targets: ["PlatformShare"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0"),
    ],
    targets: [
        // `@NSCodingUnsupported`, for nodes only ever made in code, and
        // `@Stored`, `@Synced` and `@SyncedKeys`, for saved values.
        .macro(
            name: "MacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Macros",
            dependencies: [
                "MacrosPlugin",
                .product(name: "PlatformServices", package: "spritekit-android"),
            ]
        ),
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
        // Spine skeletons played and drawn: the runtime (`RigData`,
        // `RigPose`, spine-core 4.2), their meshes as SpriteKit draws them
        // (`RigMeshNode`) and the node that plays one (`RigNode`).
        .target(
            name: "PlatformRigs",
            dependencies: [
                "PlatformCore",
                "Macros",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            exclude: ["LICENSE"],
            swiftSettings: settings
        ),
        // Focus for the Apple TV remote, gamepads and the Mac's pointer,
        // moving between a scene's controls; gamepads (GameController on
        // Apple, the shell's `GamepadEvents` on Android); the keyboard's
        // and the Menu button's scene protocols; the pressable control base.
        .target(
            name: "PlatformInput",
            dependencies: [
                "PlatformCore",
                "Macros",
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
            name: "PlatformRigsTests",
            dependencies: ["PlatformRigs"],
            resources: [.copy("Fixtures")],
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
            dependencies: ["PlatformCore", "Macros"],
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
            dependencies: ["PlatformSync", "Macros"],
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
        // What a game's Android controller stands on: the view, window and
        // screen laid out as the shell reports them (`GameHostSurface`),
        // `GameHost`'s common members (`AndroidGameHost`) and the toolkit's
        // managers handed to Play (`AndroidPlatformServices.Configuration
        // .toolkit`). All `SPRITEKIT_SHIM`, and its dependencies only on the
        // shim, so Apple builds compile it empty.
        .target(
            name: "PlatformAndroidHost",
            dependencies: [
                .target(name: "PlatformAndroid", condition: onShim),
                .target(name: "PlatformAudio", condition: onShim),
                .target(name: "PlatformDisplay", condition: onShim),
                .target(name: "PlatformSprite", condition: onShim),
                .target(name: "PlatformGameCenter", condition: onShim),
                .target(name: "PlatformStore", condition: onShim),
                .target(name: "PlatformSync", condition: onShim),
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformAndroidHostTests",
            dependencies: [
                "PlatformAndroidHost",
                "PlatformAndroid",
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        // The SpriteKit infrastructure no game's content is in: the texture
        // cache and sprite helpers, colours, text and fonts, SVG paths and
        // icons drawn from them, shape sprites, scene loading, the
        // localization mechanism, debug markers and the display's corners.
        // Every game-specific piece (art scale, slice table, icon table,
        // languages, fonts) is passed in.
        .target(
            name: "PlatformSprite",
            dependencies: [
                "PlatformCore",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformSpriteTests",
            dependencies: [
                "PlatformSprite",
                "Macros",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        // Game Center: sign-in, achievements reported as they move, scores,
        // the dashboard. GameKit on Apple; Play Games (PlatformShim) on
        // Android.
        .target(
            name: "PlatformGameCenter",
            dependencies: [
                "PlatformSprite",
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
        // The system's share sheet and pasteboard, the store's review page
        // and a feedback mail: UIKit's on Apple, the shell's on Android.
        .target(
            name: "PlatformShare",
            dependencies: [
                "PlatformSprite",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformShareTests",
            dependencies: [
                "PlatformShare",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
                .product(name: "PlatformShim", package: "spritekit-android", condition: onShim),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "PlatformStoreTests",
            dependencies: ["PlatformStore"],
            swiftSettings: settings
        ),
        // Expanded by the compiler, under the games' settings.
        .testTarget(
            name: "MacrosUsageTests",
            dependencies: [
                "Macros",
                .product(name: "SpriteKitShim", package: "spritekit-android", condition: onShim),
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
