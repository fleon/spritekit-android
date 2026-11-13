// swift-tools-version: 6.0
import PackageDescription

// Android-only, like Compat/. Do not build this package on a Mac: it reaches
// SDL3 and GLES headers that only exist in the Android sysroot and in the
// cross-compiled SDL prefix.
//
// It is a package of its own rather than a target in ../Package.swift so that
// the shim there keeps building and testing on the host, which is how that
// layer is developed. The dependency on SpriteKitShim is by path — the shim
// is used, never copied.
//
//   Scripts/build-shell.sh
//
// which expands to, per ABI:
//
//   swift build --package-path Shell \
//     --swift-sdk swift-6.4.2-RELEASE_android \
//     --triple aarch64-unknown-linux-android23 \
//     -Xcc -I<sdl prefix>/include \
//     -Xlinker -L<sdl prefix>/lib -Xlinker -lSDL3 \
//     -Xlinker -lGLESv3 -Xlinker -llog
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM")
let v5 = SwiftSetting.swiftLanguageMode(.v5)

let package = Package(
    name: "SwitchlingsShell",
    products: [
        // The shared library the APK loads. SDL's `nativeRunMain` dlopens it
        // by this name and looks up `SDL_main`.
        .library(name: "AndroidShell", type: .dynamic, targets: ["AndroidShell"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .target(name: "CAndroidShell", path: "Sources/CAndroidShell"),
        .target(
            name: "AndroidShell",
            dependencies: [
                "CAndroidShell",
                .product(name: "SpriteKitShim", package: "Android"),
            ],
            path: "Sources/AndroidShell",
            swiftSettings: [v5, shimDefine]
        ),
    ]
)
