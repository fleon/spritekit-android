import Foundation
import Testing
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import CoreGraphics
#endif
@testable import PlatformRigs

@Suite("Posing a rig")
struct RigPoseTests {
    @Test("With nothing playing, the rig stands in its setup pose")
    func setup() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        #expect(pose.playing == nil)
        #expect(!pose.isAnimating)
        for slot in rig.slots.indices {
            #expect(pose.attachmentIndex(slot: slot) == rig.slots[slot].attachment)
            #expect(pose.slotColor(slot) == rig.slots[slot].color)
        }
        // A child composes through its parent.
        let hip = pose.transform("hip"), move = pose.transform("move")
        #expect(abs(hip.y - (move.y + 50)) < 1e-9)
    }

    @Test("Positions are relative to where the skeleton stands, and scaled")
    func relativeToOrigin() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        let here = pose.at("spine")
        pose.origin = CGPoint(x: 400, y: -250)
        pose.advance(0)
        let moved = pose.at("spine")
        #expect(abs(moved.x - here.x) < 1e-9 && abs(moved.y - here.y) < 1e-9)

        let scaled = RigPose(data: rig, scale: 2)
        #expect(abs(scaled.at("spine").y - here.y * 2) < 1e-9)
    }

    @Test("Playing an animation moves the rig, and looping brings it round again")
    func plays() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        let grounded = pose.at("move")
        pose.play("jump", loop: true)
        #expect(pose.playing == "jump")
        #expect(pose.isAnimating)
        pose.advance(0.3)
        #expect(abs(pose.at("move").y - grounded.y - 40) < 1e-9)
        pose.advance(0.3)
        #expect(abs(pose.at("move").y - grounded.y) < 1e-9)
    }

    @Test("rise scales how far the rise bone lifts, and 0 keeps it down")
    func rise() throws {
        let rig = try #require(RigFixture.data)
        func apex(_ rise: CGFloat) -> CGFloat {
            let pose = RigPose(data: rig)
            pose.riseBone = rig.bone(named: "move")
            pose.play("jump", loop: true, rise: rise)
            pose.advance(0.3)
            return pose.at("move").y
        }
        #expect(abs(apex(1) - 40) < 1e-9)
        #expect(abs(apex(0.5) - 20) < 1e-9)
        #expect(abs(apex(0)) < 1e-9)
    }

    @Test("An animation played once hands over to the one it names, as it ends")
    func then() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        var ended: [String] = []
        pose.onEnd = { ended.append($1) }
        pose.play("jump", loop: false, then: "idle")
        pose.advance(0.3)
        #expect(pose.playing == "jump")
        pose.advance(0.31)
        #expect(pose.playing == "idle")
        #expect(pose.current(track: 0)?.loop == true)
        pose.advance(1)
        #expect(ended == ["jump"])
    }

    @Test("Played backwards, it stops where it is told to and hands over")
    func backwards() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        pose.play("jump", loop: false, rate: -1, from: 0.6, until: 0.1, then: "walk")
        pose.advance(0.3)
        #expect(abs(pose.at("move").y - 40) < 1e-9)
        #expect(pose.current(track: 0)?.animationTime == 0.3)
        pose.advance(0.15)
        #expect(pose.playing == "jump")
        pose.advance(0.1)
        #expect(pose.playing == "walk")
    }

    @Test("Queued, an entry waits its delay; cleared, a track lets go")
    func queue() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        var started: [String] = []
        pose.onStart = { started.append("\($0) \($1)") }
        pose.setAnimation(0, "jump", loop: false)
        pose.addAnimation(0, "walk", loop: true, delay: 0.5)
        pose.advance(0.4)
        pose.advance(0.2)
        // It takes over the frame after the last one reached its delay, as spine-core's does.
        #expect(pose.playing == "jump")
        pose.advance(0.01)
        #expect(pose.playing == "walk")
        pose.setAnimation(2, "wave", loop: true)
        #expect(pose.animationName(track: 2) == "wave")
        pose.clearTrack(2)
        #expect(pose.animationName(track: 2) == nil)
        pose.clearTracks()
        #expect(!pose.isAnimating)
        #expect(started == ["0 jump", "0 walk", "2 wave"])
    }

    @Test("The skeleton's colour and time scale apply to everything")
    func skeletonWide() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        let tip = try #require(rig.slot(named: "tip"))
        pose.skeletonColor = RigData.Color(r: 0.5, g: 1, b: 1, a: 0.5)
        #expect(pose.color(slot: tip) == RigData.Color(r: 0.5, g: 1, b: 1, a: 0.5))

        let fast = RigPose(data: rig), slow = RigPose(data: rig)
        fast.timeScale = 2
        fast.play("jump", loop: true)
        slow.play("jump", loop: true)
        fast.advance(0.15)
        slow.advance(0.3)
        #expect(abs(fast.at("move").y - slow.at("move").y) < 1e-9)
    }
}

