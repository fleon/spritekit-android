// swift-tools-version: 6.0
import PackageDescription

// The text stack: HarfBuzz for shaping, FreeType for metrics and
// rasterising, a glyph atlas over both, and the `TextProvider` the shim asks
// for its label layout and font metrics.
//
// A package of its own, like Modules and Shell: it has C dependencies of its
// own (FreeType and HarfBuzz), and putting them in ../Package.swift would
// make `swift build` there need a cmake run first —
// for everyone working on the scene graph, the actions or the renderer, none
// of whom need text. The shim therefore never links FreeType; it calls
// whatever provider has been registered with `TextMetrics`.
//
// Build the libraries first, once:
//
//   Vendor/build.sh host        # what `swift test` here needs
//   Vendor/build.sh android     # both device ABIs
//
// then
//
//   PKG_CONFIG_PATH=../Vendor/out/host/lib/pkgconfig swift test
//
//   PKG_CONFIG_PATH=../Vendor/out/aarch64-linux-android/lib/pkgconfig \
//   swift build --swift-sdk swift-6.4.2-RELEASE_android \
//               --triple aarch64-unknown-linux-android23
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM")
let v5 = SwiftSetting.swiftLanguageMode(.v5)

let package = Package(
    name: "SpriteKitText",
    products: [
        .library(name: "TextShaping", targets: ["TextShaping"]),
        // Linking is the thing a library build never checks. See its main.swift.
        .executable(name: "TextProbe", targets: ["TextProbe"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .systemLibrary(
            name: "CTextShaping",
            path: "Sources/CTextShaping",
            pkgConfig: "spritekit-text"
        ),
        .target(
            name: "TextShaping",
            dependencies: [
                "CTextShaping",
                .product(name: "SpriteKitShim", package: "spritekit-android"),
            ],
            path: "Sources/TextShaping",
            swiftSettings: [v5, shimDefine]
        ),
        .executableTarget(
            name: "TextProbe",
            dependencies: ["TextShaping", .product(name: "SpriteKitShim", package: "spritekit-android")],
            path: "Sources/TextProbe",
            swiftSettings: [v5, shimDefine]
        ),
        .testTarget(
            name: "TextShapingTests",
            dependencies: ["TextShaping", .product(name: "SpriteKitShim", package: "spritekit-android")],
            path: "Tests/TextShapingTests",
            swiftSettings: [v5, shimDefine]
        ),
    ]
)
