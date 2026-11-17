// swift-tools-version: 6.2
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

// The app target's own concurrency settings (Switchlings.xcodeproj): Swift 5,
// main-actor isolation by default and Approachable Concurrency. The game's
// files are written against these — a scene calls `SettingsFlow` (explicitly
// `@MainActor`) from its own methods, which only holds if the scene is
// main-actor isolated too — so they compile here under the same ones. The
// app's member import visibility is left out: it only adds strictness, and
// here Foundation's members (`isLowPowerModeEnabled`) come from the shim.
let gameSettings: [SwiftSetting] = [
    v5, shimDefine,
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    // On x86_64, corelibs' `CGFloat` takes a `Float80` too, and one of the
    // game's longer `CGFloat` expressions (`MechanicSampleNode.opaqueBounds`)
    // then runs past the type checker's default scope limit. arm64 is fine.
    .unsafeFlags(["-Xfrontend", "-solver-scope-threshold=10000000"]),
]

let package = Package(
    name: "SwitchlingsCompat",
    products: [
        .library(name: "GameCompat", targets: ["GameCompat"]),
        // The shared library the APK loads: the runtime's shell with
        // Switchlings in it. SDL's `nativeRunMain` dlopens it by this name
        // and looks up `SDL_main`, which `SwitchlingsEntry` exports.
        .library(name: "AndroidShell", type: .dynamic, targets: ["SwitchlingsEntry"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(path: "../Shell"),
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
        .target(name: "CoreImage",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/CoreImage", swiftSettings: [v5, shimDefine]),
        .target(name: "QuartzCore",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/QuartzCore", swiftSettings: [v5, shimDefine]),
        .target(name: "StoreKit",
                dependencies: [.product(name: "SpriteKitShim", package: "Android"), .product(name: "PlatformShim", package: "Android")],
                path: "Sources/StoreKit", swiftSettings: [v5, shimDefine]),
        .target(name: "CryptoKit",
                dependencies: [.product(name: "PlatformShim", package: "Android")],
                path: "Sources/CryptoKit", swiftSettings: [v5, shimDefine]),
        // The beta's solve log's two (`PlaytestLog`).
        .target(name: "GameKit",
                path: "Sources/GameKit", swiftSettings: [v5, shimDefine]),
        .target(name: "Network",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/Network", swiftSettings: [v5, shimDefine]),
        // The share film's three (`SolutionFilm`, `FilmSoundtrack`).
        .target(name: "Metal",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/Metal", swiftSettings: [v5, shimDefine]),
        .target(name: "CoreVideo",
                dependencies: [.product(name: "SpriteKitShim", package: "Android")],
                path: "Sources/CoreVideo", swiftSettings: [v5, shimDefine]),
        .target(name: "AVFoundation",
                dependencies: [
                    .product(name: "SpriteKitShim", package: "Android"),
                    .product(name: "PlatformShim", package: "Android"),
                ],
                path: "Sources/AVFoundation", swiftSettings: [v5, shimDefine]),
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
                .product(name: "SwitchlingsStore", package: "Android"),
                .product(name: "Macros", package: "Macros"),
                "SpriteKit", "UIKit", "CoreText", "CoreGraphics", "CoreImage", "QuartzCore", "os", "simd",
                "Metal", "CoreVideo", "AVFoundation", "StoreKit", "CryptoKit", "GameKit", "Network",
            ],
            path: "Sources/GameCompat",
            swiftSettings: gameSettings
        ),

        // Where the runtime and the game meet: `SDL_main`, handing the
        // shell `AndroidGameController` as its `GameHost`.
        .target(
            name: "SwitchlingsEntry",
            dependencies: [
                "GameCompat",
                .product(name: "AndroidShellKit", package: "Shell"),
                .product(name: "SpriteKitShim", package: "Android"),
            ],
            path: "Sources/SwitchlingsEntry",
            swiftSettings: gameSettings
        ),
    ]
)