@Suite("Crossfading")
struct CrossfadeTests {
    /// The move bone hangs off the root, which nothing animates, so its y is
    /// the local y the crossfade blends; nothing trails it.
    private func lift(_ pose: RigPose) -> CGFloat { pose.at("move").y }

    @Test("Half way through a mix, the pose lies half way between the two animations")
    func halfway() throws {
        let rig = try #require(RigFixture.data)
        let from = RigPose(data: rig)
        from.play("walk", loop: true)
        from.advance(0.1)
        from.advance(0.05)
        let a = lift(from)
        let to = RigPose(data: rig)
        to.play("jump", loop: true)
        to.advance(0.05)
        let b = lift(to)
        #expect(abs(a - b) > 1)

        let mixed = RigPose(data: rig)
        mixed.play("walk", loop: true)
        mixed.advance(0.1)
        mixed.play("jump", loop: true, mix: 0.1)
        mixed.advance(0.05)
        #expect(abs(lift(mixed) - (a + b) / 2) < 1e-9)
    }

    @Test("Once the mix is over, the new animation has it to itself")
    func finishes() throws {
        let rig = try #require(RigFixture.data)
        let alone = RigPose(data: rig)
        alone.play("jump", loop: true)
        alone.advance(0.25)
        let mixed = RigPose(data: rig)
        mixed.defaultMix = 0.2
        mixed.play("walk", loop: true)
        mixed.advance(0.3)
        mixed.play("jump", loop: true)
        mixed.advance(0.25)
        #expect(abs(lift(mixed) - lift(alone)) < 1e-9)
    }

    @Test("The first animation takes hold at once, with nothing to mix from")
    func firstPlay() throws {
        let rig = try #require(RigFixture.data)
        let alone = RigPose(data: rig)
        alone.play("jump", loop: true)
        alone.advance(0.2)
        let mixed = RigPose(data: rig)
        mixed.play("jump", loop: true, mix: 0.5)
        mixed.advance(0.2)
        #expect(lift(alone) > 10)
        #expect(abs(lift(mixed) - lift(alone)) < 1e-9)
    }

    @Test("A mix set between two animations is used for them alone")
    func setMix() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        pose.setMix(from: "walk", to: "jump", duration: 0.4)
        pose.defaultMix = 0.1
        pose.play("walk", loop: true)
        pose.advance(0.1)
        #expect(pose.play("jump", loop: true)?.mixDuration == 0.4)
        pose.advance(0.1)
        #expect(pose.play("walk", loop: true)?.mixDuration == 0.1)
        // An entry never posed isn't mixed from.
        #expect(pose.play("jump", loop: true)?.mixDuration == 0.1)
    }
}

@Suite("Vertices")
struct VertexTests {
    @Test("A mesh's vertices move with the bones under them, and deform keys bend them")
    func meshFollows() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        let rest = pose.vertices("body"), flag = pose.vertices("flag")
        #expect(rest.count == 4 && flag.count == 4)
        pose.play("idle", loop: true)
        pose.advance(0.5)
        #expect(zip(rest, pose.vertices("body")).contains { hypot($0.x - $1.x, $0.y - $1.y) > 1 })
        // The flag rides an onlyTranslation bone: at the deform key, its
        // second and third vertices are offset by the key, in the bone's space.
        let hand = pose.transform("hand"), bent = pose.vertices("flag")
        #expect(abs(bent[1].x - (hand.x + hand.a * 23)) < 1e-6)
        #expect(abs(bent[1].y - (hand.y + hand.d * -1)) < 1e-6)
    }

    @Test("Weights that sum to a little under one don't fling a vertex toward a far origin")
    func farOrigin() throws {
        let json: [String: Any] = [
            "bones": [["name": "root"], ["name": "a", "parent": "root", "x": 10]],
            "slots": [["name": "s", "bone": "root", "attachment": "m"]],
            "skins": [["name": "default", "attachments": ["s": ["m": [
                "type": "mesh", "uvs": [0, 0, 1, 0, 1, 1], "triangles": [0, 1, 2], "hull": 3,
                "vertices": [2, 0, 0, 0, 0.5, 1, 0, 0, 0.4999, 1, 1, 5, 5, 0.9999, 1, 1, -5, 5, 0.9999],
            ]]]]],
        ]
        let rig = try #require(RigData(json: json, textureURL: URL(fileURLWithPath: "/dev/null")))
        let pose = RigPose(data: rig)
        let here = pose.vertices("s")
        pose.origin = CGPoint(x: 1e6, y: -1e6)
        pose.advance(0)
        let afar = pose.vertices("s")
        #expect(zip(here, afar).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-6 })
    }

    @Test("A region's corners turn with its bone")
    func region() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        let corners = pose.vertices("tip")
        #expect(corners.count == 4)
        let tail = pose.transform("tail2")
        let centre = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        #expect(abs(centre.x - (tail.x + tail.a * 4)) < 1e-6)
        #expect(abs(centre.y - (tail.y + tail.c * 4)) < 1e-6)
    }
}

