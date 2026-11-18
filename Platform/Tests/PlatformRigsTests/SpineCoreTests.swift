import Foundation
import Testing
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import CoreGraphics
#endif
@testable import PlatformRigs

/// A frame of the `tracks` schedule as spine-core 4.2 posed it
/// (Tools/Rig/spine-dump.mjs): bone transforms (a, b, c, d, x, y, relative
/// to the skeleton's place), two slots' colours, what the head shows, and two
/// meshes' vertices.
private struct Golden {
    let frame: Int
    let bones: [String: [CGFloat]]
    let head: [CGFloat]
    let tip: [CGFloat]
    let headShows: String
    let body: [CGFloat]
    let flag: [CGFloat]
}

@Suite("Posing against spine-core")
struct SpineCoreTests {
    private static let golden: [Golden] = [
        Golden(
            frame: 45,
            bones: [
                "leg2": [0.4904, 0.8192, -0.8842, 0.4641, 19.9869, 31.9968],
                "fin": [3.6965, -0.5022, 2.1469, 0.8647, -6.0872, 114.1981],
                "follower": [0.5606, -0.7941, 0.9072, 0.5325, -20.8711, 32.1337],
                "crest": [0.8652, -0.1392, -0.4285, -1.1153, -9.7566, 87.3694],
                "p3": [2.2992, 0.1466, -0.3408, 0.9892, 10.9541, 40.4331],
                "tail2": [-1.0016, 0.0871, -0.0349, -1.0072, -34.8092, 51.7303],
                "hand": [1.3554, 0, 0, 0.8223, 1.7636, 126.9795],
                "arm": [0.5234, -0.8521, 0.8521, 0.5234, -13.938, 101.4166],
            ],
            head: [1, 0.3151, 0.3151, 0.9386],
            tip: [1, 1, 1, 0.6263],
            headShows: "head2",
            body: [-12.298, 49.009, 14.263, 50.528, 2.139, 100.684, -26.675, 100.1],
            flag: [1.764, 122.868, 30.74, 124.379, 28.872, 133.357, 1.764, 131.091]
        ),
        Golden(
            frame: 100,
            bones: [
                "leg2": [0.2669, 0.9516, -0.9639, 0.2661, 23.1118, 32.2753],
                "fin": [2.5322, -0.7895, 3.257, 0.6138, -5.8988, 110.3818],
                "follower": [0.619, -0.7826, 0.8281, 0.6113, -20.3123, 31.0085],
                "crest": [0.9732, -0.0016, -0.0357, -1.1109, -3.4976, 82.1357],
                "p3": [2.2992, 0.1466, -0.3408, 0.9892, 10.9541, 40.4331],
                "tail2": [-1.0184, -0.2817, 0.3757, -0.9594, -36.542, 59.135],
                "hand": [1.0227, 0, 0, 0.9886, -6.801, 125.3547],
                "arm": [-0.0601, -0.9982, 0.9982, -0.0601, -4.9966, 95.409],
            ],
            head: [1, 0.8227, 0.76, 0.7313],
            tip: [1, 1, 1, 0.9068],
            headShows: "head",
            body: [-14.356, 45.986, 15.003, 46.12, 10.907, 94.417, -19.649, 95.317],
            flag: [-6.801, 120.412, 14.011, 120.872, 13.654, 130.989, -6.801, 130.298]
        ),
        Golden(
            frame: 165,
            bones: [
                "leg2": [0.4685, 0.8382, -0.8798, 0.4752, 13.1688, 46.199],
                "fin": [-1.5817, 0.9493, -4.7761, -0.3144, -21.656, 126.6646],
                "follower": [0.5838, -0.8205, 0.8649, 0.5894, -20.5935, 37.6026],
                "crest": [0.9878, 0.2874, 0.2682, -1.1081, -6.647, 104.4399],
                "p3": [2.2992, 0.1466, -0.3408, 0.9892, 10.9541, 40.4331],
                "tail2": [-0.9447, 0.357, -0.3939, -0.9338, -34.3398, 63.4834],
                "hand": [1.039, 0, 0, 0.9805, -33.8163, 135.4468],
                "arm": [-0.8107, -0.5855, 0.5855, -0.8107, -9.4957, 117.8823],
            ],
            head: [1, 0.6011, 0.6011, 0.6787],
            tip: [1, 1, 1, 0.6809],
            headShows: "head",
            body: [-13.861, 67.683, 15.37, 68.86, 7.951, 117.411, -24.978, 116.907],
            flag: [-33.816, 130.544, -11.793, 132.109, -13.037, 142.696, -33.816, 140.349]
        ),
        Golden(
            frame: 250,
            bones: [
                "leg2": [0.2269, 0.9673, -0.9744, 0.2249, 23.7095, 32.4194],
                "fin": [3.0761, -0.5535, 2.0442, 0.8329, 3.8688, 106.8962],
                "follower": [0.6184, -0.7855, 0.8273, 0.6117, -20.3116, 30.8599],
                "crest": [0.9597, -0.2085, -0.2651, -1.0758, -3.4896, 81.5578],
                "p3": [2.2992, 0.1466, -0.3408, 0.9892, 10.9541, 40.4331],
                "tail2": [-1.0299, 0.0484, -0.0202, -0.9992, -36.5758, 49.2328],
                "hand": [1.3116, 0, 0, 0.8442, 12.7228, 119.0044],
                "arm": [0.5903, -0.8072, 0.8072, 0.5903, -4.9851, 94.7881],
            ],
            head: [1, 0.8089, 0.6939, 0.7418],
            tip: [1, 1, 1, 0.9486],
            headShows: "head",
            body: [-14.516, 45.441, 15.128, 45.627, 11.034, 93.913, -19.762, 94.588],
            flag: [12.723, 114.784, 39.226, 115.016, 38.955, 123.573, 12.723, 123.225]
        ),
        Golden(
            frame: 330,
            bones: [
                "leg2": [0.35, 0.9124, -0.9365, 0.3505, 21.7797, 32.0226],
                "fin": [1.8028, -0.9187, 4.1945, 0.3949, -16.2471, 109.1745],
                "follower": [0.5926, -0.7958, 0.8519, 0.5828, -20.5057, 31.3465],
                "crest": [0.9388, 0.168, 0.1296, -1.113, -5.664, 83.295],
                "p3": [2.2992, 0.1466, -0.3408, 0.9892, 10.9541, 40.4331],
                "tail2": [-1.0363, 0.1202, -0.1032, -0.9926, -36.5291, 48.015],
                "hand": [1.3116, 0, 0, 0.8442, -24.4027, 121.7636],
                "arm": [-0.5437, -0.8393, 0.8393, -0.5437, -8.0914, 96.5854],
            ],
            head: [1, 0.6946, 0.6151, 0.7105],
            tip: [1, 1, 1, 0.8173],
            headShows: "head",
            body: [-13.816, 46.868, 14.886, 47.781, 8.235, 96.144, -22.383, 95.74],
            flag: [-24.403, 117.543, 2.729, 118.314, 1.83, 127.141, -24.403, 125.984]
        ),
        Golden(
            frame: 399,
            bones: [
                "leg2": [0.1502, 0.9911, -0.9943, 0.0804, 25.7076, 32.7287],
                "fin": [2.9072, -0.6706, 2.6278, 0.7419, -1.6808, 107.7913],
                "follower": [0.5996, -0.7953, 0.8399, 0.6062, -20.4308, 30.6397],
                "crest": [0.9813, -0.1369, -0.1907, -1.0873, -4.8247, 80.6081],
                "p3": [2.2992, 0.1466, -0.3408, 0.9892, 10.9541, 40.4331],
                "tail2": [-1.0346, 0.1971, -0.1126, -1.003, -36.0455, 45.3316],
                "hand": [1.3116, 0, 0, 0.8442, 3.5308, 121.8568],
                "arm": [0.3474, -0.9377, 0.9377, 0.3474, -6.8925, 93.7258],
            ],
            head: [1, 1, 1, 1],
            tip: [1, 1, 1, 1],
            headShows: "head2",
            body: [],
            flag: []
        ),
    ]

