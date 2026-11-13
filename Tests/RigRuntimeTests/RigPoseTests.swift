import CoreGraphics
import Foundation
import Testing

/// Poses are compared by what they put on screen rather than by their
/// internals, which is also how a wrong one would show.
private extension RigPose {
    /// The angle a bone's world transform turns to, in radians.
    func angle(of bone: Int) -> CGFloat {
        let t = transform(of: bone)
        return atan2(t.c, t.a)
    }

    /// Where a bone's origin lands, relative to the rig's.
    func at(_ bone: Int) -> CGPoint {
        let t = transform(of: bone)
        return CGPoint(x: t.x, y: t.y)
    }
}

private func bone(_ rig: RigData, _ name: String) throws -> Int {
    try #require(rig.bones.firstIndex { $0.name == name }, "no \(name) bone")
}

@Suite("Posing a rig")
struct RigPoseTests {
    @Test("With nothing playing, the rig stands in its setup pose")
    func setup() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let pose = RigPose(data: rig)
        pose.advance(0)

        #expect(pose.playing == nil)
        // Each slot shows what the skeleton says it shows.
        #expect(pose.shown == rig.slots.map(\.attachment))
        #expect(pose.opacity == rig.slots.map(\.alpha))

        // A parentless bone sits where its own setup puts it; a child
        // composes through its parent.
        let root = try bone(rig, "root"), body = try bone(rig, "body")
        #expect(abs(pose.at(root).x - rig.bones[root].x) < 1e-6)
        let parent = try #require(rig.bones[body].parent)
        let p = pose.world[parent], local = rig.bones[body]
        #expect(abs(pose.world[body].x - (p.a * local.x + p.b * local.y + p.x)) < 1e-6)
        #expect(abs(pose.world[body].y - (p.c * local.x + p.d * local.y + p.y)) < 1e-6)
    }

    @Test("transform(of:) is relative to where the rig stands")
    func relativeToOrigin() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let pose = RigPose(data: rig)
        pose.advance(0)
        let here = pose.at(try bone(rig, "body"))

        pose.origin = CGPoint(x: 400, y: -250)
        pose.advance(0)
        let moved = pose.at(try bone(rig, "body"))
        // The rig moved through the scene; the bone did not move within it.
        #expect(abs(moved.x - here.x) < 1e-6)
        #expect(abs(moved.y - here.y) < 1e-6)
    }

    @Test("Playing an animation moves the rig, and looping brings it round again")
    func plays() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let hop = try #require(rig.animations["hop-right"])
        let pose = RigPose(data: rig)
        let move = try bone(rig, "move")

        pose.play("idle", loop: true)
        pose.advance(0)
        let grounded = pose.at(move)

        pose.play("hop-right", loop: true, mix: 1e-3)
        pose.advance(1e-3)
        // Part way through the hop the move bone is off the ground.
        pose.advance(hop.duration / 2 - 1e-3)
        let airborne = pose.at(move)
        #expect(airborne.y > grounded.y + 1)

        // All the way round, it is back where it started.
        pose.advance(hop.duration / 2)
        let landed = pose.at(move)
        #expect(abs(landed.y - grounded.y) < 1)
    }

    @Test("rise scales how far the move bone lifts, and 0 keeps it down")
    func rise() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let hop = try #require(rig.animations["hop-right"])
        let move = try bone(rig, "move")

        func apex(rise: CGFloat) -> CGFloat {
            let pose = RigPose(data: rig)
            pose.play("hop-right", loop: true, rise: rise)
            var highest = -CGFloat.infinity
            for _ in 0 ..< 60 {
                pose.advance(hop.duration / 60)
                highest = max(highest, pose.at(move).y)
            }
            return highest
        }

        let full = apex(rise: 1), half = apex(rise: 0.5), none = apex(rise: 0)
        #expect(full > none + 1)
        #expect(abs(half - (full + none) / 2) < 0.5)
    }

    @Test("An animation played once hands over to the one queued after it")
    func queued() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let pose = RigPose(data: rig)
        let hop = try #require(rig.animations["hop-right"])

        pose.play("hop-right", loop: false, then: "idle")
        pose.advance(hop.duration / 2)
        #expect(pose.playing == "hop-right")
        pose.advance(hop.duration)
        #expect(pose.playing == "idle")
    }

    @Test("Played backwards, it stops where it is told to")
    func backwards() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let hop = try #require(rig.animations["hop-right"])
        let pose = RigPose(data: rig)
        let move = try bone(rig, "move")

        pose.play("hop-right", loop: false, rate: -1, from: hop.duration, until: 0, then: "idle")
        pose.advance(hop.duration / 2)
        let midway = pose.at(move)
        pose.advance(hop.duration)
        #expect(pose.playing == "idle")

        // Backwards through the middle of a hop is still off the ground.
        let grounded = RigPose(data: rig)
        grounded.advance(0)
        #expect(midway.y > grounded.at(move).y)
    }
}

