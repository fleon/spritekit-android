// swift-tools-version: 6.2
import PackageDescription

// Android-only. Do not build this package on a Mac: the runtime's module-name
// targets (CoreGraphics, UIKit, …) cycle with the real modules there.
//
// GAME_NAME on SpriteKit for Android (the submodule at ../spritekit-android):
// its own sources compiled unmodified against the runtime
// (Sources/GameCompat/Source links the repository's Source/ folder) over the
// shared platform code (../spritekit-android/Platform), its controller, and
// its entry, whose `AndroidShell` product is the library the APK loads.
//
//   ../spritekit-android/Scripts/build-shell.sh --debug arm64-v8a
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM")
let v5 = SwiftSetting.swiftLanguageMode(.v5)

// The app target's own concurrency settings (its Xcode project): Swift 5,
// main-actor isolation by default and Approachable Concurrency.
let gameSettings: [SwiftSetting] = [
    v5, shimDefine,
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "GAME_MODULEGame",
    products: [
        .library(name: "GameCompat", targets: ["GameCompat"]),
        // The shared library the APK loads: the runtime's shell with the
        // game in it. SDL's `nativeRunMain` dlopens it by this name and looks
        // up `SDL_main`, which the entry exports.
        .library(name: "AndroidShell", type: .dynamic, targets: ["GAME_MODULEEntry"]),
    ],
    dependencies: [
        .package(path: "../spritekit-android"),
        .package(path: "../spritekit-android/Modules"),
        .package(path: "../spritekit-android/Shell"),
        .package(path: "../spritekit-android/Platform"),
    ],
    targets: [
        // The game's sources and its controller. Keep the products it
        // imports; drop the rest.
        .target(
            name: "GameCompat",
            dependencies: [
                .product(name: "SpriteKitShim", package: "spritekit-android"),
                .product(name: "PlatformShim", package: "spritekit-android"),
                .product(name: "Macros", package: "Platform"),
                .product(name: "PlatformCore", package: "Platform"),
                .product(name: "PlatformSprite", package: "Platform"),
                .product(name: "PlatformAudio", package: "Platform"),
                .product(name: "PlatformDevice", package: "Platform"),
                .product(name: "PlatformDisplay", package: "Platform"),
                .product(name: "PlatformGameCenter", package: "Platform"),
                .product(name: "PlatformStore", package: "Platform"),
                .product(name: "PlatformSync", package: "Platform"),
                .product(name: "PlatformAndroid", package: "Platform"),
                .product(name: "PlatformAndroidHost", package: "Platform"),
                .product(name: "SpriteKit", package: "Modules"),
                .product(name: "UIKit", package: "Modules"),
                .product(name: "CoreText", package: "Modules"),
                .product(name: "CoreGraphics", package: "Modules"),
                .product(name: "CoreImage", package: "Modules"),
                .product(name: "AVFoundation", package: "Modules"),
                .product(name: "StoreKit", package: "Modules"),
                .product(name: "GameKit", package: "Modules"),
                .product(name: "simd", package: "Modules"),
            ],
            path: "Sources/GameCompat",
            // `Source` links the game's whole Source/ folder, so files the
            // Apple build adds come along. Left out: the Apple app's entry,
            // which `Android/AndroidGameController.swift` stands in for.
            exclude: [
                "Source/AppDelegate.swift",
                "Source/SceneDelegate.swift",
                "Source/GameViewController.swift",
            ],
            swiftSettings: gameSettings
        ),

        // Where the runtime and the game meet: `SDL_main`, handing the
        // shell `AndroidGameController` as its `GameHost`.
        .target(
            name: "GAME_MODULEEntry",
            dependencies: [
                "GameCompat",
                .product(name: "AndroidShellKit", package: "Shell"),
                .product(name: "SpriteKitShim", package: "spritekit-android"),
                .product(name: "PlatformAndroidHost", package: "Platform"),
            ],
            path: "Sources/GAME_MODULEEntry",
            swiftSettings: gameSettings
        ),
    ]
)
