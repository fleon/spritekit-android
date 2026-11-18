// Plays the schedules in a verify-pose.js plan through RigData and RigPose
// and writes each frame's pose as JSON lines, for comparing against
// spine-core 4.2 (spine42-dump.mjs) and spine-c 3.6 (spine36-dump.c).
//
//   posedump <plan.json> <out dir> <36|42>

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write("usage: posedump <plan.json> <out dir> <36|42>\n".data(using: .utf8) ?? Data())
    exit(2)
}
let runtime: RigPose.Runtime = arguments[3] == "42" ? .spine42 : .spine36

guard
    let planData = FileManager.default.contents(atPath: arguments[1]),
    let plan = try? JSONSerialization.jsonObject(with: planData) as? [String: Any],
    let rigsDir = plan["rigsDir"] as? String,
    let runs = plan["runs"] as? [[String: Any]]
else {
    FileHandle.standardError.write("bad plan\n".data(using: .utf8) ?? Data())
    exit(2)
}

func number(_ value: Double) -> String {
    if value == 0 || !value.isFinite { return "0" }
    return String(format: "%.7g", value)
}

func write(_ values: [Double], to out: inout String) {
    out += "["
    for (i, value) in values.enumerated() {
        if i > 0 { out += "," }
        out += number(value)
    }
    out += "]"
}

func double(_ value: Any?, _ fallback: Double = 0) -> CGFloat {
    CGFloat((value as? NSNumber)?.doubleValue ?? fallback)
}

var dataCache: [String: RigData] = [:]
for run in runs {
    guard let id = run["id"] as? String, let rig = run["rig"] as? String else { continue }
    let data: RigData
    if let cached = dataCache[rig] {
        data = cached
    } else {
        let url = URL(fileURLWithPath: "\(rigsDir)/Rig\(rig).json")
        guard
            let json = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
            let loaded = RigData(json: json, textureURL: url.deletingPathExtension().appendingPathExtension("png"))
        else {
            print("cannot load \(rig)")
            continue
        }
        dataCache[rig] = loaded
        data = loaded
    }
    let pose = RigPose(data: data, scale: double(run["scale"], 1), runtime: runtime)
    pose.defaultMix = double(run["mix"])
    pose.riseBone = (run["riseBone"] as? String).flatMap { data.bone(named: $0) }
    let frames = run["frames"] as? Int ?? 0
    let dt = double(run["dt"], 1.0 / 60)
    let dts = (run["dts"] as? [NSNumber])?.map { CGFloat($0.doubleValue) }
    let drift = (run["drift"] as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? [0, 0]
    let vertexEvery = run["vertexEvery"] as? Int ?? 10
    let actions = run["actions"] as? [[String: Any]] ?? []

    var out = "{\"bones\":[" + data.bones.map { "\"\($0.name)\"" }.joined(separator: ",") + "],\"slots\":["
        + data.slots.map { "\"\($0.name)\"" }.joined(separator: ",") + "]}\n"
    var events: [String] = []
    var frame = 0
    pose.onStart = { track, name in events.append("start \(track) \(name) @\(frame)") }
    pose.onInterrupt = { track, name in events.append("interrupt \(track) \(name) @\(frame)") }
    pose.onEnd = { track, name in events.append("end \(track) \(name) @\(frame)") }
    pose.onComplete = { track, name in events.append("complete \(track) \(name) @\(frame)") }

    var points: [CGPoint] = []
    while frame < frames {
        for action in actions where action["frame"] as? Int == frame {
            let track = action["track"] as? Int ?? 0, name = action["name"] as? String ?? ""
            let loop = action["loop"] as? Bool ?? false
            switch action["op"] as? String {
            case "add":
                let entry = pose.addAnimation(track, name, loop: loop, delay: double(action["delay"]))
                if let mix = action["mix"] as? NSNumber { entry?.mixDuration = CGFloat(mix.doubleValue) }
            case "play":
                pose.play(
                    name, loop: loop, rate: double(action["rate"], 1), from: double(action["from"]), until: double(action["until"]),
                    then: action["then"] as? String, rise: double(action["rise"], 1),
                    mix: (action["mix"] as? NSNumber).map { CGFloat($0.doubleValue) }, track: track
                )
            case "origin":
                pose.origin = CGPoint(x: double(action["x"]), y: double(action["y"]))
            case "clear":
                pose.clearTrack(track)
            default:
                let entry = pose.setAnimation(track, name, loop: loop)
                if let mix = action["mix"] as? NSNumber { entry?.mixDuration = CGFloat(mix.doubleValue) }
                if let scale = action["timeScale"] as? NSNumber { entry?.timeScale = CGFloat(scale.doubleValue) }
            }
        }
        pose.origin.x += drift[0]
        pose.origin.y += drift[1]
        pose.advance(dts.map { $0[frame % $0.count] } ?? dt)
        out += "{\"f\":\(frame),\"b\":"
        var bones: [Double] = []
        for i in data.bones.indices {
            let t = pose.boneTransform(i)
            bones += [t.a, t.b, t.c, t.d, t.x, t.y].map { Double($0) }
        }
        write(bones, to: &out)
        out += ",\"a\":["
        out += (0..<pose.slotCount).map { pose.attachmentName(slot: $0).map { "\"\($0)\"" } ?? "null" }.joined(separator: ",")
        out += "],\"c\":"
        write((0..<pose.slotCount).flatMap { slot -> [Double] in
            let c = pose.color(slot: slot)
            return [c.r, c.g, c.b, c.a].map { Double($0) }
        }, to: &out)
        if frame % vertexEvery == 0 {
            out += ",\"v\":{"
            var first = true
            for slot in 0..<pose.slotCount where pose.worldVertices(slot: slot, into: &points) {
                if !first { out += "," }
                first = false
                out += "\"\(slot)\":"
                write(points.flatMap { [Double($0.x), Double($0.y)] }, to: &out)
            }
            out += "}"
        }
        out += "}\n"
        frame += 1
    }
    out += "{\"events\":[" + events.map { "\"\($0)\"" }.joined(separator: ",") + "]}\n"
    FileManager.default.createFile(atPath: "\(arguments[2])/\(id).jsonl", contents: out.data(using: .utf8))
}