    private static let events = 
[
            "start 0 idle @0",
            "start 1 wave @30",
            "interrupt 0 idle @60",
            "start 0 walk @60",
            "complete 0 idle @60",
            "complete 1 wave @66",
            "interrupt 0 walk @70",
            "start 0 jump @70",
            "end 0 walk @83",
            "end 0 idle @83",
            "interrupt 0 jump @95",
            "start 0 idle @95",
            "complete 1 wave @102",
            "complete 0 jump @106",
            "end 0 jump @108",
            "complete 1 wave @138",
            "interrupt 1 wave @150",
            "start 1 jump @150",
            "complete 0 idle @154",
            "interrupt 1 jump @163",
            "start 1 wave @163",
            "end 1 wave @169",
            "end 1 jump @176",
            "complete 1 wave @198",
            "complete 0 idle @214",
            "end 1 wave @220",
            "interrupt 0 idle @240",
            "start 0 walk @240",
            "end 0 idle @253",
            "interrupt 0 walk @320",
            "start 0 idle @320",
            "end 0 walk @351",
            "complete 0 idle @355",
        ]
    /// Two tracks layered, crossfaded, queued, interrupted, cleared, played
    /// backwards and sped up while the skeleton travels, at verify-pose.js's step.
    @Test("Layered, crossfaded and queued tracks pose as spine-core does, frame by frame")
    func tracks() throws {
        let rig = try #require(RigFixture.data)
        let pose = RigPose(data: rig)
        pose.defaultMix = 0.2
        var frame = 0
        var events: [String] = []
        pose.onStart = { events.append("start \($0) \($1) @\(frame)") }
        pose.onInterrupt = { events.append("interrupt \($0) \($1) @\(frame)") }
        pose.onEnd = { events.append("end \($0) \($1) @\(frame)") }
        pose.onComplete = { events.append("complete \($0) \($1) @\(frame)") }
        var golden = Self.golden[...]
        while frame < 400 {
            switch frame {
            case 0: pose.setAnimation(0, "idle", loop: true)
            case 30: pose.setAnimation(1, "wave", loop: true)
            case 60: pose.setAnimation(0, "walk", loop: true)?.mixDuration = 0.3
            case 70: pose.setAnimation(0, "jump", loop: false)
            case 71: pose.addAnimation(0, "idle", loop: true)
            case 150: pose.setAnimation(1, "jump", loop: false)?.mixDuration = 0.3
            case 160: pose.addAnimation(1, "wave", loop: true, delay: 0.2)
            case 220: pose.clearTrack(1)
            case 240: pose.setAnimation(0, "walk", loop: true)?.timeScale = -0.7
            case 300: pose.origin = CGPoint(x: 200, y: -100)
            case 320:
                let entry = pose.setAnimation(0, "idle", loop: false)
                entry?.mixDuration = 0.5
                entry?.timeScale = 1.7
            default: break
            }
            pose.origin.x += 1.5
            pose.origin.y -= 0.8
            pose.advance(RigFixture.step)
            if let expected = golden.first, expected.frame == frame {
                golden.removeFirst()
                check(pose, expected)
            }
            frame += 1
        }
        #expect(golden.isEmpty)
        #expect(events == Self.events)
    }