@Suite("Crossfading")
struct CrossfadeTests {
    /// How far off the ground the move bone is.
    ///
    /// The move bone hangs straight off the root, which nothing animates, so
    /// its world y is a linear function of the local y the crossfade blends.
    /// That is what makes "half way" something to measure rather than merely
    /// bracket. Nothing here has physics on it either, so what the test sees
    /// is the crossfade and nothing else.
    private func reading(_ rig: RigData, _ pose: RigPose) throws -> CGFloat {
        try pose.at(bone(rig, "move")).y
    }

    @Test("Half way through a mix, the pose lies between the two animations")
    func halfway() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let mix: CGFloat = 0.2, step: CGFloat = 0.1

        // Where each animation stands on its own, at the times the mixed one
        // will have reached.
        let from = RigPose(data: rig)
        from.play("celebrate", loop: true)
        from.advance(step + step)
        let a = try reading(rig, from)

        let to = RigPose(data: rig)
        to.play("hop-right", loop: true)
        to.advance(step)
        let b = try reading(rig, to)

        #expect(abs(a - b) > 1, "the two animations have to differ for this to mean anything")

        let mixed = RigPose(data: rig)
        mixed.play("celebrate", loop: true)
        mixed.advance(step)
        mixed.play("hop-right", loop: true, mix: mix)
        mixed.advance(step)
        let half = try reading(rig, mixed)

        #expect(min(a, b) < half && half < max(a, b), "\(half) is not between \(a) and \(b)")
        // Half the mix in, it is half way across — not merely somewhere
        // between, which a snap to either end would also satisfy.
        #expect(abs(half - (a + b) / 2) < 1e-6)

        // Both animations go on running under the fade: the one being faded
        // out keeps its own time rather than freezing where it was handed over.
        let frozen = RigPose(data: rig)
        frozen.play("celebrate", loop: true)
        frozen.advance(step)
        let handover = try reading(rig, frozen)
        #expect(abs(a - handover) > 1)
    }

    @Test("Once the mix is over, the new animation has it to itself")
    func finishes() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let mix: CGFloat = 0.2, after: CGFloat = 0.25

        let alone = RigPose(data: rig)
        alone.play("hop-right", loop: true)
        alone.advance(after)

        let mixed = RigPose(data: rig)
        mixed.play("celebrate", loop: true)
        mixed.advance(0.3)
        mixed.play("hop-right", loop: true, mix: mix)
        mixed.advance(after)

        #expect(abs(try reading(rig, mixed) - (try reading(rig, alone))) < 1e-6)
    }

    @Test("The very first animation takes hold at once, with nothing to mix from")
    func firstPlay() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        // Part way into the hop, where it is off the ground.
        let into: CGFloat = 0.2

        let alone = RigPose(data: rig)
        alone.play("hop-right", loop: true)
        alone.advance(into)

        let setup = RigPose(data: rig)
        setup.advance(into)

        // Nothing was playing, so there is no fade in from the setup pose.
        #expect(abs(try reading(rig, alone) - (try reading(rig, setup))) > 1)

        // Asking for a long mix changes nothing when there is nothing to mix
        // from: the first animation is simply what the rig does.
        let again = RigPose(data: rig)
        again.play("hop-right", loop: true, mix: 0.5)
        again.advance(into)
        #expect(abs(try reading(rig, again) - (try reading(rig, alone))) < 1e-9)
    }

    @Test("A mesh's vertices move with the bones under them")
    func meshFollows() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let slot = try #require(rig.slots.firstIndex { $0.name == "body" })
        guard case let .mesh(mesh)? = rig.attachments[slot]["body"] else {
            Issue.record("the body is not a mesh")
            return
        }

        let pose = RigPose(data: rig)
        pose.advance(0)
        var rest: [CGPoint] = []
        pose.vertices(of: mesh, into: &rest)
        #expect(rest.count == mesh.weights.count)

        pose.play("celebrate", loop: true)
        pose.advance(0.4)
        var moved: [CGPoint] = []
        pose.vertices(of: mesh, into: &moved)
        #expect(moved.count == rest.count)
        #expect(zip(rest, moved).contains { hypot($0.x - $1.x, $0.y - $1.y) > 1 })

        // Weights that sum to 0.9999 must not drag a vertex toward a far
        // origin. Carried 14,000 units across the scene, the same pose is
        // the same mesh to within a rounding error, not a tenth of it.
        pose.origin = CGPoint(x: 10_000, y: -10_000)
        pose.advance(0)
        var afar: [CGPoint] = []
        pose.vertices(of: mesh, into: &afar)
        #expect(zip(moved, afar).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-6 })
    }

    @Test("No rig's mesh drifts when it is carried across the scene")
    func noMeshDrifts() throws {
        RigFixture.install()
        let names = try FileManager.default.contentsOfDirectory(atPath: RigFixture.directory.path)
            .filter { $0.hasPrefix("Rig") && $0.hasSuffix(".json") && $0 != "RigFaces.json" }
            .map { String($0.dropFirst(3).dropLast(5)) }
            .sorted()

        var meshes = 0
        for name in names {
            let rig = try #require(RigData.named(name))
            for byName in rig.attachments {
                for (_, attachment) in byName {
                    guard case let .mesh(mesh) = attachment, !mesh.weights.isEmpty else { continue }
                    meshes += 1
                    let pose = RigPose(data: rig)
                    pose.advance(0)
                    var here: [CGPoint] = []
                    pose.vertices(of: mesh, into: &here)
                    pose.origin = CGPoint(x: 10_000, y: -10_000)
                    pose.advance(0)
                    var afar: [CGPoint] = []
                    pose.vertices(of: mesh, into: &afar)
                    let drift = zip(here, afar).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
                    #expect(drift < 2, "\(name) drifted \(drift) units")
                }
            }
        }
        #expect(meshes > 20, "only \(meshes) meshes — is Assets/Rigs built?")
    }
}

