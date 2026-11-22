import Foundation
import Testing
import SpriteKitShim
@testable import PlatformRigs

@Suite("Reading a rig")
struct RigDataTests {
    @Test("Bones, slots and constraints read back in order, with every inherit mode")
    func reads() throws {
        let rig = try #require(RigFixture.data)
        #expect(rig.bones.count == 18)
        #expect(rig.slots.map(\.name) == ["body", "clip", "head", "flag", "trail", "shade", "tip"])
        for (index, bone) in rig.bones.enumerated() {
            if index == 0 { #expect(bone.parent == nil) } else { #expect((bone.parent ?? .max) < index) }
        }
        let inherits = Dictionary(uniqueKeysWithValues: rig.bones.map { ($0.name, $0.inherit) })
        #expect(inherits["arm"] == .noScale)
        #expect(inherits["hand"] == .onlyTranslation)
        #expect(inherits["crest"] == .noRotationOrReflection)
        #expect(inherits["fin"] == .noScaleOrReflection)
        #expect(inherits["spine"] == .normal)
        #expect(rig.bones[try #require(rig.bone(named: "spine"))].shearX == 5)

        #expect(rig.iks.map(\.bones.count) == [2, 1])
        #expect(rig.iks[0].bendDirection == -1)
        #expect(rig.transforms.map(\.local) == [false, true])
        #expect(rig.paths.first?.rotateMode == .chainScale)
        #expect(rig.physics.map(\.name) == ["tailPhysics", "tail2Physics"])
        #expect(abs((rig.physics.last?.step ?? 0) - 1.0 / 30) < 1e-12)
        #expect(rig.referenceScale == 100)
        #expect(rig.extras["note"] as? String == "a game's own field")
        #expect(rig.extras["bones"] == nil)
    }

    @Test("Attachments: regions, weighted and plain meshes, a clip and a path")
    func attachments() throws {
        let rig = try #require(RigFixture.data)
        let body = try #require(rig.slot(named: "body"))
        guard case let .mesh(mesh)? = rig.attachment(slot: body, named: "body") else {
            Issue.record("body is not a mesh")
            return
        }
        #expect(mesh.vertices.isWeighted)
        #expect(mesh.vertices.length == 8)
        #expect(mesh.triangles.allSatisfy { $0 >= 0 && $0 < mesh.uvs.count })
        #expect(mesh.frame == CGRect(x: 0, y: 40, width: 40, height: 60))

        let flag = try #require(rig.slot(named: "flag"))
        guard case let .mesh(plain)? = rig.attachment(slot: flag, named: "flag") else {
            Issue.record("flag is not a mesh")
            return
        }
        #expect(!plain.vertices.isWeighted)

        let clip = try #require(rig.slot(named: "clip"))
        guard case let .clipping(clipping)? = rig.attachment(slot: clip, named: "clip") else {
            Issue.record("clip is not a clipping")
            return
        }
        #expect(clipping.end == flag)

        let trail = try #require(rig.slot(named: "trail"))
        guard case let .path(path)? = rig.attachment(slot: trail, named: "trail") else {
            Issue.record("trail is not a path")
            return
        }
        #expect(path.vertices.length == 18)
        #expect(!path.closed)

        let head = try #require(rig.slot(named: "head"))
        #expect(rig.slots[head].attachmentName == "head")
        #expect(rig.slots[head].color != .white)
        guard case let .region(region)? = rig.attachment(slot: head, named: "head") else {
            Issue.record("head is not a region")
            return
        }
        #expect(region.offsets.count == 4)
        // Region UVs in the packed texture follow its atlas place.
        let uvs = rig.textureUVs(of: .region(region), in: CGSize(width: 128, height: 128))
        #expect(uvs.first == CGPoint(x: 30.0 / 128, y: 24.0 / 128))
        #expect(rig.tintsColor)
    }

    @Test("Animations read with their durations, each kind of timeline once")
    func animations() throws {
        let rig = try #require(RigFixture.data)
        #expect(Set(rig.animations.keys) == ["idle", "walk", "wave", "jump"])
        let idle = try #require(rig.animations["idle"])
        #expect(idle.duration == 1)
        let kinds = Set(idle.timelines.map(\.kind))
        for kind: RigData.Timeline.Kind in [.translate, .rotate, .scale, .shear, .scaleX, .shearY, .translateX, .translateY, .rgba, .rgb, .alpha, .attachment, .deform] {
            #expect(kinds.contains(kind), "no \(kind) timeline")
        }
        for timeline in idle.timelines {
            #expect(zip(timeline.times, timeline.times.dropFirst()).allSatisfy { $0 <= $1 })
        }
        #expect(rig.peakLift(of: try #require(rig.bone(named: "move")), in: "jump") == 40)
    }

    @Test("A loader set by the game reads rigs once, until forgotten")
    func loader() throws {
        let previous = RigData.loader
        defer { RigData.loader = previous }
        nonisolated(unsafe) var reads = 0
        RigData.loader = { name in
            reads += 1
            return name == "Test" ? RigFixture.data : nil
        }
        #expect(RigData.named("Test") === RigFixture.data)
        #expect(RigData.named("Test") === RigFixture.data)
        #expect(reads == 1)
        #expect(RigData.named("Missing") == nil)
        RigData.forget { $0 == "Test" }
        _ = RigData.named("Test")
        #expect(reads == 3)
    }
}

@Suite("Sampling a curve")
struct CurveTests {
    private func timeline(_ curve: Any?) throws -> RigData.Timeline {
        var first: [String: Any] = ["time": 0, "value": 0]
        if let curve { first["curve"] = curve }
        let json: [String: Any] = [
            "bones": [["name": "root"]], "slots": [],
            "animations": ["a": ["bones": ["root": ["translatex": [first, ["time": 1, "value": 10]]]]]],
        ]
        let rig = try #require(RigData(json: json, textureURL: URL(fileURLWithPath: "/dev/null")))
        return try #require(rig.animations["a"]?.timelines.first)
    }

    @Test("Linear runs straight, and time outside the keys is held")
    func linear() throws {
        let t = try timeline(nil)
        #expect(t.value(at: 0.25, channel: 0) == 2.5)
        #expect(t.value(at: -5, channel: 0) == 0)
        #expect(t.value(at: 99, channel: 0) == 10)
    }

    @Test("Stepped holds until the next key")
    func stepped() throws {
        let t = try timeline("stepped")
        #expect(t.value(at: 0.99, channel: 0) == 0)
        #expect(t.value(at: 1, channel: 0) == 10)
    }

    @Test("A bezier eases along spine-core's polyline, through its ends")
    func bezier() throws {
        let t = try timeline([0.25, 0, 0.75, 10])
        #expect(abs(t.value(at: 0, channel: 0)) < 1e-9)
        #expect(abs(t.value(at: 0.5, channel: 0) - 5) < 0.01)
        #expect(t.value(at: 0.2, channel: 0) < 2)
        #expect(t.value(at: 0.8, channel: 0) > 8)
        let samples = stride(from: CGFloat(0), through: 1, by: 0.02).map { t.value(at: $0, channel: 0) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
        // CurveTimeline.getBezierValue (spine-core 4.2, which keeps its
        // polyline in 32-bit floats) at 0.3.
        #expect(abs(t.value(at: 0.3, channel: 0) - 2.422018245036899) < 1e-6)
    }
}
