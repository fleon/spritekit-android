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
//
// The targets, and why there are four:
//
//   CAndroidShell  the C the clang importer cannot reach on its own.
//   CSwitchlingsAudio  the AAC decoder, over Android's MediaCodec.
//   SDLAudio       the audio backend: SDL3 for output and sound effects,
//                  the decoder above for the soundtrack.
//   CZlib          Android's own zlib, for inflating the art's PNGs.
//   ShellCore      the seam: FrameRenderer, Frame, RenderContext, Log.
//                  Its own target so the shell and the renderer can both
//                  use it without depending on each other.
//   GLESBackend    every GL call in the port, plus the asset loading and
//                  PNG decoding that feed it. It links TextShaping, so a
//                  shell build needs PKG_CONFIG_PATH pointing at the
//                  Vendor prefix for the ABI — Scripts/build-shell.sh
//                  sets it.
//   AndroidShell   the window, the context, the lifecycle and the frame
//                  loop. It depends on GLESBackend only to install it;
//                  nothing in the shell knows what a sprite is.
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
        // The glyph atlas. Only GLESBackend links it, and only to upload
        // what it rasterises; nothing else in the shell knows about text.
        .package(path: "../Text"),
        // The game's own sources, compiled for Android (symlinks into
        // Source/, never copies). The shell links it so the port can start
        // drawing the real thing rather than stand-ins: the rigs first.
        .package(path: "../Compat"),
    ],
    targets: [
        .target(name: "CAndroidShell", path: "Sources/CAndroidShell"),
        .target(name: "CSwitchlingsAudio", path: "Sources/CSwitchlingsAudio"),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),

        .target(
            name: "ShellCore",
            dependencies: [
                "CAndroidShell",
                .product(name: "SpriteKitShim", package: "Android"),
            ],
            path: "Sources/ShellCore",
            swiftSettings: [v5, shimDefine]
        ),

        .target(
            name: "SDLAudio",
            dependencies: [
                "CAndroidShell",
                "CSwitchlingsAudio",
                "ShellCore",
                .product(name: "PlatformShim", package: "Android"),
            ],
            path: "Sources/SDLAudio",
            swiftSettings: [v5, shimDefine]
        ),

        .target(
            name: "GLESBackend",
            dependencies: [
                "CAndroidShell",
                "CZlib",
                "ShellCore",
                .product(name: "SpriteKitShim", package: "Android"),
                .product(name: "GLESRenderer", package: "Android"),
                .product(name: "TextShaping", package: "Text"),
                .product(name: "GameCompat", package: "Compat"),
            ],
            path: "Sources/GLESBackend",
            swiftSettings: [v5, shimDefine]
        ),

        .target(
            name: "AndroidShell",
            dependencies: [
                "CAndroidShell",
                "ShellCore",
                "GLESBackend",
                "SDLAudio",
                .product(name: "SpriteKitShim", package: "Android"),
            ],
            path: "Sources/AndroidShell",
            swiftSettings: [v5, shimDefine],
            // Named here rather than as `-Xlinker -l…` on the build's
            // command line, which would reach the host macro plugin's link
            // too — see Scripts/build-shell.sh. The search path for them is
            // still a flag, since it is different per ABI.
            linkerSettings: [
                .linkedLibrary("SDL3"),
                .linkedLibrary("GLESv3"),
                .linkedLibrary("log"),
                // Android's own media stack, for decoding the soundtrack's AAC.
                .linkedLibrary("mediandk"),
            ]
        ),
    ]
)