@Suite("Physics")
struct RigPhysicsTests {
    /// GardenA's leaves and top trail: rotate and scaleX constraints, which
    /// is what every Switchling's loose parts use.
    @Test("A trailing part swings as the rig moves and settles once it stops")
    func swingsAndSettles() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        #expect(rig.physics.contains { rig.bones[$0.bone].name == "leafL" })
        let leaf = try bone(rig, "leafL")

        // Nothing playing, so the only thing that can move the leaf is the
        // physics trailing the rig through the scene.
        let pose = RigPose(data: rig)
        pose.advance(0)
        let rest = pose.angle(of: leaf)

        let frame: CGFloat = 1 / 60
        for _ in 0 ..< 30 { pose.advance(frame) }
        #expect(abs(pose.angle(of: leaf) - rest) < 1e-6, "standing still, nothing should swing")

        // Carried smartly across the scene for a third of a second.
        //
        // Diagonally, on purpose: this leaf lies along x at rest, and a
        // carry straight along x turns the line from its root to its tip by
        // nothing at all, so it would feel no torque and the test would pass
        // on a rig that never swings. A hop moves both ways anyway.
        var swung: CGFloat = 0
        for _ in 0 ..< 20 {
            pose.origin = CGPoint(x: pose.origin.x + 9, y: pose.origin.y + 12)
            pose.advance(frame)
            swung = max(swung, abs(pose.angle(of: leaf) - rest))
        }
        #expect(swung > 0.02, "the leaf did not swing (\(swung) rad)")

        // Held still, it comes back to rest.
        for _ in 0 ..< 240 { pose.advance(frame) }
        #expect(abs(pose.angle(of: leaf) - rest) < swung / 10, "it did not settle")
    }

    @Test("Physics is stepped by time, not by frames")
    func steppedByTime() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let leaf = try bone(rig, "leafL")

        func carried(steps: Int) -> CGFloat {
            let pose = RigPose(data: rig)
            pose.advance(0)
            let rest = pose.angle(of: leaf)
            var swung: CGFloat = 0
            for i in 1 ... steps {
                let travelled = CGFloat(i) * 240 / CGFloat(steps)
                pose.origin = CGPoint(x: travelled * 0.6, y: travelled)
                pose.advance(0.5 / CGFloat(steps))
                swung = max(swung, abs(pose.angle(of: leaf) - rest))
            }
            return swung
        }

        // The same journey over the same half second, at 30 fps and at 120.
        // Spine's constraint runs on its own fixed step, so the two agree.
        let slow = carried(steps: 15), fast = carried(steps: 60)
        #expect(slow > 0.02 && fast > 0.02)
        #expect(abs(slow - fast) < max(slow, fast) * 0.35, "30 fps gave \(slow), 120 fps gave \(fast)")
    }

    @Test("A rig that does not travel keeps its parts still")
    func stillWhenStill() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let leaf = try bone(rig, "leafL")
        let pose = RigPose(data: rig)
        pose.advance(0)
        let rest = pose.angle(of: leaf)
        for _ in 0 ..< 600 { pose.advance(1 / 60) }
        #expect(abs(pose.angle(of: leaf) - rest) < 1e-6)
    }
}
