import CoreGraphics
import Foundation

// The rig runtime, tested on the host against the real rigs.
//
// `RigData.swift` and `RigPose.swift` are symlinked into this target, not
// copied, so these run against the same bytes the game ships — and against
// the same bytes the Android build compiles. Both files are pure Foundation
// and CoreGraphics: no SpriteKit, no GL, no device. `RigMeshNode`,
// `RigNode` and `LedGlowNode` are not here, because they are SpriteKit and
// their proof is the Android build plus what draws on screen.
//
// `BundleResources.swift` is symlinked in from the shim as well, which is
// what lets `RigData.named(_:)` run at all here: it asks `Bundle.main` for
// `RigGardenA.json`, and on the host — as on Android — the main bundle has
// no such thing. The shim's `Bundle` overload is in this module, so it is in
// scope in `RigData.swift` without that file importing anything, exactly as
// the `CoreGraphics` module-name target puts it in scope on Android. So
// these tests also prove the overload wins: if Swift ever stopped preferring
// it, `named(_:)` would answer nil here and every test would fail.
enum RigFixture {
    /// `Assets/Rigs` in the checkout this file belongs to.
    static let directory: URL = {
        // …/Android/Tests/RigRuntimeTests/RigFixture.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Assets/Rigs")
    }()

    /// Points `Bundle.main` at the rigs on disk. Idempotent, so every suite
    /// can call it.
    static func install() {
        BundleResources.provider = { name, ext in
            let url = directory.appendingPathComponent("\(name).\(ext)")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// A rig by name, with the fixture installed.
    static func rig(_ name: String) -> RigData? {
        install()
        return RigData.named(name)
    }
}

/// `Source/Utils/GeometryHelpers.swift` is where this lives for real, and
/// `GameCompat` compiles that file as it is. It cannot be symlinked in here
/// too: it imports UIKit, which a macOS test target has no module for. The
/// rigs use this one helper out of all of it, so here it is, copied.
nonisolated func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}