    private func check(_ pose: RigPose, _ expected: Golden) {
        for (name, values) in expected.bones {
            let t = pose.transform(name)
            let got = [t.a, t.b, t.c, t.d, t.x, t.y]
            let off = zip(got, values).map { abs($0 - $1) }.max() ?? 0
            #expect(off < 2e-4, "frame \(expected.frame): \(name) \(got) against \(values)")
        }
        let rig = pose.data
        for (slot, values) in [("head", expected.head), ("tip", expected.tip)] {
            guard let index = rig.slot(named: slot) else { continue }
            let c = pose.color(slot: index)
            let off = zip([c.r, c.g, c.b, c.a], values).map { abs($0 - $1) }.max() ?? 0
            #expect(off < 2e-4, "frame \(expected.frame): \(slot) colour \(c)")
        }
        #expect(rig.slot(named: "head").flatMap { pose.attachmentName(slot: $0) } == expected.headShows)
        for (slot, values) in [("body", expected.body), ("flag", expected.flag)] where !values.isEmpty {
            let got = pose.vertices(slot).flatMap { [$0.x, $0.y] }
            #expect(got.count == values.count)
            let off = zip(got, values).map { abs($0 - $1) }.max() ?? 0
            #expect(off < 2e-3, "frame \(expected.frame): \(slot) vertices \(got)")
        }
    }
}
