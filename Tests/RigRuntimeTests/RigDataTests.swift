import CoreGraphics
import Foundation
import Testing

@Suite("Reading a rig")
struct RigDataTests {
    @Test("A packed rig reads back with its bones, slots, atlas and animations")
    func reads() throws {
        let rig = try #require(RigFixture.rig("GardenA"), "Assets/Rigs is not built — run npm run rigs")

        #expect(rig.bones.map(\.name) == ["root", "shadow", "move", "body", "top", "leafL", "leafR", "face"])
        #expect(rig.slots.map(\.name) == ["shadow", "body", "eyes"])
        #expect(rig.move == "hop")
        #expect(rig.flies == false)
        #expect(rig.origin == CGPoint(x: 180.5, y: 299))

        // Every bone but the root hangs off one declared before it, which is
        // what lets `place()` run the list once, parents first.
        for (index, bone) in rig.bones.enumerated() {
            if index == 0 { #expect(bone.parent == nil) } else { #expect((bone.parent ?? -1) < index) }
        }

        // The move bone is the one a hop lifts.
        #expect(rig.moveBone == rig.bones.firstIndex { $0.name == "move" })

        // What the rig draws itself has a place on the rig's own page; the
        // faces do not, because they come off the shared RigFaces sheet and
        // `RigNode` skips any attachment with no atlas rect.
        for (slot, byName) in rig.attachments.enumerated() where rig.slots[slot].name != "eyes" {
            for name in byName.keys {
                #expect(rig.atlas[name] != nil, "\(rig.slots[slot].name)/\(name) has no atlas rect")
            }
        }
        let eyes = try #require(rig.slots.firstIndex { $0.name == "eyes" })
        #expect(Set(rig.attachments[eyes].keys) == ["eyes", "blink", "happy", "dizzy", "sleep"])
        #expect(rig.attachments[eyes].keys.allSatisfy { rig.atlas[$0] == nil })
    }

    @Test("Each of the 34 animations is there, with a duration and keys")
    func animations() throws {
        let rig = try #require(RigFixture.rig("GardenA"))

        for name in ["idle", "sleep", "celebrate", "hop-left", "hop-right", "hop-up", "hop-down",
                     "jump-left", "rebound-left", "slide-left", "fly-left", "convey-left",
                     "portal", "pad", "teleport", "bump-left"] {
            let animation = try #require(rig.animations[name], "no \(name)")
            #expect(animation.duration > 0)
            #expect(!animation.bones.isEmpty)
            for track in animation.bones {
                #expect(!track.keys.isEmpty)
                // Keys are in time order, which `sample` walks backwards.
                #expect(zip(track.keys, track.keys.dropFirst()).allSatisfy { $0.time <= $1.time })
            }
        }

        // A hop lifts; an idle does not.
        #expect(try #require(rig.animations["hop-right"]).rise > 0)
        #expect(try #require(rig.animations["idle"]).rise == 0)
    }

    @Test("The body is a weighted mesh whose triangles all point at real vertices")
    func mesh() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let slot = try #require(rig.slots.firstIndex { $0.name == "body" })
        guard case let .mesh(mesh)? = rig.attachments[slot]["body"] else {
            Issue.record("the body is not a mesh")
            return
        }
        #expect(mesh.uvs.count == 62)
        #expect(mesh.weights.count == mesh.uvs.count)
        #expect(mesh.triangles.count % 3 == 0)
        #expect(mesh.triangles.allSatisfy { $0 >= 0 && $0 < mesh.uvs.count })
        #expect(mesh.uvs.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
        // Spine rounds the weights it writes, so they sum to about one —
        // which is exactly why `RigPose.vertices` takes bones relative to the
        // origin before weighting them.
        for weights in mesh.weights {
            let sum = weights.reduce(CGFloat(0)) { $0 + $1.weight }
            #expect(abs(sum - 1) < 0.01)
            #expect(weights.allSatisfy { $0.bone >= 0 && $0.bone < rig.bones.count })
        }
    }

