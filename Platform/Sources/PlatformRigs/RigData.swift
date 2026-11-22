#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A Spine skeleton as a game plays it: what Spine 4.2 exported as JSON, with its images packed into one
/// texture whose places the JSON's `atlas` table gives (`[x, y, width,
/// height]` in pixels, y down, by image name). Read once and shared by every
/// `RigPose` that plays it.
///
/// Values stay in the skeleton's own units. What's read: bones with every
/// `inherit` mode, slots with colours, the default skin's region, mesh,
/// clipping and path attachments, IK, transform, path and physics
/// constraints, and bone, colour, attachment and deform keys. Whatever else
/// the JSON carries at its top level (a game's own fields) is kept in `extras`.
///
/// A port of the Spine Runtimes (spine-core 4.2), which may only
/// be used under the Spine Runtimes License by holders of a Spine license.
public nonisolated final class RigData: @unchecked Sendable {
    public struct Color: Equatable, Sendable {
        public var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

        public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        public static let white = Color(r: 1, g: 1, b: 1, a: 1)
    }

    public enum Inherit: Sendable {
        case normal, onlyTranslation, noRotationOrReflection, noScale, noScaleOrReflection
    }

    public struct Bone: Sendable {
        public let name: String
        public let parent: Int?
        public let x, y, rotation, scaleX, scaleY, shearX, shearY, length: CGFloat
        public let inherit: Inherit
    }

    public struct Slot: Sendable {
        public let name: String
        public let bone: Int
        /// The attachment it shows at rest, an index into `attachments`.
        public let attachment: Int?
        /// That attachment's name, which may name nothing in the skin.
        public let attachmentName: String?
        public let color: Color
    }

    /// A vertex attachment's vertices, laid out as Spine's runtimes keep them.
    public struct Vertices: Sendable {
        /// Per vertex, how many bones hold it and then those bones; empty when
        /// the vertices sit in the slot's bone.
        public let bones: [Int]
        /// Unweighted: x, y per vertex. Weighted: x, y, weight per bone per vertex.
        public let values: [CGFloat]
        /// Twice the vertex count.
        public let length: Int

        public var isWeighted: Bool { !bones.isEmpty }
    }

    /// An image on a bone. `offsets` are its corners in the bone's space and
    /// `uvs` where they lie in its image (0…1, y down), in this order:
    /// bottom right, bottom left, top left, top right.
    public struct Region: Sendable {
        public let offsets: [CGPoint]
        public let uvs: [CGPoint]
        public let color: Color
        /// Where its image lies in the rig's texture, in pixels, y down.
        public let frame: CGRect?
        /// As the skeleton places it on its bone.
        public let x, y, rotation, scaleX, scaleY, width, height: CGFloat

        /// The quad's two triangles.
        public static let triangles = [0, 1, 2, 2, 3, 0]
    }

    public struct Mesh: Sendable {
        public let vertices: Vertices
        /// Each vertex's place in its image (0…1, y down).
        public let uvs: [CGPoint]
        public let triangles: [Int]
        /// How many of the first vertices outline it.
        public let hull: Int
        public let color: Color
        /// Where its image lies in the rig's texture, in pixels, y down.
        public let frame: CGRect?
        public let width, height: CGFloat
    }

    /// A mask the slots after its own, up to and including `end`, draw within.
    public struct Clipping: Sendable {
        public let vertices: Vertices
        public let end: Int?
        public let color: Color
    }

    public struct Path: Sendable {
        public let vertices: Vertices
        /// Each curve's length from the path's start.
        public let lengths: [CGFloat]
        public let closed: Bool
        public let constantSpeed: Bool
    }

    public enum Attachment: Sendable {
        case region(Region)
        case mesh(Mesh)
        case clipping(Clipping)
        case path(Path)

        /// Its vertices, unless it's a region.
        public var vertices: Vertices? {
            switch self {
            case .region: nil
            case let .mesh(mesh): mesh.vertices
            case let .clipping(clipping): clipping.vertices
            case let .path(path): path.vertices
            }
        }
    }

    public struct Ik: Sendable {
        public let name: String
        public let order: Int
        public let bones: [Int]
        public let target: Int
        public let mix, softness, bendDirection: CGFloat
        public let compress, stretch, uniform: Bool
    }

    public struct TransformConstraint: Sendable {
        public let name: String
        public let order: Int
        public let bones: [Int]
        public let target: Int
        public let local, relative: Bool
        public let offsetRotation, offsetX, offsetY, offsetScaleX, offsetScaleY, offsetShearY: CGFloat
        public let mixRotate, mixX, mixY, mixScaleX, mixScaleY, mixShearY: CGFloat
    }

    public enum PositionMode: Sendable { case fixed, percent }
    public enum SpacingMode: Sendable { case length, fixed, percent, proportional }
    public enum RotateMode: Sendable { case tangent, chain, chainScale }

    public struct PathConstraint: Sendable {
        public let name: String
        public let order: Int
        public let bones: [Int]
        /// The slot showing the path.
        public let target: Int
        public let positionMode: PositionMode
        public let spacingMode: SpacingMode
        public let rotateMode: RotateMode
        public let offsetRotation, position, spacing, mixRotate, mixX, mixY: CGFloat
    }

    /// Spine 4.2's physics constraint: a bone that trails behind as the
    /// skeleton moves, springing back.
    public struct Physics: Sendable {
        public let name: String
        public let order: Int
        public let bone: Int
        public let x, y, rotate, scaleX, shearX: CGFloat
        public let limit, step, inertia, strength, damping, massInverse, wind, gravity, mix: CGFloat
    }

    public struct Timeline: Sendable {
        public enum Kind: Sendable {
            case rotate, translate, translateX, translateY, scale, scaleX, scaleY, shear, shearX, shearY
            case rgba, rgb, alpha, attachment, deform
        }

        /// A key's curve to the next: linear, stepped or an index into the samples.
        public static let linear = -1
        public static let stepped = -2

        public let kind: Kind
        /// The bone or slot it keys.
        public let target: Int
        /// Deform: the attachment it bends.
        public let attachment: Int
        public let times: [CGFloat]
        /// `width` values per key (deform: the vertex values, set up as runtimes
        /// keep them; colours: r, g, b, a).
        public let values: [CGFloat]
        public let width: Int
        /// How many values its curves ease (deform: one, from 0 to 1).
        public let channels: Int
        /// Attachment keys: the attachment shown from each key on.
        public let names: [Int?]
        /// Per key, `linear`, `stepped` or a bezier's index.
        public let curves: [Int]
        /// Per bezier and channel, spine-core 4.2's polyline: nine (time, value) pairs.
        public let samples: [CGFloat]
    }

    public struct Animation: Sendable {
        public let name: String
        public let duration: CGFloat
        public let timelines: [Timeline]
    }

    public let bones: [Bone]
    public let slots: [Slot]
    /// Every default-skin attachment; slots refer to them by index.
    public let attachments: [Attachment]
    public let attachmentNames: [String]
    /// Per slot, its attachments by name.
    public let skin: [[String: Int]]
    public let iks: [Ik]
    public let transforms: [TransformConstraint]
    public let paths: [PathConstraint]
    public let physics: [Physics]
    public let animations: [String: Animation]
    /// The physics constraints' reference scale (Spine's default is 100).
    public let referenceScale: CGFloat
    /// Where each image lies in the packed texture, in pixels, y down.
    public let atlas: [String: CGRect]
    public let textureURL: URL
    /// The JSON's top-level fields Spine doesn't define, as they were read.
    public let extras: [String: Any]
    /// Whether any part ever draws in a colour other than white (its alpha
    /// aside): slot and attachment colours, and colour keys.
    public let tintsColor: Bool

    private let boneIndex: [String: Int]
    private let slotIndex: [String: Int]

    // MARK: - Loading

    private struct Loading {
        var cache: [String: RigData] = [:]
        var load: @Sendable (String) -> RigData? = { bundled($0) }
    }

    private static let loading = Locked(Loading())

    /// Reads the rig `name` for `named(_:)`, the first time it's asked for.
    /// By default `bundled(_:)`; a game that packs its rigs another way
    /// (deflated, split into a skeleton and its places) sets its own.
    public static var loader: @Sendable (String) -> RigData? {
        get { loading.withLock { $0.load } }
        set {
            loading.withLock { loading in
                loading.load = newValue
                loading.cache.removeAll()
            }
        }
    }

    /// The rig `name`, read once by `loader` and kept.
    public static func named(_ name: String) -> RigData? {
        let (cached, load) = loading.withLock { ($0.cache[name], $0.load) }
        if let cached { return cached }
        guard let rig = load(name) else { return nil }
        return loading.withLock { loading in
            if let raced = loading.cache[name] { return raced }
            loading.cache[name] = rig
            return rig
        }
    }

    /// Forgets the rigs `forget` picks by name, so they're read again.
    public static func forget(where forget: (String) -> Bool) {
        loading.withLock { $0.cache = $0.cache.filter { !forget($0.key) } }
    }

    /// `Rig<name>.json` and its texture `Rig<name>.png` from `bundle`.
    public static func bundled(_ name: String, in bundle: Bundle = .main) -> RigData? {
        guard
            let url = bundle.url(forResource: "Rig\(name)", withExtension: "json"),
            let textureURL = bundle.url(forResource: "Rig\(name)", withExtension: "png"),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return RigData(json: json, textureURL: textureURL)
    }

    public func bone(named name: String) -> Int? { boneIndex[name] }
    public func slot(named name: String) -> Int? { slotIndex[name] }

    /// Slot `slot`'s attachment `name`.
    public func attachment(slot: Int, named name: String) -> Attachment? {
        skin[slot][name].map { attachments[$0] }
    }

    /// The fields Spine's JSON defines at its top level; the rest are `extras`.
    private static let spineKeys: Set<String> = [
        "skeleton", "bones", "slots", "ik", "transform", "path", "physics", "skins", "events", "animations",
    ]

    public init?(json: [String: Any], textureURL: URL) {
        guard let boneList = json["bones"] as? [[String: Any]], let slotList = json["slots"] as? [[String: Any]] else { return nil }
        self.textureURL = textureURL
        extras = json.filter { !Self.spineKeys.contains($0.key) }
        referenceScale = Self.number((json["skeleton"] as? [String: Any])?["referenceScale"], 100)

        var boneIndex: [String: Int] = [:]
        var bones: [Bone] = []
        for entry in boneList {
            let name = entry["name"] as? String ?? ""
            boneIndex[name] = bones.count
            bones.append(Bone(
                name: name,
                parent: (entry["parent"] as? String).flatMap { boneIndex[$0] },
                x: Self.number(entry["x"]),
                y: Self.number(entry["y"]),
                rotation: Self.number(entry["rotation"]),
                scaleX: Self.number(entry["scaleX"], 1),
                scaleY: Self.number(entry["scaleY"], 1),
                shearX: Self.number(entry["shearX"]),
                shearY: Self.number(entry["shearY"]),
                length: Self.number(entry["length"]),
                inherit: Self.inherit((entry["inherit"] ?? entry["transform"]) as? String)
            ))
        }
        self.bones = bones
        self.boneIndex = boneIndex

        var slotIndex: [String: Int] = [:]
        for (index, entry) in slotList.enumerated() {
            slotIndex[entry["name"] as? String ?? ""] = index
        }
        self.slotIndex = slotIndex

        // Attachments look their image up by `path`, else by name.
        var atlas: [String: CGRect] = [:]
        for (name, value) in json["atlas"] as? [String: [Double]] ?? [:] where value.count == 4 {
            atlas[name] = CGRect(x: value[0], y: value[1], width: value[2], height: value[3])
        }
        self.atlas = atlas

        var attachments: [Attachment] = []
        var attachmentNames: [String] = []
        var skin = Array(repeating: [String: Int](), count: slotList.count)
        for entry in json["skins"] as? [[String: Any]] ?? [] where (entry["name"] as? String ?? "default") == "default" {
            for (slotName, slotAttachments) in entry["attachments"] as? [String: [String: [String: Any]]] ?? [:] {
                guard let slot = slotIndex[slotName] else { continue }
                for name in slotAttachments.keys.sorted() {
                    guard
                        let map = slotAttachments[name],
                        let attachment = Self.attachment(map, name: name, atlas: atlas, bones: bones.count, slots: slotIndex)
                    else { continue }
                    skin[slot][name] = attachments.count
                    attachments.append(attachment)
                    attachmentNames.append(name)
                }
            }
        }
        self.attachments = attachments
        self.attachmentNames = attachmentNames
        self.skin = skin

        slots = slotList.enumerated().map { index, entry in
            let name = entry["attachment"] as? String
            return Slot(
                name: entry["name"] as? String ?? "",
                bone: boneIndex[entry["bone"] as? String ?? ""] ?? 0,
                attachment: name.flatMap { skin[index][$0] },
                attachmentName: name,
                color: Self.color(entry["color"] as? String)
            )
        }

        iks = (json["ik"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let target = boneIndex[entry["target"] as? String ?? ""] else { return nil }
            let constrained = (entry["bones"] as? [String] ?? []).compactMap { boneIndex[$0] }
            guard !constrained.isEmpty, constrained.count <= 2 else { return nil }
            return Ik(
                name: entry["name"] as? String ?? "",
                order: entry["order"] as? Int ?? 0,
                bones: constrained,
                target: target,
                mix: Self.number(entry["mix"], 1),
                softness: Self.number(entry["softness"]),
                bendDirection: (entry["bendPositive"] as? Bool ?? true) ? 1 : -1,
                compress: entry["compress"] as? Bool ?? false,
                stretch: entry["stretch"] as? Bool ?? false,
                uniform: entry["uniform"] as? Bool ?? false
            )
        }

        transforms = (json["transform"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let target = boneIndex[entry["target"] as? String ?? ""] else { return nil }
            let constrained = (entry["bones"] as? [String] ?? []).compactMap { boneIndex[$0] }
            guard !constrained.isEmpty else { return nil }
            let mixX = Self.number(entry["mixX"], 1), mixScaleX = Self.number(entry["mixScaleX"], 1)
            return TransformConstraint(
                name: entry["name"] as? String ?? "",
                order: entry["order"] as? Int ?? 0,
                bones: constrained,
                target: target,
                local: entry["local"] as? Bool ?? false,
                relative: entry["relative"] as? Bool ?? false,
                offsetRotation: Self.number(entry["rotation"]),
                offsetX: Self.number(entry["x"]),
                offsetY: Self.number(entry["y"]),
                offsetScaleX: Self.number(entry["scaleX"]),
                offsetScaleY: Self.number(entry["scaleY"]),
                offsetShearY: Self.number(entry["shearY"]),
                mixRotate: Self.number(entry["mixRotate"], 1),
                mixX: mixX,
                mixY: Self.number(entry["mixY"], mixX),
                mixScaleX: mixScaleX,
                mixScaleY: Self.number(entry["mixScaleY"], mixScaleX),
                mixShearY: Self.number(entry["mixShearY"], 1)
            )
        }

        paths = (json["path"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let target = slotIndex[entry["target"] as? String ?? ""] else { return nil }
            let constrained = (entry["bones"] as? [String] ?? []).compactMap { boneIndex[$0] }
            guard !constrained.isEmpty else { return nil }
            let positionMode: PositionMode = (entry["positionMode"] as? String)?.lowercased() == "fixed" ? .fixed : .percent
            let spacingMode: SpacingMode = switch (entry["spacingMode"] as? String)?.lowercased() {
            case "fixed": .fixed
            case "percent": .percent
            case "proportional": .proportional
            default: .length
            }
            let rotateMode: RotateMode = switch (entry["rotateMode"] as? String)?.lowercased() {
            case "chain": .chain
            case "chainscale": .chainScale
            default: .tangent
            }
            let mixX = Self.number(entry["mixX"], 1)
            return PathConstraint(
                name: entry["name"] as? String ?? "",
                order: entry["order"] as? Int ?? 0,
                bones: constrained,
                target: target,
                positionMode: positionMode,
                spacingMode: spacingMode,
                rotateMode: rotateMode,
                offsetRotation: Self.number(entry["rotation"]),
                position: Self.number(entry["position"]),
                spacing: Self.number(entry["spacing"]),
                mixRotate: Self.number(entry["mixRotate"], 1),
                mixX: mixX,
                mixY: Self.number(entry["mixY"], mixX)
            )
        }

        physics = (json["physics"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let bone = boneIndex[entry["bone"] as? String ?? ""] else { return nil }
            return Physics(
                name: entry["name"] as? String ?? "",
                order: entry["order"] as? Int ?? 0,
                bone: bone,
                x: Self.number(entry["x"]),
                y: Self.number(entry["y"]),
                rotate: Self.number(entry["rotate"]),
                scaleX: Self.number(entry["scaleX"]),
                shearX: Self.number(entry["shearX"]),
                limit: Self.number(entry["limit"], 5000),
                step: 1 / Self.number(entry["fps"], 60),
                inertia: Self.number(entry["inertia"], 1),
                strength: Self.number(entry["strength"], 100),
                damping: Self.number(entry["damping"], 1),
                massInverse: 1 / Self.number(entry["mass"], 1),
                wind: Self.number(entry["wind"]),
                gravity: Self.number(entry["gravity"]),
                mix: Self.number(entry["mix"], 1)
            )
        }

        var animations: [String: Animation] = [:]
        for (name, entry) in json["animations"] as? [String: [String: Any]] ?? [:] {
            var timelines: [Timeline] = []
            // Slots first, then bones, then deform, as Spine reads them:
            // a deform key applies only once the slot shows its attachment.
            let slotMaps = entry["slots"] as? [String: [String: [[String: Any]]]] ?? [:]
            for slotName in slotMaps.keys.sorted(by: { (slotIndex[$0] ?? 0) < (slotIndex[$1] ?? 0) }) {
                guard let slot = slotIndex[slotName], let maps = slotMaps[slotName] else { continue }
                for type in ["attachment", "rgba", "rgb", "alpha", "rgba2", "rgb2"] {
                    guard let keys = maps[type], !keys.isEmpty else { continue }
                    if type == "attachment" {
                        timelines.append(Self.attachmentTimeline(keys, slot: slot, skin: skin[slot]))
                    } else {
                        timelines.append(Self.colorTimeline(keys, type: type, slot: slot))
                    }
                }
            }
            let boneMaps = entry["bones"] as? [String: [String: [[String: Any]]]] ?? [:]
            for boneName in boneMaps.keys.sorted(by: { (boneIndex[$0] ?? 0) < (boneIndex[$1] ?? 0) }) {
                guard let bone = boneIndex[boneName], let maps = boneMaps[boneName] else { continue }
                for type in ["rotate", "translate", "translatex", "translatey", "scale", "scalex", "scaley", "shear", "shearx", "sheary"] {
                    guard let keys = maps[type], !keys.isEmpty else { continue }
                    timelines.append(Self.boneTimeline(keys, type: type, bone: bone))
                }
            }
            let deformSkins = entry["attachments"] as? [String: [String: [String: [String: [[String: Any]]]]]] ?? [:]
            for (skinName, slotMaps) in deformSkins where skinName == "default" {
                for slotName in slotMaps.keys.sorted(by: { (slotIndex[$0] ?? 0) < (slotIndex[$1] ?? 0) }) {
                    guard let slot = slotIndex[slotName], let attachmentMaps = slotMaps[slotName] else { continue }
                    for attachmentName in attachmentMaps.keys.sorted() {
                        guard
                            let keys = attachmentMaps[attachmentName]?["deform"], !keys.isEmpty,
                            let attachment = skin[slot][attachmentName],
                            let timeline = Self.deformTimeline(keys, slot: slot, attachment: attachment, in: attachments)
                        else { continue }
                        timelines.append(timeline)
                    }
                }
            }
            let duration = timelines.reduce(CGFloat(0)) { max($0, $1.times.last ?? 0) }
            animations[name] = Animation(name: name, duration: duration, timelines: timelines)
        }
        self.animations = animations

        func tinted(_ color: Color) -> Bool { color.r != 1 || color.g != 1 || color.b != 1 }
        tintsColor = slots.contains { tinted($0.color) }
            || attachments.contains {
                switch $0 {
                case let .region(region): tinted(region.color)
                case let .mesh(mesh): tinted(mesh.color)
                default: false
                }
            }
            || animations.values.contains { animation in
                animation.timelines.contains { timeline in
                    (timeline.kind == .rgba || timeline.kind == .rgb) && timeline.times.indices.contains { key in
                        (0..<3).contains { timeline.values[key * timeline.width + $0] != 1 }
                    }
                }
            }
    }

    // MARK: - Attachments

    private static func attachment(
        _ map: [String: Any], name: String, atlas: [String: CGRect], bones: Int, slots: [String: Int]
    ) -> Attachment? {
        let color = color(map["color"] as? String)
        let frame = atlas[map["path"] as? String ?? name]
        switch map["type"] as? String ?? "region" {
        case "region":
            let width = number(map["width"], 32), height = number(map["height"], 32)
            let scaleX = number(map["scaleX"], 1), scaleY = number(map["scaleY"], 1)
            let x = number(map["x"]), y = number(map["y"]), rotation = number(map["rotation"])
            // RegionAttachment.updateOffset for an untrimmed image.
            let localX = -width / 2 * scaleX, localY = -height / 2 * scaleY
            let localX2 = localX + width * scaleX, localY2 = localY + height * scaleY
            let radians = rotation * .pi / 180
            let cosine = cos(radians), sine = sin(radians)
            func corner(_ cx: CGFloat, _ cy: CGFloat) -> CGPoint {
                CGPoint(x: cx * cosine - cy * sine + x, y: cy * cosine + cx * sine + y)
            }
            return .region(Region(
                offsets: [corner(localX2, localY), corner(localX, localY), corner(localX, localY2), corner(localX2, localY2)],
                uvs: [CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)],
                color: color,
                frame: frame,
                x: x, y: y, rotation: rotation, scaleX: scaleX, scaleY: scaleY, width: width, height: height
            ))
        case "mesh":
            let regionUVs = numbers(map["uvs"])
            let uvs = stride(from: 0, to: regionUVs.count - 1, by: 2).map { CGPoint(x: regionUVs[$0], y: regionUVs[$0 + 1]) }
            return .mesh(Mesh(
                vertices: vertices(map, length: uvs.count * 2, bones: bones),
                uvs: uvs,
                triangles: map["triangles"] as? [Int] ?? [],
                hull: map["hull"] as? Int ?? 0,
                color: color,
                frame: frame,
                width: number(map["width"]),
                height: number(map["height"])
            ))
        case "clipping":
            let count = map["vertexCount"] as? Int ?? 0
            return .clipping(Clipping(
                vertices: vertices(map, length: count * 2, bones: bones),
                end: (map["end"] as? String).flatMap { slots[$0] },
                color: color
            ))
        case "path":
            let count = map["vertexCount"] as? Int ?? 0
            return .path(Path(
                vertices: vertices(map, length: count * 2, bones: bones),
                lengths: numbers(map["lengths"]),
                closed: map["closed"] as? Bool ?? false,
                constantSpeed: map["constantSpeed"] as? Bool ?? true
            ))
        default:
            return nil
        }
    }

    /// SkeletonJson.readVertices: more values than `length` means weighted.
    private static func vertices(_ map: [String: Any], length: Int, bones: Int) -> Vertices {
        let values = numbers(map["vertices"])
        guard values.count != length else { return Vertices(bones: [], values: values, length: length) }
        var boneList: [Int] = [], weights: [CGFloat] = []
        var i = 0
        while i < values.count {
            let count = Int(values[i])
            i += 1
            boneList.append(count)
            for _ in 0..<count {
                guard i + 3 < values.count else { break }
                boneList.append(min(max(Int(values[i]), 0), bones - 1))
                weights.append(contentsOf: [values[i + 1], values[i + 2], values[i + 3]])
                i += 4
            }
        }
        return Vertices(bones: boneList, values: weights, length: length)
    }

    /// Where `attachment`'s vertices lie in a texture `size` pixels big (0…1,
    /// y down): a region's corners in `Region.offsets`' order, a mesh's vertices.
    public func textureUVs(of attachment: Attachment, in size: CGSize) -> [CGPoint] {
        let local: [CGPoint], frame: CGRect?
        switch attachment {
        case let .region(region): (local, frame) = (region.uvs, region.frame)
        case let .mesh(mesh): (local, frame) = (mesh.uvs, mesh.frame)
        default: return []
        }
        guard let frame, size.width > 0, size.height > 0 else { return [] }
        return local.map {
            CGPoint(x: (frame.minX + $0.x * frame.width) / size.width, y: (frame.minY + $0.y * frame.height) / size.height)
        }
    }

    // MARK: - Timelines

    private static func boneTimeline(_ keys: [[String: Any]], type: String, bone: Int) -> Timeline {
        let kind: Timeline.Kind
        let fields: [String]
        let fallback: CGFloat
        switch type {
        case "rotate": (kind, fields, fallback) = (.rotate, ["value"], 0)
        case "translate": (kind, fields, fallback) = (.translate, ["x", "y"], 0)
        case "translatex": (kind, fields, fallback) = (.translateX, ["value"], 0)
        case "translatey": (kind, fields, fallback) = (.translateY, ["value"], 0)
        case "scale": (kind, fields, fallback) = (.scale, ["x", "y"], 1)
        case "scalex": (kind, fields, fallback) = (.scaleX, ["value"], 1)
        case "scaley": (kind, fields, fallback) = (.scaleY, ["value"], 1)
        case "shear": (kind, fields, fallback) = (.shear, ["x", "y"], 0)
        case "shearx": (kind, fields, fallback) = (.shearX, ["value"], 0)
        default: (kind, fields, fallback) = (.shearY, ["value"], 0)
        }
        let values = keys.flatMap { key in fields.map { number(key[$0], fallback) } }
        return curveTimeline(kind, target: bone, keys: keys, values: values, width: fields.count, channels: fields.count)
    }

    private static func colorTimeline(_ keys: [[String: Any]], type: String, slot: Int) -> Timeline {
        let kind: Timeline.Kind
        let values: [CGFloat]
        switch type {
        case "alpha":
            kind = .alpha
            values = keys.map { number($0["value"]) }
        case "rgb", "rgb2":
            kind = .rgb
            values = keys.flatMap { key in
                let c = color(key[type == "rgb" ? "color" : "light"] as? String)
                return [c.r, c.g, c.b]
            }
        default:
            kind = .rgba
            values = keys.flatMap { key in
                let c = color(key[type == "rgba" ? "color" : "light"] as? String)
                return [c.r, c.g, c.b, c.a]
            }
        }
        let width = kind == .alpha ? 1 : kind == .rgb ? 3 : 4
        // Two-colour keys ease their dark colour too, whose handles come after
        // the light's; only the light colour is kept.
        return curveTimeline(kind, target: slot, keys: keys, values: values, width: width, channels: width)
    }

    private static func attachmentTimeline(_ keys: [[String: Any]], slot: Int, skin: [String: Int]) -> Timeline {
        Timeline(
            kind: .attachment, target: slot, attachment: -1,
            times: keys.map { number($0["time"]) },
            values: [], width: 0, channels: 0,
            names: keys.map { ($0["name"] as? String).flatMap { skin[$0] } },
            curves: [], samples: []
        )
    }

    /// SkeletonJson's deform keys: offsets from the setup vertices, stored as
    /// the vertices themselves for unweighted meshes and as offsets for weighted ones.
    private static func deformTimeline(_ keys: [[String: Any]], slot: Int, attachment: Int, in attachments: [Attachment]) -> Timeline? {
        guard let vertices = attachments[attachment].vertices else { return nil }
        let weighted = vertices.isWeighted
        let length = weighted ? vertices.values.count / 3 * 2 : vertices.values.count
        var values: [CGFloat] = []
        values.reserveCapacity(length * keys.count)
        for key in keys {
            var deform = Array(repeating: CGFloat(0), count: length)
            let offsets = numbers(key["vertices"])
            if offsets.isEmpty {
                if !weighted { deform = vertices.values }
            } else {
                let start = key["offset"] as? Int ?? 0
                for (i, value) in offsets.enumerated() where start + i < length {
                    deform[start + i] = value
                }
                if !weighted {
                    for i in 0..<length { deform[i] += vertices.values[i] }
                }
            }
            values.append(contentsOf: deform)
        }
        return curveTimeline(.deform, target: slot, attachment: attachment, keys: keys, values: values, width: length, channels: 1)
    }

    /// Reads each key's curve: spine-core 4.2's per-channel handles, each
    /// as a polyline.
    private static func curveTimeline(
        _ kind: Timeline.Kind, target: Int, attachment: Int = -1, keys: [[String: Any]], values: [CGFloat], width: Int, channels: Int
    ) -> Timeline {
        let times = keys.map { number($0["time"]) }
        var curves: [Int] = []
        var samples: [CGFloat] = []
        var bezier = 0
        for (i, key) in keys.enumerated() {
            if (key["curve"] as? String) == "stepped" {
                curves.append(Timeline.stepped)
                continue
            }
            let handles = numbers(key["curve"])
            guard i + 1 < keys.count, handles.count >= channels * 4 else {
                curves.append(Timeline.linear)
                continue
            }
            let t0 = times[i], t1 = times[i + 1]
            func value(_ key: Int, _ channel: Int) -> CGFloat {
                kind == .deform ? CGFloat(key - i) : values[key * width + channel]
            }
            for channel in 0..<channels {
                let h = channel * 4
                samples.append(contentsOf: polyline(
                    t0, value(i, channel), handles[h], handles[h + 1], handles[h + 2], handles[h + 3], t1, value(i + 1, channel)
                ))
            }
            curves.append(bezier)
            bezier += 1
        }
        return Timeline(
            kind: kind, target: target, attachment: attachment, times: times, values: values, width: width, channels: channels,
            names: [], curves: curves, samples: samples
        )
    }

    /// CurveTimeline.setBezier (spine-core 4.2).
    private static func polyline(
        _ time1: CGFloat, _ value1: CGFloat, _ cx1: CGFloat, _ cy1: CGFloat, _ cx2: CGFloat, _ cy2: CGFloat, _ time2: CGFloat, _ value2: CGFloat
    ) -> [CGFloat] {
        let tmpx = (time1 - cx1 * 2 + cx2) * 0.03, tmpy = (value1 - cy1 * 2 + cy2) * 0.03
        let dddx = ((cx1 - cx2) * 3 - time1 + time2) * 0.006, dddy = ((cy1 - cy2) * 3 - value1 + value2) * 0.006
        var ddx = tmpx * 2 + dddx, ddy = tmpy * 2 + dddy
        var dx = (cx1 - time1) * 0.3 + tmpx + dddx * 0.16666667, dy = (cy1 - value1) * 0.3 + tmpy + dddy * 0.16666667
        var x = time1 + dx, y = value1 + dy
        var points: [CGFloat] = []
        for _ in 0..<9 {
            points.append(x)
            points.append(y)
            dx += ddx
            dy += ddy
            ddx += dddx
            ddy += dddy
            x += dx
            y += dy
        }
        return points
    }

    // MARK: - Values

    static func number(_ value: Any?, _ fallback: CGFloat = 0) -> CGFloat {
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
        return fallback
    }

    private static func numbers(_ value: Any?) -> [CGFloat] {
        (value as? [Any] ?? []).map { number($0) }
    }

    /// A colour as Spine writes it: `rrggbbaa`, or `rrggbb` opaque.
    public static func color(_ hex: String?) -> Color {
        guard let hex, hex.count >= 6, let value = UInt32(hex.prefix(8), radix: 16) else { return .white }
        let full = hex.count >= 8 ? value : value << 8 | 0xFF
        return Color(
            r: CGFloat(full >> 24 & 0xFF) / 255,
            g: CGFloat(full >> 16 & 0xFF) / 255,
            b: CGFloat(full >> 8 & 0xFF) / 255,
            a: CGFloat(full & 0xFF) / 255
        )
    }

    private static func inherit(_ name: String?) -> Inherit {
        switch name?.lowercased() {
        case "onlytranslation": .onlyTranslation
        case "norotationorreflection": .noRotationOrReflection
        case "noscale": .noScale
        case "noscaleorreflection": .noScaleOrReflection
        default: .normal
        }
    }
}

// MARK: - Sampling keys

public nonisolated extension RigData.Timeline {
    /// Channel `channel` at `time` (held before the first key and after the
    /// last), eased along the channel's polyline.
    func value(at time: CGFloat, channel: Int) -> CGFloat {
        guard let first = times.first else { return 0 }
        if time < first { return values[channel] }
        let last = times.count - 1
        if time >= times[last] { return values[last * width + channel] }
        let k = frame(time)
        return value(k, time, channel: channel, values[k * width + channel], values[(k + 1) * width + channel])
    }

    /// Eases from `v0` at key `k` to `v1` at the next key.
    internal func value(_ k: Int, _ time: CGFloat, channel: Int, _ v0: CGFloat, _ v1: CGFloat) -> CGFloat {
        let t0 = times[k], t1 = times[k + 1]
        let curve = curves[k]
        switch curve {
        case Self.linear: return v0 + (time - t0) / (t1 - t0) * (v1 - v0)
        case Self.stepped: return v0
        default: break
        }
        // CurveTimeline.getBezierValue (4.2).
        let s = (curve * channels + channel) * 18
        if samples[s] > time { return v0 + (time - t0) / (samples[s] - t0) * (samples[s + 1] - v0) }
        var i = s + 2
        while i < s + 18 {
            if samples[i] >= time {
                let x = samples[i - 2], y = samples[i - 1]
                return y + (time - x) / (samples[i] - x) * (samples[i + 1] - y)
            }
            i += 2
        }
        let x = samples[s + 16], y = samples[s + 17]
        return y + (time - x) / (t1 - x) * (v1 - y)
    }

    /// The last key at or before `time` (which is before the last key).
    internal func frame(_ time: CGFloat) -> Int {
        var low = 0, high = times.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if times[middle] <= time { low = middle } else { high = middle }
        }
        return low
    }
}

public nonisolated extension RigData {
    /// How far `animation` moves `bone` along y from its setup place at `time`
    /// (its translate keys), in the skeleton's units.
    func lift(of bone: Int, in animation: String, at time: CGFloat) -> CGFloat {
        guard let animation = animations[animation] else { return 0 }
        return animation.timelines.reduce(CGFloat(0)) { sum, timeline in
            guard timeline.target == bone else { return sum }
            switch timeline.kind {
            case .translate: return sum + timeline.value(at: time, channel: 1)
            case .translateY: return sum + timeline.value(at: time, channel: 0)
            default: return sum
            }
        }
    }

    /// The highest `animation`'s keys lift `bone` (0 if they never lift it).
    func peakLift(of bone: Int, in animation: String) -> CGFloat {
        guard let animation = animations[animation] else { return 0 }
        var peak: CGFloat = 0
        for timeline in animation.timelines where timeline.target == bone {
            switch timeline.kind {
            case .translate: for k in timeline.times.indices { peak = max(peak, timeline.values[k * 2 + 1]) }
            case .translateY: for value in timeline.values { peak = max(peak, value) }
            default: break
            }
        }
        return peak
    }
}
