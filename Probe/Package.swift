// swift-tools-version: 6.0
import PackageDescription

// Android-only, and a package of its own because it is the only thing that
// needs both of the others: Compat (the game's own sources against the shim)
// and Text (FreeType and HarfBuzz). Keeping it apart means `swift build` in
// Compat still needs no cmake run, which is what everyone else building the
// game's sources wants.
//
// What it is for: running the game's own text layout on a device. See
// Sources/GameProbe/main.swift, and run-probe.sh beside it.
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM")
let v5 = SwiftSetting.swiftLanguageMode(.v5)

let package = Package(
    name: "SwitchlingsProbe",
    products: [
        .executable(name: "GameProbe", targets: ["GameProbe"]),
    ],
    dependencies: [
        .package(path: "../Compat"),
        .package(path: "../Text"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "GameProbe",
            dependencies: [
                .product(name: "GameCompat", package: "Compat"),
                .product(name: "TextShaping", package: "Text"),
                .product(name: "SpriteKitShim", package: "Android"),
            ],
            path: "Sources/GameProbe",
            swiftSettings: [v5, shimDefine]
        ),
    ]
)