    @Test("The lift of a hop rises to its apex and comes back down")
    func lift() throws {
        let rig = try #require(RigFixture.rig("GardenA"))
        let hop = try #require(rig.animations["hop-right"])

        let samples = stride(from: CGFloat(0), through: hop.duration, by: hop.duration / 40)
            .map { rig.lift("hop-right", at: $0) }
        #expect(samples.allSatisfy { $0 >= -0.001 && $0 <= 1.001 })
        #expect(samples.first! < 0.01)
        #expect(samples.last! < 0.01)
        #expect(samples.max()! > 0.99)
        // The apex is somewhere in the middle, not at either end.
        let apex = samples.firstIndex(of: samples.max()!)!
        #expect(apex > 2 && apex < samples.count - 3)
    }

    @Test("Every packed rig reads, and the faces sheet places four expressions")
    func everyRig() throws {
        RigFixture.install()
        let names = try FileManager.default.contentsOfDirectory(atPath: RigFixture.directory.path)
            .filter { $0.hasPrefix("Rig") && $0.hasSuffix(".json") && $0 != "RigFaces.json" }
            .map { String($0.dropFirst(3).dropLast(5)) }
            .sorted()
        #expect(names.count > 40, "only \(names.count) rigs — is Assets/Rigs built?")

        for name in names {
            let rig = try #require(RigData.named(name), "\(name) would not read")
            #expect(!rig.bones.isEmpty)
            #expect(!rig.slots.isEmpty)
            #expect(!rig.animations.isEmpty)
        }

        // The Switchlings wear painted faces; the mechanisms do not.
        let faces = RigData.faces(of: "GardenA")
        #expect(Set(faces.keys) == [.happy, .dizzy, .sleep, .blink])
        for (_, face) in faces {
            #expect(face.frame.width > 0 && face.frame.height > 0)
            #expect(face.placement.size == face.frame.size)
        }
        #expect(RigData.faces(of: "LeverCastle").isEmpty)
    }
}

@Suite("Sampling a curve")
struct CurveTests {
    private func keys(_ curve: RigData.Curve) -> [RigData.Key] {
        [RigData.Key(time: 0, values: [0], curve: curve),
         RigData.Key(time: 1, values: [10], curve: .linear)]
    }

    @Test("A linear curve runs straight between its keys")
    func linear() {
        let keys = keys(.linear)
        #expect(RigData.sample(keys, at: 0, channel: 0) == 0)
        #expect(RigData.sample(keys, at: 0.25, channel: 0) == 2.5)
        #expect(RigData.sample(keys, at: 0.5, channel: 0) == 5)
        #expect(RigData.sample(keys, at: 1, channel: 0) == 10)
    }

    @Test("Time before the first key and after the last is held")
    func held() {
        let keys = keys(.linear)
        #expect(RigData.sample(keys, at: -5, channel: 0) == 0)
        #expect(RigData.sample(keys, at: 99, channel: 0) == 10)
    }

    @Test("A stepped curve holds its value until the next key")
    func stepped() {
        let keys = keys(.stepped)
        #expect(RigData.sample(keys, at: 0.01, channel: 0) == 0)
        #expect(RigData.sample(keys, at: 0.99, channel: 0) == 0)
        #expect(RigData.sample(keys, at: 1, channel: 0) == 10)
    }

    @Test("A bezier curve eases, passing through its ends exactly")
    func bezier() {
        // Spine writes the two handles as time, value, time, value; this is
        // an ease-in-ease-out between (0, 0) and (1, 10).
        let keys = keys(.bezier([0.25, 0, 0.75, 10]))
        #expect(abs(RigData.sample(keys, at: 0, channel: 0)) < 1e-6)
        #expect(abs(RigData.sample(keys, at: 1, channel: 0) - 10) < 1e-6)
        #expect(abs(RigData.sample(keys, at: 0.5, channel: 0) - 5) < 0.01)
        // Eased: it lags a straight line early and catches up late.
        #expect(RigData.sample(keys, at: 0.2, channel: 0) < 2)
        #expect(RigData.sample(keys, at: 0.8, channel: 0) > 8)
        // Monotone all the way through, as an ease must be.
        let samples = stride(from: CGFloat(0), through: 1, by: 0.02).map { RigData.sample(keys, at: $0, channel: 0) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
    }

    @Test("Each channel of a multi-value key is sampled on its own")
    func channels() {
        let keys = [RigData.Key(time: 0, values: [0, 100], curve: .linear),
                    RigData.Key(time: 2, values: [10, 0], curve: .linear)]
        #expect(RigData.sample(keys, at: 1, channel: 0) == 5)
        #expect(RigData.sample(keys, at: 1, channel: 1) == 50)
    }
}
