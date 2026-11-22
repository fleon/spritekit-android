import Foundation
import SpriteKitShim
@testable import PlatformRigs

/// A small synthetic skeleton (Fixtures/RigTest.json) that exercises every
/// feature the runtime reads: inherit modes, shear, a weighted and an
/// unweighted mesh, deform, regions, clipping, a path, IK with one and two
/// bones, world and local transform constraints, physics, colour, two-colour,
/// alpha and attachment keys, curves of every kind, and four animations to
/// layer and crossfade. Tools/Rig/verify-pose.js checks it against spine-core.
nonisolated enum RigFixture {
    static let url = Bundle.module.url(forResource: "RigTest", withExtension: "json", subdirectory: "Fixtures")

    static let json: [String: Any] = {
        guard
            let url,
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }()

    static let data: RigData? = RigData(json: json, textureURL: URL(fileURLWithPath: "/dev/null"))

    /// verify-pose.js's step, which never lands on a key.
    static let step: CGFloat = 1 / 60.02
}

nonisolated extension RigPose {
    func transform(_ name: String) -> Transform {
        data.bone(named: name).map(boneTransform) ?? Transform()
    }

    func at(_ name: String) -> CGPoint {
        let t = transform(name)
        return CGPoint(x: t.x, y: t.y)
    }

    /// The angle a bone's world transform turns to, in radians.
    func angle(_ name: String) -> CGFloat {
        let t = transform(name)
        return atan2(t.c, t.a)
    }

    func vertices(_ slot: String) -> [CGPoint] {
        var points: [CGPoint] = []
        guard let slot = data.slot(named: slot), worldVertices(slot: slot, into: &points) else { return [] }
        return points
    }
}