@Suite("Physics")
struct RigPhysicsTests {
    private let frame: CGFloat = 1 / 60

    /// Settled under its wind and gravity.
    private func settled(_ rig: RigData) -> RigPose {
        let pose = RigPose(data: rig)
        for _ in 0..<900 { pose.advance(frame) }
        return pose
    }

    @Test("A trailing part swings as the rig moves and settles once it stops")
    func swingsAndSettles() throws {
        let rig = try #require(RigFixture.data)
        let pose = settled(rig)
        #expect(pose.isSettled)
        let rest = pose.angle("tail")
        for _ in 0..<30 { pose.advance(frame) }
        #expect(abs(pose.angle("tail") - rest) < 1e-6, "standing still, nothing should swing")

        var swung: CGFloat = 0
        for _ in 0..<20 {
            pose.origin = CGPoint(x: pose.origin.x + 9, y: pose.origin.y + 12)
            pose.advance(frame)
            swung = max(swung, abs(pose.angle("tail") - rest))
        }
        #expect(swung > 0.02, "the tail did not swing (\(swung) rad)")
        #expect(!pose.isSettled)
        for _ in 0..<900 { pose.advance(frame) }
        #expect(abs(pose.angle("tail") - rest) < swung / 10, "it did not settle")
    }

    @Test("A slow swing isn't settled at the ends of its arc, wind or not")
    func slowSwingSettlesOnce() throws {
        var json = RigFixture.json
        var physics = try #require(json["physics"] as? [[String: Any]])
        for i in physics.indices {
            physics[i]["damping"] = 0.97
            physics[i]["strength"] = 70
        }
        json["physics"] = physics
        let rig = try #require(RigData(json: json, textureURL: URL(fileURLWithPath: "/dev/null")))
        let pose = settled(rig)
        for _ in 0..<20 {
            pose.origin.x += 9
            pose.advance(frame)
        }
        var settledAt: Int?
        var swingsAgain = false
        for f in 0..<1800 {
            pose.advance(frame)
            if pose.isSettled, settledAt == nil { settledAt = f }
            if !pose.isSettled, settledAt != nil { swingsAgain = true }
        }
        #expect(settledAt != nil)
        #expect(!swingsAgain, "it counted as settled mid-swing (frame \(settledAt ?? -1))")
    }

    @Test("Physics is stepped by time, not by frames")
    func steppedByTime() throws {
        let rig = try #require(RigFixture.data)
        func carried(steps: Int) -> CGFloat {
            let pose = settled(rig)
            let rest = pose.angle("tail"), start = pose.origin
            var swung: CGFloat = 0
            for i in 1...steps {
                let travelled = CGFloat(i) * 240 / CGFloat(steps)
                pose.origin = CGPoint(x: start.x + travelled * 0.6, y: start.y + travelled)
                pose.advance(0.5 / CGFloat(steps))
                swung = max(swung, abs(pose.angle("tail") - rest))
            }
            return swung
        }
        let slow = carried(steps: 15), fast = carried(steps: 60)
        #expect(slow > 0.02 && fast > 0.02)
        #expect(abs(slow - fast) < max(slow, fast) * 0.35, "30 fps gave \(slow), 120 fps gave \(fast)")
    }

    @Test("Resetting physics puts every trailing part back at once")
    func reset() throws {
        let rig = try #require(RigFixture.data)
        let still = RigPose(data: rig)
        let pose = RigPose(data: rig)
        for _ in 0..<10 {
            pose.origin.x += 20
            pose.advance(frame)
        }
        pose.resetPhysics()
        pose.advance(frame)
        still.resetPhysics()
        still.advance(frame)
        #expect(abs(pose.angle("tail") - still.angle("tail")) < 1e-9)
        #expect(abs(pose.angle("tail2") - still.angle("tail2")) < 1e-9)
    }
}
