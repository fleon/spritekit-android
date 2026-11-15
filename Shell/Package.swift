// swift-tools-version: 6.2
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
//     -Xlinker -L<sdl prefix>/lib
//
// The libraries themselves are AndroidShell's `linkerSettings`, not flags:
// a `-Xlinker -lSDL3` would reach the Macros plugin's own host link too.
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
//                  PNG decoding that feed it, and the scene it draws. It
//                  links TextShaping, so a shell build needs
//                  PKG_CONFIG_PATH pointing at the Vendor prefix for the
//                  ABI — Scripts/build-shell.sh sets it — and it is the
//                  one target that depends on Compat's GameCompat, the
//                  game's own sources.
//   AndroidShell   the window, the context, the lifecycle and the frame
//                  loop. It depends on GLESBackend only to install it;
//                  nothing in the shell knows what a sprite is.
let shimDefine = SwiftSetting.define("SPRITEKIT_SHIM")
let v5 = SwiftSetting.swiftLanguageMode(.v5)
// The frame loop, the renderer and the game share one thread, which is the
// main actor's (`MainActorJobs`, `MainThread`): SpriteKit's nodes are main-
// actor isolated, as on Apple, so the code that drives them is too. Not
// SDLAudio, whose callbacks run on SDL's audio thread.
let mainActor = SwiftSetting.defaultIsolation(MainActor.self)

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
        // Source/, never copies). The shell links it so the port draws the
        // real thing rather than stand-ins: the rigs, the levels and the
        // board that play them, and Starry Sky's backdrop. Only GLESBackend
        // depends on it — the shell proper still knows nothing about any of it.
        .package(path: "../Compat"),
    ],
    targets: [
        .target(name: "CAndroidShell", path: "Sources/CAndroidShell"),
        .target(name: "CSwitchlingsAudio", path: "Sources/CSwitchlingsAudio"),
        .target(name: "CSwitchlingsMedia", path: "Sources/CSwitchlingsMedia"),
        // A share film's encoding, over MediaCodec and MediaMuxer: the
        // device half of PlatformShim's AVFoundation stand-ins.
        .target(
            name: "FilmMedia",
            dependencies: [
                "CSwitchlingsAudio",
                "CSwitchlingsMedia",
                .product(name: "PlatformShim", package: "Android"),
            ],
            path: "Sources/FilmMedia",
            swiftSettings: [v5, shimDefine]
        ),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),

        .target(
            name: "ShellCore",
            dependencies: [
                "CAndroidShell",
                .product(name: "SpriteKitShim", package: "Android"),
            ],
            path: "Sources/ShellCore",
            swiftSettings: [v5, shimDefine, mainActor]
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
            swiftSettings: [v5, shimDefine, mainActor]
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
                .product(name: "PlatformShim", package: "Android"),
            ],
            path: "Sources/GLESBackend",
            swiftSettings: [v5, shimDefine, mainActor]
        ),

        .target(
            name: "AndroidShell",
            dependencies: [
                "CAndroidShell",
                "ShellCore",
                "GLESBackend",
                "SDLAudio",
                "FilmMedia",
                .product(name: "SpriteKitShim", package: "Android"),
            ],
            path: "Sources/AndroidShell",
            swiftSettings: [v5, shimDefine],
            // Named here rather than as `-Xlinker -l…` on the build's
            // command line, which would reach the host macro plugin's link
            // too — see Scripts/build-shell.sh. The search path for them is
            // still a flag, since it is different per ABI.
            linkerSettings: [
                .linkedLibrary("SDL3", .when(platforms: [.android])),
                .linkedLibrary("GLESv3", .when(platforms: [.android])),
                // A second context sharing the frame thread's, for building
                // programs on a thread of their own (`GLBuilderThread`).
                .linkedLibrary("EGL", .when(platforms: [.android])),
                .linkedLibrary("log", .when(platforms: [.android])),
                // The looper the vsync callbacks arrive on and the window's
                // buffer size (`VsyncPacer`, `SurfaceScaler`).
                .linkedLibrary("android", .when(platforms: [.android])),
                // Android's own media stack, for decoding the soundtrack's AAC.
                .linkedLibrary("mediandk", .when(platforms: [.android])),
                // The main queue's drain, which the frame loop calls
                // (`switchlings_drain_main_queue`).
                .linkedLibrary("dispatch", .when(platforms: [.android])),
            ]
        ),
    ]
)
