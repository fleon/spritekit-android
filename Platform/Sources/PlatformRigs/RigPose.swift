#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// One rig in motion, as Spine's runtimes pose it each frame: the animation
/// state (tracks of animations played and queued, crossfading from what
/// played before, layered over one another; `AnimationState.update`, then
/// `apply`), then the skeleton (`Skeleton.update`, `updateWorldTransform`):
/// bones in every inherit mode, IK, transform, path and physics constraints,
/// slot colours, attachments and deformed vertices.
///
/// Positions are in the rig's units times `scale` (what a JSON loader would
/// scale at load, applied here on output, which poses identically: every
/// length the loader scales is scaled alike), y up, relative to `origin`.
public nonisolated final class RigPose {
    public struct Transform: Equatable, Sendable {
        public var a: CGFloat = 1, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 1
        public var x: CGFloat = 0, y: CGFloat = 0

        public init(a: CGFloat = 1, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 1, x: CGFloat = 0, y: CGFloat = 0) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.x = x
            self.y = y
        }
    }

    /// Whose behaviour to follow where spine-core 4.2 and spine-c 3.6 differ.
    /// 4.2 is the whole runtime. 3.6 (for skeletons made for it, played as a
    /// cocos2d-x game played them) eases curves its way, turns rotate keys
    /// the short way, treats layered tracks before their first key, queue
    /// delays, loop completion and path edge cases as 3.6 did, poses bones,
    /// IK and paths by 3.6's maths, and plays without crossfades, physics or
    /// transform constraints, as that game did.
    public enum Runtime: Sendable {
        case spine36, spine42
    }

    /// A track's place in the queue (`TrackEntry`): what it plays and how.
    public final class Entry {
        public let track: Int
        public let name: String
        public let animation: RigData.Animation
        public let loop: Bool
        /// How fast it plays; negative plays it backwards, down to `stop`.
        public var timeScale: CGFloat = 1
        /// How long it takes over from what played before.
        public var mixDuration: CGFloat = 0
        /// How much of it shows (1: all of it).
        public var alpha: CGFloat = 1
        /// Seconds into it, from when it starts.
        public var trackTime: CGFloat = 0
        /// How long it waits to start after being queued.
        public var delay: CGFloat = 0
        /// Where it stops when played backwards.
        public var stop: CGFloat = 0
        /// Scales how far `RigPose.riseBone` lifts along y.
        public var rise: CGFloat = 1
        /// Played once, it hands over to this (looping) as it ends.
        public var then: String?

        var trackLast: CGFloat = -1
        var nextTrackLast: CGFloat = -1
        var animationLast: CGFloat = -1
        var nextAnimationLast: CGFloat = -1
        let trackEnd = CGFloat(Int32.max)
        var mixTime: CGFloat = 0
        var interruptAlpha: CGFloat = 1
        var totalAlpha: CGFloat = 0
        var next: Entry?
        var mixingFrom: Entry?
        weak var mixingTo: Entry?
        var modes: [Mode] = []
        var holdMix: [Entry?] = []
        var rotations: [CGFloat] = []

        init(track: Int, name: String, animation: RigData.Animation, loop: Bool) {
            self.track = track
            self.name = name
            self.animation = animation
            self.loop = loop
        }

        /// Where in its animation it is.
        public var animationTime: CGFloat {
            let duration = animation.duration
            if loop { return duration == 0 ? 0 : trackTime.truncatingRemainder(dividingBy: duration) }
            return max(min(trackTime, duration), timeScale < 0 ? stop : -.infinity)
        }

        /// Whether it has played to its end (or, backwards, down to `stop`).
        var isEnded: Bool {
            timeScale < 0 ? trackTime <= stop : trackTime >= animation.duration
        }

        /// AnimationState's TrackEntry.getTrackComplete.
        var trackComplete: CGFloat {
            let duration = animation.duration
            if duration != 0 {
                if loop { return duration * (1 + (trackTime / duration).rounded(.towardZero)) }
                if trackTime < duration { return duration }
            }
            return trackTime
        }
    }

    private struct BoneState {
        var x, y, rotation, scaleX, scaleY, shearX, shearY: CGFloat
        var ax: CGFloat = 0, ay: CGFloat = 0, arotation: CGFloat = 0, ascaleX: CGFloat = 1, ascaleY: CGFloat = 1
        var ashearX: CGFloat = 0, ashearY: CGFloat = 0
        var appliedValid = false
        var world = Transform()
    }

    private struct SlotState {
        var color: RigData.Color
        var attachment: Int?
        /// Deformed vertex values (see `RigData.Timeline.values`), the first `deformCount` in use.
        var deform: [CGFloat]
        var deformCount = 0
        var attachmentState = 0
    }

    /// A physics constraint's state (PhysicsConstraint's fields).
    private struct Trail {
        var ux: CGFloat = 0, uy: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0, tx: CGFloat = 0, ty: CGFloat = 0
        var xOffset: CGFloat = 0, xVelocity: CGFloat = 0, yOffset: CGFloat = 0, yVelocity: CGFloat = 0
        var rotateOffset: CGFloat = 0, rotateVelocity: CGFloat = 0, scaleOffset: CGFloat = 0, scaleVelocity: CGFloat = 0
        var remaining: CGFloat = 0, lastTime: CGFloat = 0
        var reset = true
    }

    /// MixBlend.
    enum Blend {
        case setup, first, replace, add
    }

    /// AnimationState's timeline modes (3.6 knew the first three).
    enum Mode: UInt8 {
        case subsequent, first, holdSubsequent, holdFirst, holdMix
    }

    private enum EventKind {
        case start, interrupt, end, dispose, complete
    }

    private enum Update {
        case bone(Int), ik(Int), transform(Int), path(Int), physics(Int)
    }

    public let data: RigData
    public let scale: CGFloat
    public let runtime: Runtime
    /// Speeds every track up or slows it down (AnimationState.timeScale).
    public var timeScale: CGFloat = 1
    /// The skeleton's colour, multiplied into every slot's.
    public var skeletonColor = RigData.Color.white
    /// Where the skeleton stands, in its units (Skeleton.x, y): what physics
    /// trails behind as it moves. Every position read back is relative to it.
    public var origin = CGPoint.zero
    /// How long an animation takes over from another when nothing says
    /// (AnimationStateData.defaultMix).
    public var defaultMix: CGFloat = 0
    /// The bone whose y keys `Entry.rise` scales (one that carries the whole
    /// rig off the ground, say).
    public var riseBone: Int?

    /// AnimationState's listeners, called as spine-core calls them: during
    /// `advance`, or from `setAnimation` for what it starts and replaces.
    /// Each gets the track and the animation's name.
    public var onStart: ((Int, String) -> Void)?
    public var onInterrupt: ((Int, String) -> Void)?
    public var onEnd: ((Int, String) -> Void)?
    public var onComplete: ((Int, String) -> Void)?

    private var mixes: [String: CGFloat] = [:]
    private var bones: [BoneState]
    private var slots: [SlotState]
    private var children: [[Int]]
    private var updates: [Update] = []
    private var resets: [Int] = []
    private var trails: [Trail]
    /// Skeleton.time.
    private var time: CGFloat = 0

    private var tracks: [Entry?] = []
    private var queue: [(EventKind, Entry)] = []
    private var draining = false
    private var animationsChanged = false
    private var claimed = Set<Int>()
    private var unkeyedState = 0
    /// Each animation's property IDs per timeline, and all of them.
    private var properties: [String: (ids: [[Int]], all: Set<Int>)] = [:]

    private var vertexBuffer: [CGFloat] = []
    private var pathSpaces: [CGFloat] = []
    private var pathLengths: [CGFloat] = []
    private var pathPositions: [CGFloat] = []
    private var pathWorld: [CGFloat] = []
    private var pathCurves: [CGFloat] = []
    private var pathSegments = [CGFloat](repeating: 0, count: 10)

    public init(data: RigData, scale: CGFloat = 1, runtime: Runtime = .spine42) {
        self.data = data
        self.scale = scale
        self.runtime = runtime
        bones = data.bones.map {
            BoneState(x: $0.x, y: $0.y, rotation: $0.rotation, scaleX: $0.scaleX, scaleY: $0.scaleY, shearX: $0.shearX, shearY: $0.shearY)
        }
        var children = Array(repeating: [Int](), count: data.bones.count)
        for (index, bone) in data.bones.enumerated() {
            if let parent = bone.parent { children[parent].append(index) }
        }
        self.children = children
        var deformSizes = Array(repeating: 0, count: data.slots.count)
        for animation in data.animations.values {
            for timeline in animation.timelines where timeline.kind == .deform {
                deformSizes[timeline.target] = max(deformSizes[timeline.target], timeline.width)
            }
        }
        slots = data.slots.enumerated().map { index, slot in
            SlotState(color: slot.color, attachment: slot.attachment, deform: Array(repeating: 0, count: deformSizes[index]))
        }
        trails = Array(repeating: Trail(), count: runtime == .spine42 ? data.physics.count : 0)
        if runtime == .spine42 { updateCache42() } else { updateCache36() }
        updateWorldTransform()
    }

    // MARK: - Playing

    /// Sets how long `from` takes to hand over to `to` (AnimationStateData.setMix).
    public func setMix(from: String, to: String, duration: CGFloat) {
        mixes["\(from)\u{0}\(to)"] = duration
    }

    private func mix(from: Entry?, to name: String) -> CGFloat {
        guard runtime == .spine42, let from else { return 0 }
        return mixes["\(from.name)\u{0}\(name)"] ?? defaultMix
    }

    /// Plays `name` on `track` now, dropping whatever was queued there, and
    /// crossfades from what played (AnimationState.setAnimation).
    @discardableResult
    public func setAnimation(_ track: Int, _ name: String, loop: Bool) -> Entry? {
        guard let animation = data.animations[name] else { return nil }
        var interrupt = true
        var current = expand(to: track)
        if let entry = current {
            if entry.nextTrackLast == -1 {
                // Don't mix from an entry that was never applied.
                tracks[track] = entry.mixingFrom
                enqueue(.interrupt, entry)
                enqueue(.end, entry)
                disposeNext(entry)
                current = entry.mixingFrom
                interrupt = false
            } else {
                disposeNext(entry)
            }
        }
        let entry = makeEntry(track, name, animation, loop: loop, last: current)
        setCurrent(track, entry, interrupt: interrupt)
        drain()
        return entry
    }

    /// Queues `name` on `track`, `delay` seconds after the last queued entry
    /// starts; when `delay` ≤ 0, that much before it completes, less its mix
    /// (AnimationState.addAnimation).
    @discardableResult
    public func addAnimation(_ track: Int, _ name: String, loop: Bool, delay: CGFloat = 0) -> Entry? {
        guard let animation = data.animations[name] else { return nil }
        var last = expand(to: track)
        while let next = last?.next { last = next }
        let entry = makeEntry(track, name, animation, loop: loop, last: last)
        var delay = delay
        if let last {
            last.next = entry
            if delay <= 0 {
                let duration = last.animation.duration
                switch runtime {
                case .spine36:
                    delay = duration != 0 ? delay + duration * (1 + (last.trackTime / duration).rounded(.towardZero)) : 0
                case .spine42:
                    delay = max(delay + last.trackComplete - entry.mixDuration, 0)
                }
            }
        } else {
            setCurrent(track, entry, interrupt: true)
            drain()
            if runtime == .spine42, delay < 0 { delay = 0 }
        }
        entry.delay = delay
        return entry
    }

    /// Plays `name` from `start` seconds in at `rate`, looping or once and
    /// then `next` (looping), crossfading from what played over `mix` seconds
    /// (`defaultMix` if not given). `rise` scales how far `riseBone` lifts
    /// (0 keeps it down); a negative `rate` plays it backwards, down to `stop`.
    @discardableResult
    public func play(
        _ name: String, loop: Bool, rate: CGFloat = 1, from start: CGFloat = 0, until stop: CGFloat = 0,
        then next: String? = nil, rise: CGFloat = 1, mix: CGFloat? = nil, track: Int = 0
    ) -> Entry? {
        guard let entry = setAnimation(track, name, loop: loop) else { return nil }
        if let mix, runtime == .spine42 { entry.mixDuration = mix }
        entry.timeScale = rate
        entry.trackTime = start
        entry.stop = stop
        entry.then = next
        entry.rise = rise
        return entry
    }

    public func clearTrack(_ track: Int) {
        guard track < tracks.count, let current = tracks[track] else { return }
        enqueue(.end, current)
        disposeNext(current)
        var entry = current
        while let from = entry.mixingFrom {
            enqueue(.end, from)
            entry.mixingFrom = nil
            from.mixingTo = nil
            entry = from
        }
        tracks[track] = nil
        drain()
    }

    public func clearTracks() {
        let wasDraining = draining
        draining = true
        for track in tracks.indices { clearTrack(track) }
        tracks.removeAll()
        draining = wasDraining
        drain()
    }

    /// What `track` plays now.
    public func current(track: Int) -> Entry? {
        track < tracks.count ? tracks[track] : nil
    }

    /// What `track` plays now, by name.
    public func animationName(track: Int) -> String? {
        current(track: track)?.name
    }

    /// What the first track plays.
    public var playing: String? { animationName(track: 0) }

    /// Whether any track is playing (or waiting to).
    public var isAnimating: Bool { tracks.contains { $0 != nil } }

    /// Whether every trailing part has come to rest.
    public var isSettled: Bool {
        let rest: CGFloat = 1e-4
        return trails.allSatisfy {
            abs($0.xVelocity) < rest && abs($0.yVelocity) < rest && abs($0.rotateVelocity) < rest && abs($0.scaleVelocity) < rest
                && abs($0.xOffset) < rest && abs($0.yOffset) < rest && abs($0.rotateOffset) < rest && abs($0.scaleOffset) < rest
        }
    }

    /// Moves time on by `delta` seconds and poses the rig.
    public func advance(_ delta: CGFloat) {
        update(delta * timeScale)
        apply()
        time += delta
        updateWorldTransform()
    }

    // MARK: - Reading the pose

    public var slotCount: Int { slots.count }

    /// The attachment `slot` shows, an index into `data.attachments`.
    public func attachmentIndex(slot: Int) -> Int? { slots[slot].attachment }

    public func attachment(slot: Int) -> RigData.Attachment? {
        slots[slot].attachment.map { data.attachments[$0] }
    }

    public func attachmentName(slot: Int) -> String? {
        slots[slot].attachment.map { data.attachmentNames[$0] }
    }

    /// The slot's own colour, as its keys set it.
    public func slotColor(_ slot: Int) -> RigData.Color { slots[slot].color }

    /// The tint `slot` draws with: skeleton × slot × attachment colour. A
    /// renderer multiplies in its node's colour and skips the slot if alpha is 0.
    public func color(slot: Int) -> RigData.Color {
        var color = skeletonColor
        let own = slots[slot].color
        color.r *= own.r
        color.g *= own.g
        color.b *= own.b
        color.a *= own.a
        let tint: RigData.Color
        switch attachment(slot: slot) {
        case let .region(region)?: tint = region.color
        case let .mesh(mesh)?: tint = mesh.color
        default: return color
        }
        color.r *= tint.r
        color.g *= tint.g
        color.b *= tint.b
        color.a *= tint.a
        return color
    }

    /// Where the vertices of `slot`'s attachment lie: a region's four corners
    /// (in `RigData.Region`'s order), a mesh's vertices, a clipping polygon or
    /// a path's points. False when it shows nothing.
    public func worldVertices(slot: Int, into points: inout [CGPoint]) -> Bool {
        guard let index = slots[slot].attachment else { return false }
        let vertices: RigData.Vertices
        switch data.attachments[index] {
        case let .region(region):
            let t = bones[data.slots[slot].bone].world
            let tx = t.x - origin.x, ty = t.y - origin.y
            resize(&points, to: 4)
            for (i, offset) in region.offsets.enumerated() {
                points[i] = CGPoint(
                    x: (offset.x * t.a + offset.y * t.b + tx) * scale,
                    y: (offset.x * t.c + offset.y * t.d + ty) * scale
                )
            }
            return true
        case let .mesh(mesh): vertices = mesh.vertices
        case let .clipping(clipping): vertices = clipping.vertices
        case let .path(path): vertices = path.vertices
        }
        if vertexBuffer.count < vertices.length { vertexBuffer = Array(repeating: 0, count: vertices.length) }
        // Each bone taken relative to `origin` before weighting: weights may
        // sum to 0.9999, and that share of a far origin would fling the vertex.
        computeWorldVertices(vertices, slot: slot, start: 0, count: vertices.length, into: &vertexBuffer, offset: 0, stride: 2, relative: true)
        let count = vertices.length / 2
        resize(&points, to: count)
        for i in 0..<count {
            points[i] = CGPoint(x: vertexBuffer[i * 2] * scale, y: vertexBuffer[i * 2 + 1] * scale)
        }
        return true
    }

    /// The bone's world transform, its place relative to `origin` and scaled.
    public func boneTransform(_ bone: Int) -> Transform {
        var t = bones[bone].world
        t.x = (t.x - origin.x) * scale
        t.y = (t.y - origin.y) * scale
        return t
    }

    /// The bone `name`'s world transform (`findBone`).
    public func boneTransform(named name: String) -> Transform? {
        data.bone(named: name).map(boneTransform)
    }

    /// How far the bone's own keys stretch it from its setup scale (a face
    /// squinting or blinking), apart from what it inherits.
    public func squash(of bone: Int) -> CGSize {
        let local = bones[bone], base = data.bones[bone]
        return CGSize(width: base.scaleX != 0 ? local.scaleX / base.scaleX : 1, height: base.scaleY != 0 ? local.scaleY / base.scaleY : 1)
    }

    private func resize(_ points: inout [CGPoint], to count: Int) {
        if points.count != count { points = Array(repeating: .zero, count: count) }
    }

    // MARK: - AnimationState

    private func makeEntry(_ track: Int, _ name: String, _ animation: RigData.Animation, loop: Bool, last: Entry?) -> Entry {
        let entry = Entry(track: track, name: name, animation: animation, loop: loop)
        entry.mixDuration = mix(from: last, to: name)
        return entry
    }

    private func expand(to index: Int) -> Entry? {
        if index < tracks.count { return tracks[index] }
        tracks.append(contentsOf: Array(repeating: nil, count: index + 1 - tracks.count))
        return nil
    }

    private func setCurrent(_ index: Int, _ current: Entry, interrupt: Bool) {
        let from = expand(to: index)
        tracks[index] = current
        if let from {
            if interrupt { enqueue(.interrupt, from) }
            current.mixingFrom = from
            from.mixingTo = current
            current.mixTime = 0
            // Keeps the share of an interrupted crossfade.
            if from.mixingFrom != nil, from.mixDuration > 0 { current.interruptAlpha *= min(1, from.mixTime / from.mixDuration) }
            from.rotations.removeAll()
        }
        enqueue(.start, current)
    }

    private func disposeNext(_ entry: Entry) {
        var next = entry.next
        while let entry = next {
            enqueue(.dispose, entry)
            next = entry.next
        }
        entry.next = nil
    }

    private func enqueue(_ event: EventKind, _ entry: Entry) {
        queue.append((event, entry))
        if event == .start || event == .end { animationsChanged = true }
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        var i = 0
        while i < queue.count {
            let (event, entry) = queue[i]
            switch event {
            case .start: onStart?(entry.track, entry.name)
            case .interrupt: onInterrupt?(entry.track, entry.name)
            case .end: onEnd?(entry.track, entry.name)
            case .complete: onComplete?(entry.track, entry.name)
            case .dispose: break
            }
            i += 1
        }
        queue.removeAll(keepingCapacity: true)
        draining = false
    }

    private func update(_ delta: CGFloat) {
        for i in tracks.indices {
            guard let current = tracks[i] else { continue }
            current.animationLast = current.nextAnimationLast
            current.trackLast = current.nextTrackLast
            var currentDelta = delta * current.timeScale
            if current.delay > 0 {
                current.delay -= currentDelta
                if current.delay > 0 { continue }
                currentDelta = -current.delay
                current.delay = 0
            }
            if let next = current.next {
                // Once the next entry's delay passes, it takes over, keeping the leftover time.
                let nextTime = current.trackLast - next.delay
                if nextTime >= 0 {
                    next.delay = 0
                    switch runtime {
                    case .spine36: next.trackTime = nextTime + delta
                    case .spine42: next.trackTime += current.timeScale == 0 ? 0 : (nextTime / current.timeScale + delta) * next.timeScale
                    }
                    current.trackTime += currentDelta
                    setCurrent(i, next, interrupt: true)
                    var entry = next
                    while let from = entry.mixingFrom {
                        entry.mixTime += runtime == .spine36 ? currentDelta : delta
                        entry = from
                    }
                    continue
                }
            } else if current.trackLast >= current.trackEnd, current.mixingFrom == nil {
                tracks[i] = nil
                enqueue(.end, current)
                disposeNext(current)
                continue
            }
            if current.mixingFrom != nil, updateMixingFrom(current, delta) {
                // Once every entry it mixes from is done, they all end.
                var from = current.mixingFrom
                current.mixingFrom = nil
                from?.mixingTo = nil
                while let entry = from {
                    enqueue(.end, entry)
                    from = entry.mixingFrom
                }
            }
            current.trackTime += currentDelta
            // An animation played once with another to follow hands over the
            // moment it ends, crossfading from where it stopped.
            if let then = current.then, !current.loop, current.next == nil, current.isEnded,
               let animation = data.animations[then] {
                current.then = nil
                let entry = makeEntry(i, then, animation, loop: true, last: current)
                setCurrent(i, entry, interrupt: true)
                entry.mixTime = delta
            }
        }
        drain()
    }

    /// Whether every entry `to` mixes from is done; with no mix time, each
    /// is applied for exactly one frame (to return what it keyed to the setup pose).
    private func updateMixingFrom(_ to: Entry, _ delta: CGFloat) -> Bool {
        guard let from = to.mixingFrom else { return true }
        let finished = updateMixingFrom(from, delta)
        let applied = runtime == .spine36 ? to.mixTime > 0 : to.nextTrackLast != -1
        if runtime == .spine42 {
            from.animationLast = from.nextAnimationLast
            from.trackLast = from.nextTrackLast
        }
        if applied, to.mixTime >= to.mixDuration {
            if runtime == .spine36 || from.totalAlpha == 0 || to.mixDuration == 0 {
                to.mixingFrom = from.mixingFrom
                from.mixingFrom?.mixingTo = to
                to.interruptAlpha = from.interruptAlpha
                enqueue(.end, from)
            }
            return finished
        }
        if runtime == .spine36 {
            from.animationLast = from.nextAnimationLast
            from.trackLast = from.nextTrackLast
        }
        from.trackTime += delta * from.timeScale
        to.mixTime += delta
        return false
    }

    private func apply() {
        if animationsChanged { updateModes() }
        for i in tracks.indices {
            guard let current = tracks[i], current.delay <= 0 else { continue }
            switch runtime {
            case .spine36: apply36(current, track: i)
            case .spine42: apply42(current, track: i)
            }
            queueComplete(current, current.animationTime)
            current.nextAnimationLast = current.animationTime
            current.nextTrackLast = current.trackTime
        }
        if runtime == .spine42 {
            // Slots that only an animation mixing out keyed go back to their
            // setup attachment (so deform keys saw theirs meanwhile).
            let setupState = unkeyedState + Self.setupState
            for slot in slots.indices where slots[slot].attachmentState == setupState {
                setAttachment(slot, data.slots[slot].attachment)
            }
            unkeyedState += 2
        }
        drain()
    }

    private static let setupState = 1
    private static let currentState = 2

    /// AnimationState.apply for one track (4.2).
    private func apply42(_ current: Entry, track i: Int) {
        let blend: Blend = i == 0 ? .first : .replace
        var alpha = current.alpha
        if current.mixingFrom != nil {
            alpha *= applyMixingFrom(current, blend: blend)
        } else if current.trackTime >= current.trackEnd, current.next == nil {
            alpha = 0
        }
        var attachments = alpha >= 0
        let time = current.animationTime, last = current.animationLast
        let timelines = current.animation.timelines
        if i == 0, alpha == 1 {
            attachments = true
            for timeline in timelines {
                if timeline.kind == .attachment {
                    applyAttachmentTimeline(timeline, time: time, blend: blend, attachments: attachments)
                } else {
                    apply(timeline, last: last, time: time, alpha: alpha, blend: blend, out: false, rise: current.rise)
                }
            }
        } else {
            let firstFrame = current.rotations.count != timelines.count * 2
            if firstFrame { current.rotations = Array(repeating: 0, count: timelines.count * 2) }
            for (ii, timeline) in timelines.enumerated() {
                let timelineBlend: Blend = current.modes[ii] == .subsequent ? blend : .setup
                if timeline.kind == .rotate {
                    applyRotateTimeline(timeline, time: time, alpha: alpha, blend: timelineBlend, rotations: &current.rotations, ii * 2, firstFrame)
                } else if timeline.kind == .attachment {
                    applyAttachmentTimeline(timeline, time: time, blend: blend, attachments: attachments)
                } else {
                    apply(timeline, last: last, time: time, alpha: alpha, blend: timelineBlend, out: false, rise: current.rise)
                }
            }
        }
    }

    /// AnimationState.applyMixingFrom (4.2): how far `to` has taken over.
    private func applyMixingFrom(_ to: Entry, blend: Blend) -> CGFloat {
        guard let from = to.mixingFrom else { return 1 }
        if from.mixingFrom != nil { _ = applyMixingFrom(from, blend: blend) }
        var blend = blend
        let mix: CGFloat
        if to.mixDuration == 0 {
            // A single frame to undo what it keyed.
            mix = 1
            if blend == .first { blend = .setup }
        } else {
            mix = min(to.mixTime / to.mixDuration, 1)
            if blend != .first { blend = .replace }
        }
        let attachments = mix < 0
        let timelines = from.animation.timelines
        let alphaHold = from.alpha * to.interruptAlpha, alphaMix = alphaHold * (1 - mix)
        let time = from.animationTime, last = from.animationLast
        let firstFrame = from.rotations.count != timelines.count * 2
        if firstFrame { from.rotations = Array(repeating: 0, count: timelines.count * 2) }
        from.totalAlpha = 0
        for (i, timeline) in timelines.enumerated() {
            let timelineBlend: Blend
            let alpha: CGFloat
            switch from.modes[i] {
            case .subsequent:
                timelineBlend = blend
                alpha = alphaMix
            case .first:
                timelineBlend = .setup
                alpha = alphaMix
            case .holdSubsequent:
                timelineBlend = blend
                alpha = alphaHold
            case .holdFirst:
                timelineBlend = .setup
                alpha = alphaHold
            case .holdMix:
                timelineBlend = .setup
                let hold = from.holdMix[i]
                alpha = alphaHold * max(0, 1 - (hold.map { $0.mixTime / $0.mixDuration } ?? 0))
            }
            from.totalAlpha += alpha
            if timeline.kind == .rotate {
                applyRotateTimeline(timeline, time: time, alpha: alpha, blend: timelineBlend, rotations: &from.rotations, i * 2, firstFrame)
            } else if timeline.kind == .attachment {
                applyAttachmentTimeline(timeline, time: time, blend: timelineBlend, attachments: attachments && alpha >= 0)
            } else {
                apply(timeline, last: last, time: time, alpha: alpha, blend: timelineBlend, out: true, rise: from.rise)
            }
        }
        if to.mixDuration > 0 { queueComplete(from, time) }
        from.nextAnimationLast = time
        from.nextTrackLast = from.trackTime
        return mix
    }

    private func applyAttachmentTimeline(_ timeline: RigData.Timeline, time: CGFloat, blend: Blend, attachments: Bool) {
        guard let first = timeline.times.first else { return }
        let slot = timeline.target
        if time < first {
            if blend == .setup || blend == .first { setAttachment(slot, data.slots[slot].attachment, keyed: attachments) }
        } else {
            setAttachment(slot, timeline.names[keyIndex(timeline.times, time)], keyed: attachments)
        }
        // Not set (before its first key, or mixing out): back to setup later.
        if slots[slot].attachmentState <= unkeyedState { slots[slot].attachmentState = unkeyedState + Self.setupState }
    }

    /// AnimationState.applyRotateTimeline: mixes the short way round on the
    /// first frame, then keeps turning the same way as the keys cross.
    private func applyRotateTimeline(
        _ timeline: RigData.Timeline, time: CGFloat, alpha: CGFloat, blend: Blend, rotations: inout [CGFloat], _ i: Int, _ firstFrame: Bool
    ) {
        if firstFrame { rotations[i] = 0 }
        if alpha == 1 {
            apply(timeline, last: 0, time: time, alpha: 1, blend: blend, out: false, rise: 1)
            return
        }
        guard let first = timeline.times.first else { return }
        let bone = timeline.target, setup = data.bones[bone].rotation
        let r1: CGFloat, r2: CGFloat
        if time < first {
            switch blend {
            case .setup:
                bones[bone].rotation = setup
                return
            case .first:
                r1 = bones[bone].rotation
                r2 = setup
            default:
                return
            }
        } else {
            r1 = blend == .setup ? setup : bones[bone].rotation
            r2 = setup + timeline.value(at: time, channel: 0)
        }
        var total: CGFloat
        var diff = r2 - r1
        diff -= (diff / 360 - 0.5).rounded(.up) * 360
        if diff == 0 {
            total = rotations[i]
        } else {
            let lastTotal = firstFrame ? 0 : rotations[i], lastDiff = firstFrame ? diff : rotations[i + 1]
            let loops = lastTotal - lastTotal.truncatingRemainder(dividingBy: 360)
            total = diff + loops
            let current = diff >= 0
            var direction = lastTotal >= 0
            if abs(lastDiff) <= 90, Self.signum(lastDiff) != Self.signum(diff) {
                if abs(lastTotal - loops) > 180 {
                    total += 360 * Self.signum(lastTotal)
                    direction = current
                } else if loops != 0 {
                    total -= 360 * Self.signum(lastTotal)
                } else {
                    direction = current
                }
            }
            if direction != current { total += 360 * Self.signum(lastTotal) }
            rotations[i] = total
        }
        rotations[i + 1] = diff
        bones[bone].rotation = r1 + total * alpha
    }

    private static func signum(_ value: CGFloat) -> CGFloat {
        value > 0 ? 1 : value < 0 ? -1 : 0
    }

    /// AnimationState.apply for one track as spine-c 3.6 played it, without crossfades.
    private func apply36(_ current: Entry, track i: Int) {
        var mix: CGFloat = 1
        if current.mixingFrom != nil {
            applyMixingFrom36(current)
        } else if current.trackTime >= current.trackEnd, current.next == nil {
            mix = 0
        }
        let time = current.animationTime
        for (index, timeline) in current.animation.timelines.enumerated() {
            let mode = index < current.modes.count ? current.modes[index] : .first
            if mix == 0 {
                apply36(timeline, time: time, reset: mode != .subsequent ? true : nil)
            } else {
                apply36(timeline, time: time, reset: false)
            }
        }
    }

    private func applyMixingFrom36(_ to: Entry) {
        guard let from = to.mixingFrom else { return }
        if from.mixingFrom != nil { applyMixingFrom36(from) }
        let time = from.animationTime
        for (index, timeline) in from.animation.timelines.enumerated() {
            let mode = index < from.modes.count ? from.modes[index] : .first
            switch mode {
            case .subsequent, .holdSubsequent: break
            case .holdFirst, .holdMix: apply36(timeline, time: time, reset: timeline.kind == .attachment)
            case .first: apply36(timeline, time: time, reset: true)
            }
        }
        from.nextAnimationLast = time
        from.nextTrackLast = from.trackTime
    }

    /// A timeline as 3.6 applied it: in full from the setup pose, or (`reset`)
    /// back to the setup pose; nil leaves it alone.
    private func apply36(_ timeline: RigData.Timeline, time: CGFloat, reset: Bool?) {
        guard let reset, let first = timeline.times.first else { return }
        let slot = timeline.target
        switch timeline.kind {
        case .attachment:
            if time < first || reset {
                setAttachment(slot, data.slots[slot].attachment)
            } else {
                setAttachment(slot, timeline.names[keyIndex(timeline.times, time)])
            }
        case .rgba, .rgb, .alpha:
            if reset || time < first {
                slots[slot].color = data.slots[slot].color
            } else {
                apply(timeline, last: 0, time: time, alpha: 1, blend: .setup, out: false, rise: 1)
            }
        default:
            apply(timeline, last: 0, time: time, alpha: reset ? 0 : 1, blend: .setup, out: reset, rise: 1)
        }
    }

    private func queueComplete(_ entry: Entry, _ time: CGFloat) {
        let duration = entry.animation.duration
        let complete: Bool
        if entry.loop {
            switch runtime {
            case .spine36:
                complete = entry.trackLast.truncatingRemainder(dividingBy: duration) > entry.trackTime.truncatingRemainder(dividingBy: duration)
            case .spine42:
                let cycles = duration == 0 ? 1 : (entry.trackTime / duration).rounded(.down)
                complete = duration == 0 || cycles > 0 && cycles > (entry.trackLast / duration).rounded(.down)
            }
        } else {
            complete = time >= duration && entry.animationLast < duration
        }
        if complete { enqueue(.complete, entry) }
    }

    /// Which timelines key a property first, after another track or the
    /// entry mixed from, or along with what's mixing in (`computeHold`).
    private func updateModes() {
        animationsChanged = false
        claimed.removeAll(keepingCapacity: true)
        for case var entry? in tracks {
            while let from = entry.mixingFrom { entry = from }
            var next: Entry? = entry
            while let current = next {
                setModes(current)
                next = current.mixingTo
            }
        }
    }

    private func setModes(_ entry: Entry) {
        let to = entry.mixingTo
        let (ids, _) = propertyIDs(entry.animation)
        entry.holdMix = Array(repeating: nil, count: ids.count)
        entry.modes = entry.animation.timelines.enumerated().map { i, timeline in
            let added = ids[i].reduce(false) { claimed.insert($1).inserted || $0 }
            guard added else { return .subsequent }
            guard let to, timeline.kind != .attachment, propertyIDs(to.animation).all.contains(where: ids[i].contains) else { return .first }
            if runtime == .spine42 {
                var next = to.mixingTo
                while let later = next {
                    if !propertyIDs(later.animation).all.isDisjoint(with: ids[i]) {
                        next = later.mixingTo
                        continue
                    }
                    if entry.mixDuration > 0 {
                        entry.holdMix[i] = later
                        return .holdMix
                    }
                    break
                }
            }
            return .holdFirst
        }
    }

    /// Each timeline's property IDs (Timeline.getPropertyIds): 4.2 keys x and
    /// y apart; 3.6 kept one per bone property, slot colour or attachment.
    private func propertyIDs(_ animation: RigData.Animation) -> (ids: [[Int]], all: Set<Int>) {
        if let known = properties[animation.name] { return known }
        let ids = animation.timelines.map { Self.properties(of: $0, runtime: runtime) }
        let result = (ids, Set(ids.joined()))
        properties[animation.name] = result
        return result
    }

    private static func properties(of timeline: RigData.Timeline, runtime: Runtime) -> [Int] {
        let kinds: [Int]
        switch (timeline.kind, runtime) {
        case (.rotate, _): kinds = [0]
        case (.translate, .spine36), (.translateX, .spine36), (.translateY, .spine36): kinds = [1]
        case (.translate, _): kinds = [1, 2]
        case (.translateX, _): kinds = [1]
        case (.translateY, _): kinds = [2]
        case (.scale, .spine36), (.scaleX, .spine36), (.scaleY, .spine36): kinds = [3]
        case (.scale, _): kinds = [3, 4]
        case (.scaleX, _): kinds = [3]
        case (.scaleY, _): kinds = [4]
        case (.shear, .spine36), (.shearX, .spine36), (.shearY, .spine36): kinds = [5]
        case (.shear, _): kinds = [5, 6]
        case (.shearX, _): kinds = [5]
        case (.shearY, _): kinds = [6]
        case (.rgba, .spine36), (.rgb, .spine36), (.alpha, .spine36): kinds = [7]
        case (.rgba, _): kinds = [7, 8]
        case (.rgb, _): kinds = [7]
        case (.alpha, _): kinds = [8]
        case (.attachment, _): kinds = [10]
        case (.deform, _): kinds = [11]
        }
        return kinds.map { $0 << 40 | (timeline.attachment + 1) << 20 | timeline.target }
    }

    // MARK: - Timelines

    /// Timeline.apply (4.2): poses the property at `time`, `alpha` of the way
    /// from where `blend` starts it. `out` is MixDirection.mixOut.
    private func apply(_ timeline: RigData.Timeline, last: CGFloat, time: CGFloat, alpha: CGFloat, blend: Blend, out: Bool, rise: CGFloat) {
        guard !timeline.times.isEmpty else { return }
        switch timeline.kind {
        case .attachment:
            // AnimationState applies these itself (`applyAttachmentTimeline`).
            break
        case .deform:
            applyDeform(timeline, time: time, alpha: alpha, blend: blend)
        case .rgba, .rgb, .alpha:
            applyColor(timeline, time: time, alpha: alpha, blend: blend)
        default:
            applyBone(timeline, time: time, alpha: alpha, blend: blend, out: out, rise: rise)
        }
    }

    private func applyBone(_ timeline: RigData.Timeline, time: CGFloat, alpha: CGFloat, blend: Blend, out: Bool, rise: CGFloat) {
        let index = timeline.target
        let setup = data.bones[index]
        let before = time < timeline.times[0]
        // Rises scale the y keys of `riseBone`.
        let lift = index == riseBone ? rise : 1
        func relative(_ current: CGFloat, _ setup: CGFloat, _ value: () -> CGFloat) -> CGFloat {
            if before {
                switch blend {
                case .setup: return setup
                case .first: return current + (setup - current) * alpha
                default: return current
                }
            }
            var value = value()
            switch blend {
            case .setup: return setup + value * alpha
            case .first, .replace: value += setup - current
            case .add: break
            }
            return current + value * alpha
        }
        func scaled(_ current: CGFloat, _ setup: CGFloat, _ key: () -> CGFloat) -> CGFloat {
            if before {
                switch blend {
                case .setup: return setup
                case .first: return current + (setup - current) * alpha
                default: return current
                }
            }
            let value = key() * setup
            if alpha == 1 { return blend == .add ? current + value - setup : value }
            // Mixing out keeps the setup or current pose's sign, else the key's.
            if out {
                switch blend {
                case .setup: return setup + (abs(value) * Self.signum(setup) - setup) * alpha
                case .first, .replace: return current + (abs(value) * Self.signum(current) - current) * alpha
                case .add: return current + (value - setup) * alpha
                }
            }
            switch blend {
            case .setup:
                let s = abs(setup) * Self.signum(value)
                return s + (value - s) * alpha
            case .first, .replace:
                let s = abs(current) * Self.signum(value)
                return s + (value - s) * alpha
            case .add:
                return current + (value - setup) * alpha
            }
        }
        var b = bones[index]
        switch timeline.kind {
        case .rotate:
            b.rotation = relative(b.rotation, setup.rotation) { rotation(timeline, time) }
        case .translate:
            b.x = relative(b.x, setup.x) { sample(timeline, time, channel: 0) }
            b.y = relative(b.y, setup.y) { sample(timeline, time, channel: 1) * lift }
        case .translateX:
            b.x = relative(b.x, setup.x) { sample(timeline, time, channel: 0) }
        case .translateY:
            b.y = relative(b.y, setup.y) { sample(timeline, time, channel: 0) * lift }
        case .scale:
            b.scaleX = scaled(b.scaleX, setup.scaleX) { sample(timeline, time, channel: 0) }
            b.scaleY = scaled(b.scaleY, setup.scaleY) { sample(timeline, time, channel: 1) }
        case .scaleX:
            b.scaleX = scaled(b.scaleX, setup.scaleX) { sample(timeline, time, channel: 0) }
        case .scaleY:
            b.scaleY = scaled(b.scaleY, setup.scaleY) { sample(timeline, time, channel: 0) }
        case .shear:
            b.shearX = relative(b.shearX, setup.shearX) { sample(timeline, time, channel: 0) }
            b.shearY = relative(b.shearY, setup.shearY) { sample(timeline, time, channel: 1) }
        case .shearX:
            b.shearX = relative(b.shearX, setup.shearX) { sample(timeline, time, channel: 0) }
        case .shearY:
            b.shearY = relative(b.shearY, setup.shearY) { sample(timeline, time, channel: 0) }
        default:
            return
        }
        bones[index] = b
    }

    private func applyColor(_ timeline: RigData.Timeline, time: CGFloat, alpha: CGFloat, blend: Blend) {
        let slot = timeline.target
        let setup = data.slots[slot].color
        var color = slots[slot].color
        let rgb = timeline.kind != .alpha, a = timeline.kind != .rgb
        if time < timeline.times[0] {
            switch blend {
            case .setup:
                if rgb { (color.r, color.g, color.b) = (setup.r, setup.g, setup.b) }
                if a { color.a = setup.a }
            case .first:
                if rgb {
                    color.r += (setup.r - color.r) * alpha
                    color.g += (setup.g - color.g) * alpha
                    color.b += (setup.b - color.b) * alpha
                }
                if a { color.a += (setup.a - color.a) * alpha }
            default:
                return
            }
            slots[slot].color = color
            return
        }
        var key = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        switch timeline.kind {
        case .alpha:
            key.a = sample(timeline, time, channel: 0)
        case .rgb:
            key.r = sample(timeline, time, channel: 0)
            key.g = sample(timeline, time, channel: 1)
            key.b = sample(timeline, time, channel: 2)
        default:
            key.r = sample(timeline, time, channel: 0)
            key.g = sample(timeline, time, channel: 1)
            key.b = sample(timeline, time, channel: 2)
            key.a = sample(timeline, time, channel: 3)
        }
        if alpha == 1 {
            if rgb { (color.r, color.g, color.b) = (key.r, key.g, key.b) }
            if a { color.a = key.a }
        } else {
            if blend == .setup {
                if rgb { (color.r, color.g, color.b) = (setup.r, setup.g, setup.b) }
                if a { color.a = setup.a }
            }
            if rgb {
                color.r += (key.r - color.r) * alpha
                color.g += (key.g - color.g) * alpha
                color.b += (key.b - color.b) * alpha
            }
            if a { color.a += (key.a - color.a) * alpha }
        }
        slots[slot].color = color
    }

    /// DeformTimeline.apply (4.2).
    private func applyDeform(_ timeline: RigData.Timeline, time: CGFloat, alpha: CGFloat, blend: Blend) {
        let slot = timeline.target
        guard slots[slot].attachment == timeline.attachment, let setup = data.attachments[timeline.attachment].vertices else { return }
        var blend = blend
        if slots[slot].deformCount == 0 { blend = .setup }
        let count = timeline.width, weighted = setup.isWeighted
        let times = timeline.times, values = timeline.values
        if time < times[0] {
            switch blend {
            case .setup:
                slots[slot].deformCount = 0
            case .first:
                if alpha == 1 {
                    slots[slot].deformCount = 0
                    return
                }
                slots[slot].deformCount = count
                for i in 0..<count {
                    slots[slot].deform[i] = weighted ? slots[slot].deform[i] * (1 - alpha)
                        : slots[slot].deform[i] + (setup.values[i] - slots[slot].deform[i]) * alpha
                }
            default:
                break
            }
            return
        }
        // The keyed vertices at `time`.
        let last = times.count - 1
        let k = time >= times[last] ? last : timeline.frame(time)
        let percent = k == last ? 0 : percent(timeline, k, time)
        func keyed(_ i: Int) -> CGFloat {
            let previous = values[k * count + i]
            return k == last ? previous : previous + (values[(k + 1) * count + i] - previous) * percent
        }
        slots[slot].deformCount = count
        for i in 0..<count {
            let value = keyed(i), current = slots[slot].deform[i]
            let rest = weighted ? 0 : setup.values[i]
            if alpha == 1 {
                slots[slot].deform[i] = blend == .add ? current + value - rest : value
                continue
            }
            switch blend {
            case .setup: slots[slot].deform[i] = rest + (value - rest) * alpha
            case .first, .replace: slots[slot].deform[i] = current + (value - current) * alpha
            case .add: slots[slot].deform[i] = current + (value - rest) * alpha
            }
        }
    }

    /// A rotate key's value: 3.6 turns the short way between keys.
    private func rotation(_ timeline: RigData.Timeline, _ time: CGFloat) -> CGFloat {
        let last = timeline.times.count - 1
        if time >= timeline.times[last] { return timeline.values[last] }
        guard runtime == .spine36 else { return sample(timeline, time, channel: 0) }
        let k = timeline.frame(time)
        let previous = timeline.values[k]
        let r = Self.wrap(timeline.values[k + 1] - previous)
        return Self.wrap(previous + r * timeline.percent36(k, time))
    }

    /// Wraps degrees to -180…180 as spine-c 3.6 does.
    private static func wrap(_ r: CGFloat) -> CGFloat {
        r - CGFloat(16384 - Int(16384.499999999996 - r / 360)) * 360
    }

    /// One of a timeline's values at `time` (at or after its first key).
    private func sample(_ timeline: RigData.Timeline, _ time: CGFloat, channel: Int) -> CGFloat {
        timeline.value(at: time, channel: channel, runtime: runtime)
    }

    /// How far between key `k` and the next `time` is, along their curve.
    private func percent(_ timeline: RigData.Timeline, _ k: Int, _ time: CGFloat) -> CGFloat {
        timeline.value(k, time, channel: 0, 0, 1, runtime: runtime)
    }

    /// The last key at or before `time` (Timeline.search1).
    private func keyIndex(_ times: [CGFloat], _ time: CGFloat) -> Int {
        let last = times.count - 1
        if time >= times[last] { return last }
        var low = 0, high = last
        while high - low > 1 {
            let middle = (low + high) / 2
            if times[middle] <= time { low = middle } else { high = middle }
        }
        return low
    }

    private func setAttachment(_ slot: Int, _ attachment: Int?, keyed: Bool = false) {
        if slots[slot].attachment != attachment {
            slots[slot].attachment = attachment
            slots[slot].deformCount = 0
        }
        if keyed { slots[slot].attachmentState = unkeyedState + Self.currentState }
    }

    // MARK: - Skeleton

    private func updateWorldTransform() {
        switch runtime {
        case .spine36:
            for bone in resets { resetApplied(bone) }
        case .spine42:
            for bone in bones.indices { resetApplied(bone) }
        }
        for update in updates {
            switch update {
            case let .bone(i):
                let b = bones[i]
                if runtime == .spine42 {
                    updateWorldTransform42(i, b.ax, b.ay, b.arotation, b.ascaleX, b.ascaleY, b.ashearX, b.ashearY)
                } else {
                    updateWorldTransform36(i, b.x, b.y, b.rotation, b.scaleX, b.scaleY, b.shearX, b.shearY)
                }
            case let .ik(i):
                if runtime == .spine42 { applyIk42(i) } else { applyIk36(i) }
            case let .transform(i):
                applyTransform(i)
            case let .path(i):
                applyPath(i)
            case let .physics(i):
                applyPhysics(i)
            }
        }
    }

    private func resetApplied(_ bone: Int) {
        let b = bones[bone]
        bones[bone].ax = b.x
        bones[bone].ay = b.y
        bones[bone].arotation = b.rotation
        bones[bone].ascaleX = b.scaleX
        bones[bone].ascaleY = b.scaleY
        bones[bone].ashearX = b.shearX
        bones[bone].ashearY = b.shearY
        bones[bone].appliedValid = true
    }

    /// Skeleton.updateCache (4.2): bones and constraints in the order they
    /// update, constraints by their `order`.
    private func updateCache42() {
        updates.removeAll()
        var sorted = Array(repeating: false, count: bones.count)
        func sortBone(_ bone: Int) {
            if sorted[bone] { return }
            if let parent = data.bones[bone].parent { sortBone(parent) }
            sorted[bone] = true
            updates.append(.bone(bone))
        }
        func sortReset(_ list: [Int]) {
            for bone in list {
                if sorted[bone] { sortReset(children[bone]) }
                sorted[bone] = false
            }
        }
        let count = data.iks.count + data.transforms.count + data.paths.count + data.physics.count
        for order in 0..<count {
            if let index = data.iks.firstIndex(where: { $0.order == order }) {
                let ik = data.iks[index]
                sortBone(ik.target)
                let parent = ik.bones[0]
                sortBone(parent)
                if ik.bones.count == 1 {
                    updates.append(.ik(index))
                    sortReset(children[parent])
                } else {
                    let child = ik.bones[ik.bones.count - 1]
                    sortBone(child)
                    updates.append(.ik(index))
                    sortReset(children[parent])
                    sorted[child] = true
                }
            } else if let index = data.transforms.firstIndex(where: { $0.order == order }) {
                let constraint = data.transforms[index]
                sortBone(constraint.target)
                for bone in constraint.bones {
                    if constraint.local, let parent = data.bones[bone].parent { sortBone(parent) }
                    sortBone(bone)
                }
                updates.append(.transform(index))
                for bone in constraint.bones { sortReset(children[bone]) }
                for bone in constraint.bones { sorted[bone] = true }
            } else if let index = data.paths.firstIndex(where: { $0.order == order }) {
                let path = data.paths[index]
                for attachment in data.skin[path.target].values {
                    sortPathAttachment(attachment, slot: path.target, sortBone)
                }
                for bone in path.bones { sortBone(bone) }
                updates.append(.path(index))
                for bone in path.bones { sortReset(children[bone]) }
                for bone in path.bones { sorted[bone] = true }
            } else if let index = data.physics.firstIndex(where: { $0.order == order }) {
                let bone = data.physics[index].bone
                sortBone(bone)
                updates.append(.physics(index))
                sortReset(children[bone])
                sorted[bone] = true
            }
        }
        for bone in bones.indices { sortBone(bone) }
    }

    private func sortPathAttachment(_ attachment: Int, slot: Int, _ sortBone: (Int) -> Void) {
        guard case let .path(path) = data.attachments[attachment] else { return }
        if path.vertices.bones.isEmpty {
            sortBone(data.slots[slot].bone)
            return
        }
        var i = 0
        while i < path.vertices.bones.count {
            let count = path.vertices.bones[i]
            for b in path.vertices.bones[(i + 1)...(i + count)] { sortBone(b) }
            i += count + 1
        }
    }

    /// spSkeleton_updateCache (3.6): IK and path constraints only.
    private func updateCache36() {
        var sorted = Array(repeating: false, count: bones.count)
        updates.removeAll()
        resets.removeAll()

        func sortBone(_ bone: Int) {
            if sorted[bone] { return }
            if let parent = data.bones[bone].parent { sortBone(parent) }
            sorted[bone] = true
            updates.append(.bone(bone))
        }
        func sortReset(_ list: [Int]) {
            for bone in list {
                if sorted[bone] { sortReset(children[bone]) }
                sorted[bone] = false
            }
        }
        func contains(_ bone: Int) -> Bool {
            updates.contains { if case let .bone(b) = $0 { b == bone } else { false } }
        }

        let constraintCount = data.iks.count + data.paths.count
        for order in 0..<constraintCount {
            if let index = data.iks.firstIndex(where: { $0.order == order }) {
                let ik = data.iks[index]
                sortBone(ik.target)
                let parent = ik.bones[0]
                sortBone(parent)
                if ik.bones.count > 1, let child = ik.bones.last, !contains(child) { resets.append(child) }
                updates.append(.ik(index))
                sortReset(children[parent])
                if let last = ik.bones.last { sorted[last] = true }
            } else if let index = data.paths.firstIndex(where: { $0.order == order }) {
                let path = data.paths[index]
                for attachment in data.skin[path.target].values {
                    sortPathAttachment(attachment, slot: path.target, sortBone)
                }
                for bone in path.bones { sortBone(bone) }
                updates.append(.path(index))
                for bone in path.bones { sortReset(children[bone]) }
                for bone in path.bones { sorted[bone] = true }
            }
        }
        for bone in bones.indices { sortBone(bone) }
    }

    private static func cosDeg(_ degrees: CGFloat) -> CGFloat { cos(degrees * .pi / 180) }
    private static func sinDeg(_ degrees: CGFloat) -> CGFloat { sin(degrees * .pi / 180) }
    private static let radDeg: CGFloat = 180 / .pi
    private static let degRad: CGFloat = .pi / 180

    /// Bone.updateWorldTransformWith (4.2, the skeleton unscaled).
    private func updateWorldTransform42(
        _ index: Int, _ x: CGFloat, _ y: CGFloat, _ rotation: CGFloat, _ scaleX: CGFloat, _ scaleY: CGFloat, _ shearX: CGFloat, _ shearY: CGFloat
    ) {
        bones[index].ax = x
        bones[index].ay = y
        bones[index].arotation = rotation
        bones[index].ascaleX = scaleX
        bones[index].ascaleY = scaleY
        bones[index].ashearX = shearX
        bones[index].ashearY = shearY
        guard let parent = data.bones[index].parent else {
            let rx = (rotation + shearX) * Self.degRad, ry = (rotation + 90 + shearY) * Self.degRad
            bones[index].world = Transform(
                a: cos(rx) * scaleX, b: cos(ry) * scaleY, c: sin(rx) * scaleX, d: sin(ry) * scaleY,
                x: x + origin.x, y: y + origin.y
            )
            return
        }
        let p = bones[parent].world
        var pa = p.a, pb = p.b, pc = p.c, pd = p.d
        var t = Transform()
        t.x = pa * x + pb * y + p.x
        t.y = pc * x + pd * y + p.y
        switch data.bones[index].inherit {
        case .normal:
            let rx = (rotation + shearX) * Self.degRad, ry = (rotation + 90 + shearY) * Self.degRad
            let la = cos(rx) * scaleX, lb = cos(ry) * scaleY, lc = sin(rx) * scaleX, ld = sin(ry) * scaleY
            t.a = pa * la + pb * lc
            t.b = pa * lb + pb * ld
            t.c = pc * la + pd * lc
            t.d = pc * lb + pd * ld
        case .onlyTranslation:
            let rx = (rotation + shearX) * Self.degRad, ry = (rotation + 90 + shearY) * Self.degRad
            t.a = cos(rx) * scaleX
            t.b = cos(ry) * scaleY
            t.c = sin(rx) * scaleX
            t.d = sin(ry) * scaleY
        case .noRotationOrReflection:
            var s = pa * pa + pc * pc
            let prx: CGFloat
            if s > 0.0001 {
                s = abs(pa * pd - pb * pc) / s
                pb = pc * s
                pd = pa * s
                prx = atan2(pc, pa) * Self.radDeg
            } else {
                pa = 0
                pc = 0
                prx = 90 - atan2(pd, pb) * Self.radDeg
            }
            let rx = (rotation + shearX - prx) * Self.degRad, ry = (rotation + shearY - prx + 90) * Self.degRad
            let la = cos(rx) * scaleX, lb = cos(ry) * scaleY, lc = sin(rx) * scaleX, ld = sin(ry) * scaleY
            t.a = pa * la - pb * lc
            t.b = pa * lb - pb * ld
            t.c = pc * la + pd * lc
            t.d = pc * lb + pd * ld
        case .noScale, .noScaleOrReflection:
            let r = rotation * Self.degRad, cosine = cos(r), sine = sin(r)
            var za = pa * cosine + pb * sine, zc = pc * cosine + pd * sine
            var s = sqrt(za * za + zc * zc)
            if s > 0.00001 { s = 1 / s }
            za *= s
            zc *= s
            s = sqrt(za * za + zc * zc)
            if data.bones[index].inherit == .noScale, pa * pd - pb * pc < 0 { s = -s }
            let turned = .pi / 2 + atan2(zc, za)
            let zb = cos(turned) * s, zd = sin(turned) * s
            let sx = shearX * Self.degRad, sy = (90 + shearY) * Self.degRad
            let la = cos(sx) * scaleX, lb = cos(sy) * scaleY, lc = sin(sx) * scaleX, ld = sin(sy) * scaleY
            t.a = za * la + zb * lc
            t.b = za * lb + zb * ld
            t.c = zc * la + zd * lc
            t.d = zc * lb + zd * ld
        }
        bones[index].world = t
    }

    /// Bone.updateAppliedTransform (4.2): local values from the world transform.
    private func updateAppliedTransform42(_ index: Int) {
        let w = bones[index].world
        guard let parent = data.bones[index].parent else {
            bones[index].ax = w.x - origin.x
            bones[index].ay = w.y - origin.y
            bones[index].arotation = atan2(w.c, w.a) * Self.radDeg
            bones[index].ascaleX = sqrt(w.a * w.a + w.c * w.c)
            bones[index].ascaleY = sqrt(w.b * w.b + w.d * w.d)
            bones[index].ashearX = 0
            bones[index].ashearY = atan2(w.a * w.b + w.c * w.d, w.a * w.d - w.b * w.c) * Self.radDeg
            return
        }
        let p = bones[parent].world
        var pa = p.a, pb = p.b, pc = p.c, pd = p.d
        var pid = 1 / (pa * pd - pb * pc)
        var ia = pd * pid, ib = pb * pid, ic = pc * pid, id = pa * pid
        let dx = w.x - p.x, dy = w.y - p.y
        bones[index].ax = dx * ia - dy * ib
        bones[index].ay = dy * id - dx * ic
        let inherit = data.bones[index].inherit
        let ra: CGFloat, rb: CGFloat, rc: CGFloat, rd: CGFloat
        if inherit == .onlyTranslation {
            (ra, rb, rc, rd) = (w.a, w.b, w.c, w.d)
        } else {
            switch inherit {
            case .noRotationOrReflection:
                let s = abs(pa * pd - pb * pc) / (pa * pa + pc * pc)
                pb = -pc * s
                pd = pa * s
                pid = 1 / (pa * pd - pb * pc)
                ia = pd * pid
                ib = pb * pid
            case .noScale, .noScaleOrReflection:
                let cosine = Self.cosDeg(bones[index].rotation), sine = Self.sinDeg(bones[index].rotation)
                pa = pa * cosine + pb * sine
                pc = pc * cosine + pd * sine
                var s = sqrt(pa * pa + pc * pc)
                if s > 0.00001 { s = 1 / s }
                pa *= s
                pc *= s
                s = sqrt(pa * pa + pc * pc)
                if inherit == .noScale, pid < 0 { s = -s }
                let r = .pi / 2 + atan2(pc, pa)
                pb = cos(r) * s
                pd = sin(r) * s
                pid = 1 / (pa * pd - pb * pc)
                ia = pd * pid
                ib = pb * pid
                ic = pc * pid
                id = pa * pid
            default:
                break
            }
            ra = ia * w.a - ib * w.c
            rb = ia * w.b - ib * w.d
            rc = id * w.c - ic * w.a
            rd = id * w.d - ic * w.b
        }
        bones[index].ashearX = 0
        let scaleX = sqrt(ra * ra + rc * rc)
        if scaleX > 0.0001 {
            let det = ra * rd - rb * rc
            bones[index].ascaleX = scaleX
            bones[index].ascaleY = det / scaleX
            bones[index].ashearY = -atan2(ra * rb + rc * rd, det) * Self.radDeg
            bones[index].arotation = atan2(rc, ra) * Self.radDeg
        } else {
            bones[index].ascaleX = 0
            bones[index].ascaleY = sqrt(rb * rb + rd * rd)
            bones[index].ashearY = 0
            bones[index].arotation = 90 - atan2(rd, rb) * Self.radDeg
        }
    }

    /// spBone_updateWorldTransformWith (3.6).
    private func updateWorldTransform36(
        _ index: Int, _ x: CGFloat, _ y: CGFloat, _ rotation: CGFloat, _ scaleX: CGFloat, _ scaleY: CGFloat, _ shearX: CGFloat, _ shearY: CGFloat
    ) {
        bones[index].ax = x
        bones[index].ay = y
        bones[index].arotation = rotation
        bones[index].ascaleX = scaleX
        bones[index].ascaleY = scaleY
        bones[index].ashearX = shearX
        bones[index].ashearY = shearY
        bones[index].appliedValid = true
        let rotationY = rotation + 90 + shearY
        guard let parent = data.bones[index].parent else {
            bones[index].world = Transform(
                a: Self.cosDeg(rotation + shearX) * scaleX, b: Self.cosDeg(rotationY) * scaleY,
                c: Self.sinDeg(rotation + shearX) * scaleX, d: Self.sinDeg(rotationY) * scaleY,
                x: x + origin.x, y: y + origin.y
            )
            return
        }
        var pa = bones[parent].world.a, pb = bones[parent].world.b, pc = bones[parent].world.c, pd = bones[parent].world.d
        var t = Transform()
        t.x = pa * x + pb * y + bones[parent].world.x
        t.y = pc * x + pd * y + bones[parent].world.y
        switch data.bones[index].inherit {
        case .normal:
            let la = Self.cosDeg(rotation + shearX) * scaleX, lb = Self.cosDeg(rotationY) * scaleY
            let lc = Self.sinDeg(rotation + shearX) * scaleX, ld = Self.sinDeg(rotationY) * scaleY
            t.a = pa * la + pb * lc
            t.b = pa * lb + pb * ld
            t.c = pc * la + pd * lc
            t.d = pc * lb + pd * ld
        case .onlyTranslation:
            t.a = Self.cosDeg(rotation + shearX) * scaleX
            t.b = Self.cosDeg(rotationY) * scaleY
            t.c = Self.sinDeg(rotation + shearX) * scaleX
            t.d = Self.sinDeg(rotationY) * scaleY
        case .noRotationOrReflection:
            var s = pa * pa + pc * pc
            let prx: CGFloat
            if s > 0.0001 {
                s = abs(pa * pd - pb * pc) / s
                pb = pc * s
                pd = pa * s
                prx = atan2(pc, pa) * 180 / .pi
            } else {
                pa = 0
                pc = 0
                prx = 90 - atan2(pd, pb) * 180 / .pi
            }
            let rx = rotation + shearX - prx, ry = rotation + shearY - prx + 90
            let la = Self.cosDeg(rx) * scaleX, lb = Self.cosDeg(ry) * scaleY
            let lc = Self.sinDeg(rx) * scaleX, ld = Self.sinDeg(ry) * scaleY
            t.a = pa * la - pb * lc
            t.b = pa * lb - pb * ld
            t.c = pc * la + pd * lc
            t.d = pc * lb + pd * ld
        case .noScale, .noScaleOrReflection:
            let cosine = Self.cosDeg(rotation), sine = Self.sinDeg(rotation)
            var za = pa * cosine + pb * sine, zc = pc * cosine + pd * sine
            var s = sqrt(za * za + zc * zc)
            if s > 0.00001 { s = 1 / s }
            za *= s
            zc *= s
            s = sqrt(za * za + zc * zc)
            let r = .pi / 2 + atan2(zc, za)
            var zb = cos(r) * s, zd = sin(r) * s
            let la = Self.cosDeg(shearX) * scaleX, lb = Self.cosDeg(90 + shearY) * scaleY
            let lc = Self.sinDeg(shearX) * scaleX, ld = Self.sinDeg(90 + shearY) * scaleY
            if data.bones[index].inherit == .noScale, pa * pd - pb * pc < 0 {
                zb = -zb
                zd = -zd
            }
            t.a = za * la + zb * lc
            t.b = za * lb + zb * ld
            t.c = zc * la + zd * lc
            t.d = zc * lb + zd * ld
        }
        bones[index].world = t
    }

    /// spBone_updateAppliedTransform (3.6).
    private func updateAppliedTransform36(_ index: Int) {
        bones[index].appliedValid = true
        let w = bones[index].world
        guard let parent = data.bones[index].parent else {
            bones[index].ax = w.x - origin.x
            bones[index].ay = w.y - origin.y
            bones[index].arotation = atan2(w.c, w.a) * 180 / .pi
            bones[index].ascaleX = sqrt(w.a * w.a + w.c * w.c)
            bones[index].ascaleY = sqrt(w.b * w.b + w.d * w.d)
            bones[index].ashearX = 0
            bones[index].ashearY = atan2(w.a * w.b + w.c * w.d, w.a * w.d - w.b * w.c) * 180 / .pi
            return
        }
        let p = bones[parent].world
        let pid = 1 / (p.a * p.d - p.b * p.c)
        let dx = w.x - p.x, dy = w.y - p.y
        let ia = pid * p.d, id = pid * p.a, ib = pid * p.b, ic = pid * p.c
        let ra = ia * w.a - ib * w.c, rb = ia * w.b - ib * w.d
        let rc = id * w.c - ic * w.a, rd = id * w.d - ic * w.b
        bones[index].ax = dx * p.d * pid - dy * p.b * pid
        bones[index].ay = dy * p.a * pid - dx * p.c * pid
        bones[index].ashearX = 0
        let scaleX = sqrt(ra * ra + rc * rc)
        if scaleX > 0.0001 {
            let det = ra * rd - rb * rc
            bones[index].ascaleX = scaleX
            bones[index].ascaleY = det / scaleX
            bones[index].ashearY = atan2(ra * rb + rc * rd, det) * 180 / .pi
            bones[index].arotation = atan2(rc, ra) * 180 / .pi
        } else {
            bones[index].ascaleX = 0
            bones[index].ascaleY = sqrt(rb * rb + rd * rd)
            bones[index].ashearY = 0
            bones[index].arotation = 90 - atan2(rd, rb) * 180 / .pi
        }
    }

    // MARK: - IK

    /// IkConstraint.update (4.2).
    private func applyIk42(_ index: Int) {
        let ik = data.iks[index]
        guard ik.mix != 0 else { return }
        let target = bones[ik.target].world
        if ik.bones.count == 1 {
            applyIk1(ik.bones[0], target.x, target.y, compress: ik.compress, stretch: ik.stretch, uniform: ik.uniform, alpha: ik.mix)
        } else {
            applyIk2(ik.bones[0], ik.bones[1], target.x, target.y, bend: ik.bendDirection, stretch: ik.stretch, uniform: ik.uniform, softness: ik.softness, alpha: ik.mix)
        }
    }

    private func applyIk1(_ bone: Int, _ targetX: CGFloat, _ targetY: CGFloat, compress: Bool, stretch: Bool, uniform: Bool, alpha: CGFloat) {
        guard let parent = data.bones[bone].parent else { return }
        let p = bones[parent].world, b = bones[bone]
        var pa = p.a, pb = p.b, pc = p.c, pd = p.d
        var rotationIK = -b.ashearX - b.arotation, tx: CGFloat = 0, ty: CGFloat = 0
        let inherit = data.bones[bone].inherit
        if inherit == .onlyTranslation {
            tx = targetX - b.world.x
            ty = targetY - b.world.y
        } else {
            if inherit == .noRotationOrReflection {
                let s = abs(pa * pd - pb * pc) / max(0.0001, pa * pa + pc * pc)
                let sa = pa, sc = pc
                pb = -sc * s
                pd = sa * s
                rotationIK += atan2(sc, sa) * Self.radDeg
            }
            let x = targetX - p.x, y = targetY - p.y
            let d = pa * pd - pb * pc
            if abs(d) <= 0.0001 {
                tx = 0
                ty = 0
            } else {
                tx = (x * pd - y * pb) / d - b.ax
                ty = (y * pa - x * pc) / d - b.ay
            }
        }
        rotationIK += atan2(ty, tx) * Self.radDeg
        if b.ascaleX < 0 { rotationIK += 180 }
        if rotationIK > 180 { rotationIK -= 360 } else if rotationIK < -180 { rotationIK += 360 }
        var sx = b.ascaleX, sy = b.ascaleY
        if compress || stretch {
            if inherit == .noScale || inherit == .noScaleOrReflection {
                tx = targetX - b.world.x
                ty = targetY - b.world.y
            }
            let length = data.bones[bone].length * sx
            if length > 0.0001 {
                let dd = tx * tx + ty * ty
                if (compress && dd < length * length) || (stretch && dd > length * length) {
                    let s = (sqrt(dd) / length - 1) * alpha + 1
                    sx *= s
                    if uniform { sy *= s }
                }
            }
        }
        updateWorldTransform42(bone, b.ax, b.ay, b.arotation + rotationIK * alpha, sx, sy, b.ashearX, b.ashearY)
    }

    private func applyIk2(
        _ parent: Int, _ child: Int, _ targetX: CGFloat, _ targetY: CGFloat, bend: CGFloat, stretch: Bool, uniform: Bool, softness: CGFloat, alpha: CGFloat
    ) {
        guard data.bones[parent].inherit == .normal, data.bones[child].inherit == .normal,
              let grandparent = data.bones[parent].parent else { return }
        let p = bones[parent], c = bones[child]
        let px = p.ax, py = p.ay
        var psx = p.ascaleX, psy = p.ascaleY, sx = psx, sy = psy, csx = c.ascaleX
        let os1: CGFloat, os2: CGFloat
        var s2: CGFloat
        if psx < 0 {
            psx = -psx
            os1 = 180
            s2 = -1
        } else {
            os1 = 0
            s2 = 1
        }
        if psy < 0 {
            psy = -psy
            s2 = -s2
        }
        if csx < 0 {
            csx = -csx
            os2 = 180
        } else {
            os2 = 0
        }
        let cx = c.ax
        let cy: CGFloat, cwx: CGFloat, cwy: CGFloat
        let u = abs(psx - psy) <= 0.0001
        if !u || stretch {
            cy = 0
            cwx = p.world.a * cx + p.world.x
            cwy = p.world.c * cx + p.world.y
        } else {
            cy = c.ay
            cwx = p.world.a * cx + p.world.b * cy + p.world.x
            cwy = p.world.c * cx + p.world.d * cy + p.world.y
        }
        let pp = bones[grandparent].world
        let a0 = pp.a, b0 = pp.b, c0 = pp.c, d0 = pp.d
        var id = a0 * d0 - b0 * c0
        var x = cwx - pp.x, y = cwy - pp.y
        id = abs(id) <= 0.0001 ? 0 : 1 / id
        let dx = (x * d0 - y * b0) * id - px, dy = (y * a0 - x * c0) * id - py
        let l1 = sqrt(dx * dx + dy * dy)
        var l2 = data.bones[child].length * csx
        if l1 < 0.0001 {
            applyIk1(parent, targetX, targetY, compress: false, stretch: stretch, uniform: false, alpha: alpha)
            updateWorldTransform42(child, cx, cy, 0, c.ascaleX, c.ascaleY, c.ashearX, c.ashearY)
            return
        }
        x = targetX - pp.x
        y = targetY - pp.y
        var tx = (x * d0 - y * b0) * id - px, ty = (y * a0 - x * c0) * id - py
        var dd = tx * tx + ty * ty
        if softness != 0 {
            let soft = softness * psx * (csx + 1) * 0.5
            let td = sqrt(dd), sd = td - l1 - l2 * psx + soft
            if sd > 0 {
                var q = min(1, sd / (soft * 2)) - 1
                q = (sd - soft * (1 - q * q)) / td
                tx -= q * tx
                ty -= q * ty
                dd = tx * tx + ty * ty
            }
        }
        var a1: CGFloat, a2: CGFloat
        solve: if u {
            l2 *= psx
            var cosine = (dd - l1 * l1 - l2 * l2) / (2 * l1 * l2)
            if cosine < -1 {
                cosine = -1
                a2 = .pi * bend
            } else if cosine > 1 {
                cosine = 1
                a2 = 0
                if stretch {
                    let s = (sqrt(dd) / (l1 + l2) - 1) * alpha + 1
                    sx *= s
                    if uniform { sy *= s }
                }
            } else {
                a2 = acos(cosine) * bend
            }
            let a = l1 + l2 * cosine, b = l2 * sin(a2)
            a1 = atan2(ty * a - tx * b, tx * a + ty * b)
        } else {
            let a = psx * l2, b = psy * l2
            let aa = a * a, bb = b * b, ta = atan2(ty, tx)
            var cc = bb * l1 * l1 + aa * dd - aa * bb
            let c1 = -2 * bb * l1, c2 = bb - aa
            var d = c1 * c1 - 4 * c2 * cc
            if d >= 0 {
                var q = sqrt(d)
                if c1 < 0 { q = -q }
                q = -(c1 + q) * 0.5
                var r0 = q / c2
                let r1 = cc / q
                let r = abs(r0) < abs(r1) ? r0 : r1
                r0 = dd - r * r
                if r0 >= 0 {
                    y = sqrt(r0) * bend
                    a1 = ta - atan2(y, r)
                    a2 = atan2(y / psy, (r - l1) / psx)
                    break solve
                }
            }
            var minAngle = CGFloat.pi, minX = l1 - a, minDist = minX * minX, minY: CGFloat = 0
            var maxAngle: CGFloat = 0, maxX = l1 + a, maxDist = maxX * maxX, maxY: CGFloat = 0
            cc = -a * l1 / (aa - bb)
            if cc >= -1, cc <= 1 {
                cc = acos(cc)
                x = a * cos(cc) + l1
                y = b * sin(cc)
                d = x * x + y * y
                if d < minDist {
                    minAngle = cc
                    minDist = d
                    minX = x
                    minY = y
                }
                if d > maxDist {
                    maxAngle = cc
                    maxDist = d
                    maxX = x
                    maxY = y
                }
            }
            if dd <= (minDist + maxDist) * 0.5 {
                a1 = ta - atan2(minY * bend, minX)
                a2 = minAngle * bend
            } else {
                a1 = ta - atan2(maxY * bend, maxX)
                a2 = maxAngle * bend
            }
        }
        let os = atan2(cy, cx) * s2
        var rotation = p.arotation
        a1 = (a1 - os) * Self.radDeg + os1 - rotation
        if a1 > 180 { a1 -= 360 } else if a1 < -180 { a1 += 360 }
        updateWorldTransform42(parent, px, py, rotation + a1 * alpha, sx, sy, 0, 0)
        rotation = c.arotation
        a2 = ((a2 + os) * Self.radDeg - c.ashearX) * s2 + os2 - rotation
        if a2 > 180 { a2 -= 360 } else if a2 < -180 { a2 += 360 }
        updateWorldTransform42(child, cx, cy, rotation + a2 * alpha, c.ascaleX, c.ascaleY, c.ashearX, c.ashearY)
    }

    /// spIkConstraint_apply (3.6).
    private func applyIk36(_ index: Int) {
        let ik = data.iks[index]
        let target = bones[ik.target].world
        if ik.bones.count == 1 {
            applyIk1Of36(ik.bones[0], target.x, target.y, ik.mix)
        } else {
            applyIk2Of36(ik.bones[0], ik.bones[1], target.x, target.y, ik.bendDirection, ik.mix)
        }
    }

    private func applyIk1Of36(_ bone: Int, _ targetX: CGFloat, _ targetY: CGFloat, _ alpha: CGFloat) {
        guard let parent = data.bones[bone].parent else { return }
        if !bones[bone].appliedValid { updateAppliedTransform36(bone) }
        let p = bones[parent].world, b = bones[bone]
        let id = 1 / (p.a * p.d - p.b * p.c)
        let x = targetX - p.x, y = targetY - p.y
        let tx = (x * p.d - y * p.b) * id - b.ax, ty = (y * p.a - x * p.c) * id - b.ay
        var rotationIK = atan2(ty, tx) * 180 / .pi - b.ashearX - b.arotation
        if b.ascaleX < 0 { rotationIK += 180 }
        if rotationIK > 180 { rotationIK -= 360 } else if rotationIK < -180 { rotationIK += 360 }
        updateWorldTransform36(bone, b.ax, b.ay, b.arotation + rotationIK * alpha, b.ascaleX, b.ascaleY, b.ashearX, b.ashearY)
    }

    private func applyIk2Of36(_ parent: Int, _ child: Int, _ targetX: CGFloat, _ targetY: CGFloat, _ bendDirection: CGFloat, _ alpha: CGFloat) {
        if alpha == 0 {
            let c = bones[child]
            updateWorldTransform36(child, c.x, c.y, c.rotation, c.scaleX, c.scaleY, c.shearX, c.shearY)
            return
        }
        guard let grandparent = data.bones[parent].parent else { return }
        if !bones[parent].appliedValid { updateAppliedTransform36(parent) }
        if !bones[child].appliedValid { updateAppliedTransform36(child) }
        let p = bones[parent], c = bones[child], pp = bones[grandparent].world
        let px = p.ax, py = p.ay
        var psx = p.ascaleX, psy = p.ascaleY, csx = c.ascaleX
        let o1: CGFloat, o2: CGFloat
        var s2: CGFloat
        if psx < 0 {
            psx = -psx
            o1 = 180
            s2 = -1
        } else {
            o1 = 0
            s2 = 1
        }
        if psy < 0 {
            psy = -psy
            s2 = -s2
        }
        if csx < 0 {
            csx = -csx
            o2 = 180
        } else {
            o2 = 0
        }
        let cx = c.ax
        let cy: CGFloat, cwx: CGFloat, cwy: CGFloat
        let u = abs(psx - psy) <= 0.0001
        if !u {
            cy = 0
            cwx = p.world.a * cx + p.world.x
            cwy = p.world.c * cx + p.world.y
        } else {
            cy = c.ay
            cwx = p.world.a * cx + p.world.b * cy + p.world.x
            cwy = p.world.c * cx + p.world.d * cy + p.world.y
        }
        let id = 1 / (pp.a * pp.d - pp.b * pp.c)
        var x = targetX - pp.x, y = targetY - pp.y
        let tx = (x * pp.d - y * pp.b) * id - px, ty = (y * pp.a - x * pp.c) * id - py
        x = cwx - pp.x
        y = cwy - pp.y
        let dx = (x * pp.d - y * pp.b) * id - px, dy = (y * pp.a - x * pp.c) * id - py
        let l1 = sqrt(dx * dx + dy * dy)
        var l2 = data.bones[child].length * csx
        var a1: CGFloat, a2: CGFloat
        solve: if u {
            l2 *= psx
            let cosine = min(max((tx * tx + ty * ty - l1 * l1 - l2 * l2) / (2 * l1 * l2), -1), 1)
            a2 = acos(cosine) * bendDirection
            let a = l1 + l2 * cosine, b = l2 * sin(a2)
            a1 = atan2(ty * a - tx * b, tx * a + ty * b)
        } else {
            let a = psx * l2, b = psy * l2
            let aa = a * a, bb = b * b, ll = l1 * l1, dd = tx * tx + ty * ty, ta = atan2(ty, tx)
            var c0 = bb * ll + aa * dd - aa * bb
            let c1 = -2 * bb * l1, c2 = bb - aa
            let d = c1 * c1 - 4 * c2 * c0
            if d >= 0 {
                var q = sqrt(d)
                if c1 < 0 { q = -q }
                q = -(c1 + q) / 2
                let r0 = q / c2, r1 = c0 / q
                let r = abs(r0) < abs(r1) ? r0 : r1
                if r * r <= dd {
                    y = sqrt(dd - r * r) * bendDirection
                    a1 = ta - atan2(y, r)
                    a2 = atan2(y / psy, (r - l1) / psx)
                    break solve
                }
            }
            var minAngle = CGFloat.pi, minX = l1 - a, minDist = minX * minX, minY: CGFloat = 0
            var maxAngle: CGFloat = 0, maxX = l1 + a, maxDist = maxX * maxX, maxY: CGFloat = 0
            c0 = -a * l1 / (aa - bb)
            if c0 >= -1, c0 <= 1 {
                c0 = acos(c0)
                x = a * cos(c0) + l1
                y = b * sin(c0)
                let dist = x * x + y * y
                if dist < minDist {
                    minAngle = c0
                    minDist = dist
                    minX = x
                    minY = y
                }
                if dist > maxDist {
                    maxAngle = c0
                    maxDist = dist
                    maxX = x
                    maxY = y
                }
            }
            if dd <= (minDist + maxDist) / 2 {
                a1 = ta - atan2(minY * bendDirection, minX)
                a2 = minAngle * bendDirection
            } else {
                a1 = ta - atan2(maxY * bendDirection, maxX)
                a2 = maxAngle * bendDirection
            }
        }
        let os = atan2(cy, cx) * s2
        a1 = (a1 - os) * 180 / .pi + o1 - p.arotation
        if a1 > 180 { a1 -= 360 } else if a1 < -180 { a1 += 360 }
        updateWorldTransform36(parent, px, py, p.rotation + a1 * alpha, p.ascaleX, p.ascaleY, 0, 0)
        let child2 = bones[child]
        a2 = ((a2 + os) * 180 / .pi - child2.ashearX) * s2 + o2 - child2.arotation
        if a2 > 180 { a2 -= 360 } else if a2 < -180 { a2 += 360 }
        updateWorldTransform36(child, cx, cy, child2.arotation + a2 * alpha, child2.ascaleX, child2.ascaleY, child2.ashearX, child2.ashearY)
    }

    // MARK: - Transform constraint (4.2)

    private func applyTransform(_ index: Int) {
        let constraint = data.transforms[index]
        let mixRotate = constraint.mixRotate, mixX = constraint.mixX, mixY = constraint.mixY
        let mixScaleX = constraint.mixScaleX, mixScaleY = constraint.mixScaleY, mixShearY = constraint.mixShearY
        guard mixRotate != 0 || mixX != 0 || mixY != 0 || mixScaleX != 0 || mixScaleY != 0 || mixShearY != 0 else { return }
        let target = bones[constraint.target]
        if constraint.local {
            for bone in constraint.bones {
                let b = bones[bone]
                var rotation = b.arotation, x = b.ax, y = b.ay, scaleX = b.ascaleX, scaleY = b.ascaleY, shearY = b.ashearY
                if constraint.relative {
                    rotation += (target.arotation + constraint.offsetRotation) * mixRotate
                    x += (target.ax + constraint.offsetX) * mixX
                    y += (target.ay + constraint.offsetY) * mixY
                    scaleX *= (target.ascaleX - 1 + constraint.offsetScaleX) * mixScaleX + 1
                    scaleY *= (target.ascaleY - 1 + constraint.offsetScaleY) * mixScaleY + 1
                    shearY += (target.ashearY + constraint.offsetShearY) * mixShearY
                } else {
                    if mixRotate != 0 { rotation += (target.arotation - rotation + constraint.offsetRotation) * mixRotate }
                    x += (target.ax - x + constraint.offsetX) * mixX
                    y += (target.ay - y + constraint.offsetY) * mixY
                    if mixScaleX != 0, scaleX != 0 { scaleX = (scaleX + (target.ascaleX - scaleX + constraint.offsetScaleX) * mixScaleX) / scaleX }
                    if mixScaleY != 0, scaleY != 0 { scaleY = (scaleY + (target.ascaleY - scaleY + constraint.offsetScaleY) * mixScaleY) / scaleY }
                    if mixShearY != 0 { shearY += (target.ashearY - shearY + constraint.offsetShearY) * mixShearY }
                }
                updateWorldTransform42(bone, x, y, rotation, scaleX, scaleY, b.ashearX, shearY)
            }
            return
        }
        let t = target.world
        let reflect = t.a * t.d - t.b * t.c > 0 ? Self.degRad : -Self.degRad
        let offsetRotation = constraint.offsetRotation * reflect, offsetShearY = constraint.offsetShearY * reflect
        for bone in constraint.bones {
            var w = bones[bone].world
            if mixRotate != 0 {
                let a = w.a, b = w.b, c = w.c, d = w.d
                var r = atan2(t.c, t.a) + offsetRotation - (constraint.relative ? 0 : atan2(c, a))
                if r > .pi { r -= 2 * .pi } else if r < -.pi { r += 2 * .pi }
                r *= mixRotate
                let cosine = cos(r), sine = sin(r)
                w.a = cosine * a - sine * c
                w.b = cosine * b - sine * d
                w.c = sine * a + cosine * c
                w.d = sine * b + cosine * d
            }
            if mixX != 0 || mixY != 0 {
                let x = t.a * constraint.offsetX + t.b * constraint.offsetY + t.x
                let y = t.c * constraint.offsetX + t.d * constraint.offsetY + t.y
                if constraint.relative {
                    w.x += x * mixX
                    w.y += y * mixY
                } else {
                    w.x += (x - w.x) * mixX
                    w.y += (y - w.y) * mixY
                }
            }
            if mixScaleX != 0 {
                var s: CGFloat
                if constraint.relative {
                    s = (sqrt(t.a * t.a + t.c * t.c) - 1 + constraint.offsetScaleX) * mixScaleX + 1
                } else {
                    s = sqrt(w.a * w.a + w.c * w.c)
                    if s != 0 { s = (s + (sqrt(t.a * t.a + t.c * t.c) - s + constraint.offsetScaleX) * mixScaleX) / s }
                }
                w.a *= s
                w.c *= s
            }
            if mixScaleY != 0 {
                var s: CGFloat
                if constraint.relative {
                    s = (sqrt(t.b * t.b + t.d * t.d) - 1 + constraint.offsetScaleY) * mixScaleY + 1
                } else {
                    s = sqrt(w.b * w.b + w.d * w.d)
                    if s != 0 { s = (s + (sqrt(t.b * t.b + t.d * t.d) - s + constraint.offsetScaleY) * mixScaleY) / s }
                }
                w.b *= s
                w.d *= s
            }
            if mixShearY > 0 {
                let b = w.b, d = w.d
                let by = atan2(d, b)
                var r: CGFloat
                if constraint.relative {
                    r = atan2(t.d, t.b) - atan2(t.c, t.a)
                    if r > .pi { r -= 2 * .pi } else if r < -.pi { r += 2 * .pi }
                    r = by + (r - .pi / 2 + offsetShearY) * mixShearY
                } else {
                    r = atan2(t.d, t.b) - atan2(t.c, t.a) - (by - atan2(w.c, w.a))
                    if r > .pi { r -= 2 * .pi } else if r < -.pi { r += 2 * .pi }
                    r = by + (r + offsetShearY) * mixShearY
                }
                let s = sqrt(b * b + d * d)
                w.b = cos(r) * s
                w.d = sin(r) * s
            }
            bones[bone].world = w
            updateAppliedTransform42(bone)
        }
    }

    // MARK: - Physics constraint (4.2)

    /// PhysicsConstraint.update (Physics.update).
    private func applyPhysics(_ index: Int) {
        let data = self.data.physics[index]
        let mix = data.mix
        guard mix != 0 else { return }
        let x = data.x > 0, y = data.y > 0, rotateOrShearX = data.rotate > 0 || data.shearX > 0, scaleX = data.scaleX > 0
        let bone = data.bone
        let length = self.data.bones[bone].length
        var state = trails[index]
        var t = bones[bone].world
        let delta = max(time - state.lastTime, 0)
        state.remaining += delta
        state.lastTime = time
        let bx = t.x, by = t.y
        if state.reset {
            state.reset = false
            state.ux = bx
            state.uy = by
        } else {
            var a = state.remaining
            let inertia = data.inertia, step = data.step, f = self.data.referenceScale
            var d: CGFloat = -1
            let qx = data.limit * delta, qy = qx
            if x || y {
                if x {
                    let u = (state.ux - bx) * inertia
                    state.xOffset += u > qx ? qx : u < -qx ? -qx : u
                    state.ux = bx
                }
                if y {
                    let u = (state.uy - by) * inertia
                    state.yOffset += u > qy ? qy : u < -qy ? -qy : u
                    state.uy = by
                }
                if a >= step {
                    d = pow(data.damping, 60 * step)
                    let m = data.massInverse * step, e = data.strength, w = data.wind * f, g = data.gravity * f
                    repeat {
                        if x {
                            state.xVelocity += (w - state.xOffset * e) * m
                            state.xOffset += state.xVelocity * step
                            state.xVelocity *= d
                        }
                        if y {
                            state.yVelocity -= (g + state.yOffset * e) * m
                            state.yOffset += state.yVelocity * step
                            state.yVelocity *= d
                        }
                        a -= step
                    } while a >= step
                }
                if x { t.x += state.xOffset * mix * data.x }
                if y { t.y += state.yOffset * mix * data.y }
            }
            if rotateOrShearX || scaleX {
                let ca = atan2(t.c, t.a)
                var c: CGFloat = 0, s: CGFloat = 0, mr: CGFloat = 0
                var dx = state.cx - t.x, dy = state.cy - t.y
                if dx > qx { dx = qx } else if dx < -qx { dx = -qx }
                if dy > qy { dy = qy } else if dy < -qy { dy = -qy }
                if rotateOrShearX {
                    mr = (data.rotate + data.shearX) * mix
                    var r = atan2(dy + state.ty, dx + state.tx) - ca - state.rotateOffset * mr
                    state.rotateOffset += (r - (r / (2 * .pi) - 0.5).rounded(.up) * 2 * .pi) * inertia
                    r = state.rotateOffset * mr + ca
                    c = cos(r)
                    s = sin(r)
                    if scaleX {
                        r = length * sqrt(t.a * t.a + t.c * t.c)
                        if r > 0 { state.scaleOffset += (dx * c + dy * s) * inertia / r }
                    }
                } else {
                    c = cos(ca)
                    s = sin(ca)
                    let r = length * sqrt(t.a * t.a + t.c * t.c)
                    if r > 0 { state.scaleOffset += (dx * c + dy * s) * inertia / r }
                }
                a = state.remaining
                if a >= step {
                    if d == -1 { d = pow(data.damping, 60 * step) }
                    let m = data.massInverse * step, e = data.strength, w = data.wind, g = data.gravity, h = length / f
                    while true {
                        a -= step
                        if scaleX {
                            state.scaleVelocity += (w * c - g * s - state.scaleOffset * e) * m
                            state.scaleOffset += state.scaleVelocity * step
                            state.scaleVelocity *= d
                        }
                        if rotateOrShearX {
                            state.rotateVelocity -= ((w * s + g * c) * h + state.rotateOffset * e) * m
                            state.rotateOffset += state.rotateVelocity * step
                            state.rotateVelocity *= d
                            if a < step { break }
                            let r = state.rotateOffset * mr + ca
                            c = cos(r)
                            s = sin(r)
                        } else if a < step {
                            break
                        }
                    }
                }
            }
            state.remaining = a
        }
        state.cx = t.x
        state.cy = t.y
        if rotateOrShearX {
            var o = state.rotateOffset * mix
            if data.shearX > 0 {
                var r: CGFloat = 0
                if data.rotate > 0 {
                    r = o * data.rotate
                    let s = sin(r), c = cos(r), b = t.b
                    t.b = c * b - s * t.d
                    t.d = s * b + c * t.d
                }
                r += o * data.shearX
                let s = sin(r), c = cos(r), a = t.a
                t.a = c * a - s * t.c
                t.c = s * a + c * t.c
            } else {
                o *= data.rotate
                let s = sin(o), c = cos(o)
                let a = t.a
                t.a = c * a - s * t.c
                t.c = s * a + c * t.c
                let b = t.b
                t.b = c * b - s * t.d
                t.d = s * b + c * t.d
            }
        }
        if scaleX {
            let s = 1 + state.scaleOffset * mix * data.scaleX
            t.a *= s
            t.c *= s
        }
        state.tx = length * t.a
        state.ty = length * t.c
        bones[bone].world = t
        trails[index] = state
        updateAppliedTransform42(bone)
    }

    /// Lets every trailing part go from where it is, as if the rig had always stood there.
    public func resetPhysics() {
        for i in trails.indices {
            trails[i] = Trail()
            trails[i].lastTime = time
        }
    }

    // MARK: - Path constraint

    private func applyPath(_ index: Int) {
        let constraint = data.paths[index]
        let mixRotate = constraint.mixRotate, mixX = constraint.mixX
        let mixY = runtime == .spine36 ? mixX : constraint.mixY
        guard
            mixX > 0 || mixY > 0 || mixRotate > 0,
            let attachment = slots[constraint.target].attachment,
            case let .path(path) = data.attachments[attachment]
        else { return }
        let lengthSpacing = constraint.spacingMode == .length
        let tangents = constraint.rotateMode == .tangent, chainScale = constraint.rotateMode == .chainScale
        let boneCount = constraint.bones.count, spacesCount = tangents ? boneCount : boneCount + 1
        if pathSpaces.count < spacesCount { pathSpaces = Array(repeating: 0, count: spacesCount) }
        if pathLengths.count < boneCount { pathLengths = Array(repeating: 0, count: boneCount) }
        pathSpaces[0] = 0
        let spacing = constraint.spacing
        if runtime == .spine42 {
            spaces42(constraint, spacesCount: spacesCount, chainScale: chainScale)
        } else if chainScale || lengthSpacing {
            for i in 0..<(spacesCount - 1) {
                let bone = constraint.bones[i]
                let setupLength = data.bones[bone].length
                let t = bones[bone].world
                let length36 = setupLength == 0 ? 0.000000001 : setupLength
                let x = length36 * t.a, y = length36 * t.c
                let length = sqrt(x * x + y * y)
                if chainScale { pathLengths[i] = length }
                pathSpaces[i + 1] = (lengthSpacing ? length36 + spacing : spacing) * length / length36
            }
        } else {
            for i in 1..<spacesCount { pathSpaces[i] = spacing }
        }
        computeWorldPositions(path, constraint: constraint, spacesCount: spacesCount, tangents: tangents)
        var boneX = pathPositions[0], boneY = pathPositions[1]
        var offsetRotation = constraint.offsetRotation
        let tip: Bool
        if offsetRotation == 0 {
            tip = constraint.rotateMode == .chain
        } else {
            tip = false
            let p = bones[data.slots[constraint.target].bone].world
            offsetRotation *= p.a * p.d - p.b * p.c > 0 ? .pi / 180 : -.pi / 180
        }
        var p = 3
        for i in 0..<boneCount {
            let bone = constraint.bones[i]
            var t = bones[bone].world
            t.x += (boneX - t.x) * mixX
            t.y += (boneY - t.y) * mixY
            let x = pathPositions[p], y = pathPositions[p + 1], dx = x - boneX, dy = y - boneY
            if chainScale {
                let length = pathLengths[i]
                if length != 0 {
                    let s = (sqrt(dx * dx + dy * dy) / length - 1) * mixRotate + 1
                    t.a *= s
                    t.c *= s
                }
            }
            boneX = x
            boneY = y
            if mixRotate > 0 {
                let a = t.a, b = t.b, c = t.c, d = t.d
                var r: CGFloat
                if tangents {
                    r = pathPositions[p - 1]
                } else if pathSpaces[i + 1] == 0 {
                    r = pathPositions[p + 2]
                } else {
                    r = atan2(dy, dx)
                }
                // 3.6 converts the offset to radians twice here (and adds it again below).
                r -= atan2(c, a) - (runtime == .spine36 ? offsetRotation * .pi / 180 : 0)
                if tip {
                    let cosine = cos(r), sine = sin(r)
                    let length = data.bones[bone].length
                    boneX += (length * (cosine * a - sine * c) - dx) * mixRotate
                    boneY += (length * (sine * a + cosine * c) - dy) * mixRotate
                } else {
                    r += offsetRotation
                }
                if r > .pi { r -= 2 * .pi } else if r < -.pi { r += 2 * .pi }
                r *= mixRotate
                let cosine = cos(r), sine = sin(r)
                t.a = cosine * a - sine * c
                t.b = cosine * b - sine * d
                t.c = sine * a + cosine * c
                t.d = sine * b + cosine * d
            }
            bones[bone].world = t
            if runtime == .spine42 { updateAppliedTransform42(bone) } else { bones[bone].appliedValid = false }
            p += 3
        }
    }

    /// PathConstraint.update's spaces (4.2).
    private func spaces42(_ constraint: RigData.PathConstraint, spacesCount: Int, chainScale: Bool) {
        let spacing = constraint.spacing
        let epsilon: CGFloat = 0.00001
        switch constraint.spacingMode {
        case .percent:
            if chainScale {
                for i in 0..<(spacesCount - 1) {
                    let bone = constraint.bones[i], setupLength = data.bones[bone].length, t = bones[bone].world
                    let x = setupLength * t.a, y = setupLength * t.c
                    pathLengths[i] = sqrt(x * x + y * y)
                }
            }
            for i in 1..<spacesCount { pathSpaces[i] = spacing }
        case .proportional:
            var sum: CGFloat = 0
            for i in 0..<(spacesCount - 1) {
                let bone = constraint.bones[i], setupLength = data.bones[bone].length
                if setupLength < epsilon {
                    if chainScale { pathLengths[i] = 0 }
                    pathSpaces[i + 1] = spacing
                } else {
                    let t = bones[bone].world, x = setupLength * t.a, y = setupLength * t.c
                    let length = sqrt(x * x + y * y)
                    if chainScale { pathLengths[i] = length }
                    pathSpaces[i + 1] = length
                    sum += length
                }
            }
            if sum > 0 {
                sum = CGFloat(spacesCount) / sum * spacing
                for i in 1..<spacesCount { pathSpaces[i] *= sum }
            }
        case .length, .fixed:
            let lengthSpacing = constraint.spacingMode == .length
            for i in 0..<(spacesCount - 1) {
                let bone = constraint.bones[i], setupLength = data.bones[bone].length
                if setupLength < epsilon {
                    if chainScale { pathLengths[i] = 0 }
                    pathSpaces[i + 1] = spacing
                } else {
                    let t = bones[bone].world, x = setupLength * t.a, y = setupLength * t.c
                    let length = sqrt(x * x + y * y)
                    if chainScale { pathLengths[i] = length }
                    pathSpaces[i + 1] = (lengthSpacing ? setupLength + spacing : spacing) * length / setupLength
                }
            }
        }
    }

    private func computeWorldPositions(_ path: RigData.Path, constraint: RigData.PathConstraint, spacesCount: Int, tangents: Bool) {
        let slot = constraint.target
        var position = constraint.position
        let percentPosition = constraint.positionMode == .percent
        if pathPositions.count < spacesCount * 3 + 2 { pathPositions = Array(repeating: 0, count: spacesCount * 3 + 2) }
        let closed = path.closed
        var verticesLength = path.vertices.length
        var curveCount = verticesLength / 6
        var previousCurve = -1
        /// What each space is multiplied by, once the path's length is known.
        func multiplier(_ pathLength: CGFloat) -> CGFloat {
            switch constraint.spacingMode {
            case .percent: pathLength
            case .proportional where runtime == .spine42: pathLength / CGFloat(spacesCount)
            default: 1
            }
        }

        if !path.constantSpeed {
            let lengths = path.lengths
            curveCount -= closed ? 1 : 2
            let pathLength = lengths[curveCount]
            if percentPosition { position *= pathLength }
            let scale = multiplier(pathLength)
            if pathWorld.count < 8 { pathWorld = Array(repeating: 0, count: 8) }
            var curve = 0, o = 0
            for i in 0..<spacesCount {
                let space = pathSpaces[i] * scale
                position += space
                var p = position
                if closed {
                    p = p.truncatingRemainder(dividingBy: pathLength)
                    if p < 0 { p += pathLength }
                    curve = 0
                } else if p < 0 {
                    if previousCurve != -2 {
                        previousCurve = -2
                        computeWorldVertices(path.vertices, slot: slot, start: 2, count: 4, into: &pathWorld, offset: 0, stride: 2)
                    }
                    addBeforePosition(p, 0, o)
                    o += 3
                    continue
                } else if p > pathLength {
                    if previousCurve != -3 {
                        previousCurve = -3
                        computeWorldVertices(path.vertices, slot: slot, start: verticesLength - 6, count: 4, into: &pathWorld, offset: 0, stride: 2)
                    }
                    addAfterPosition(p - pathLength, 0, o)
                    o += 3
                    continue
                }
                while true {
                    let length = lengths[curve]
                    if p > length {
                        curve += 1
                        continue
                    }
                    if curve == 0 {
                        p /= length
                    } else {
                        let previous = lengths[curve - 1]
                        p = (p - previous) / (length - previous)
                    }
                    break
                }
                if curve != previousCurve {
                    previousCurve = curve
                    if closed, curve == curveCount {
                        computeWorldVertices(path.vertices, slot: slot, start: verticesLength - 4, count: 4, into: &pathWorld, offset: 0, stride: 2)
                        computeWorldVertices(path.vertices, slot: slot, start: 0, count: 4, into: &pathWorld, offset: 4, stride: 2)
                    } else {
                        computeWorldVertices(path.vertices, slot: slot, start: curve * 6 + 2, count: 8, into: &pathWorld, offset: 0, stride: 2)
                    }
                }
                let w = pathWorld
                addCurvePosition(p, w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], o, tangents || (i > 0 && space == 0))
                o += 3
            }
            return
        }

        // World vertices.
        if closed {
            verticesLength += 2
            if pathWorld.count < verticesLength { pathWorld = Array(repeating: 0, count: verticesLength) }
            computeWorldVertices(path.vertices, slot: slot, start: 2, count: verticesLength - 4, into: &pathWorld, offset: 0, stride: 2)
            computeWorldVertices(path.vertices, slot: slot, start: 0, count: 2, into: &pathWorld, offset: verticesLength - 4, stride: 2)
            pathWorld[verticesLength - 2] = pathWorld[0]
            pathWorld[verticesLength - 1] = pathWorld[1]
        } else {
            curveCount -= 1
            verticesLength -= 4
            if pathWorld.count < verticesLength { pathWorld = Array(repeating: 0, count: verticesLength) }
            computeWorldVertices(path.vertices, slot: slot, start: 2, count: verticesLength, into: &pathWorld, offset: 0, stride: 2)
        }

        // Curve lengths.
        if pathCurves.count < curveCount { pathCurves = Array(repeating: 0, count: curveCount) }
        var pathLength: CGFloat = 0
        var x1 = pathWorld[0], y1 = pathWorld[1]
        var cx1: CGFloat = 0, cy1: CGFloat = 0, cx2: CGFloat = 0, cy2: CGFloat = 0, x2: CGFloat = 0, y2: CGFloat = 0
        var w = 2
        for i in 0..<curveCount {
            cx1 = pathWorld[w]
            cy1 = pathWorld[w + 1]
            cx2 = pathWorld[w + 2]
            cy2 = pathWorld[w + 3]
            x2 = pathWorld[w + 4]
            y2 = pathWorld[w + 5]
            let tmpx = (x1 - cx1 * 2 + cx2) * 0.1875, tmpy = (y1 - cy1 * 2 + cy2) * 0.1875
            let dddfx = ((cx1 - cx2) * 3 - x1 + x2) * 0.09375, dddfy = ((cy1 - cy2) * 3 - y1 + y2) * 0.09375
            var ddfx = tmpx * 2 + dddfx, ddfy = tmpy * 2 + dddfy
            var dfx = (cx1 - x1) * 0.75 + tmpx + dddfx * 0.16666667, dfy = (cy1 - y1) * 0.75 + tmpy + dddfy * 0.16666667
            pathLength += sqrt(dfx * dfx + dfy * dfy)
            dfx += ddfx
            dfy += ddfy
            ddfx += dddfx
            ddfy += dddfy
            pathLength += sqrt(dfx * dfx + dfy * dfy)
            dfx += ddfx
            dfy += ddfy
            pathLength += sqrt(dfx * dfx + dfy * dfy)
            dfx += ddfx + dddfx
            dfy += ddfy + dddfy
            pathLength += sqrt(dfx * dfx + dfy * dfy)
            pathCurves[i] = pathLength
            x1 = x2
            y1 = y2
            w += 6
        }
        if percentPosition { position *= pathLength }
        let scale = multiplier(pathLength)
        var curveLength: CGFloat = 0
        var curve = 0, segment = 0, o = 0
        for i in 0..<spacesCount {
            let space = pathSpaces[i] * scale
            position += space
            var p = position
            if closed {
                p = p.truncatingRemainder(dividingBy: pathLength)
                if p < 0 { p += pathLength }
                curve = 0
            } else if p < 0 {
                addBeforePosition(p, 0, o)
                o += 3
                continue
            } else if p > pathLength {
                addAfterPosition(p - pathLength, verticesLength - 4, o)
                o += 3
                continue
            }
            // The curve holding the position.
            while true {
                let length = pathCurves[curve]
                if p > length {
                    curve += 1
                    continue
                }
                if curve == 0 {
                    p /= length
                } else {
                    let previous = pathCurves[curve - 1]
                    p = (p - previous) / (length - previous)
                }
                break
            }
            // Its segments' lengths.
            if curve != previousCurve {
                previousCurve = curve
                let ii = curve * 6
                x1 = pathWorld[ii]
                y1 = pathWorld[ii + 1]
                cx1 = pathWorld[ii + 2]
                cy1 = pathWorld[ii + 3]
                cx2 = pathWorld[ii + 4]
                cy2 = pathWorld[ii + 5]
                x2 = pathWorld[ii + 6]
                y2 = pathWorld[ii + 7]
                let tmpx = (x1 - cx1 * 2 + cx2) * 0.03, tmpy = (y1 - cy1 * 2 + cy2) * 0.03
                let dddfx = ((cx1 - cx2) * 3 - x1 + x2) * 0.006, dddfy = ((cy1 - cy2) * 3 - y1 + y2) * 0.006
                var ddfx = tmpx * 2 + dddfx, ddfy = tmpy * 2 + dddfy
                var dfx = (cx1 - x1) * 0.3 + tmpx + dddfx * 0.16666667, dfy = (cy1 - y1) * 0.3 + tmpy + dddfy * 0.16666667
                curveLength = sqrt(dfx * dfx + dfy * dfy)
                pathSegments[0] = curveLength
                for s in 1..<8 {
                    dfx += ddfx
                    dfy += ddfy
                    ddfx += dddfx
                    ddfy += dddfy
                    curveLength += sqrt(dfx * dfx + dfy * dfy)
                    pathSegments[s] = curveLength
                }
                dfx += ddfx
                dfy += ddfy
                curveLength += sqrt(dfx * dfx + dfy * dfy)
                pathSegments[8] = curveLength
                dfx += ddfx + dddfx
                dfy += ddfy + dddfy
                curveLength += sqrt(dfx * dfx + dfy * dfy)
                pathSegments[9] = curveLength
                segment = 0
            }
            // Weighted by segment length.
            p *= curveLength
            while true {
                let length = pathSegments[segment]
                if p > length {
                    segment += 1
                    continue
                }
                if segment == 0 {
                    p /= length
                } else {
                    let previous = pathSegments[segment - 1]
                    p = CGFloat(segment) + (p - previous) / (length - previous)
                }
                break
            }
            addCurvePosition(p * 0.1, x1, y1, cx1, cy1, cx2, cy2, x2, y2, o, tangents || (i > 0 && space == 0))
            o += 3
        }
    }

    private func addBeforePosition(_ p: CGFloat, _ i: Int, _ o: Int) {
        let x1 = pathWorld[i], y1 = pathWorld[i + 1]
        let r = atan2(pathWorld[i + 3] - y1, pathWorld[i + 2] - x1)
        pathPositions[o] = x1 + p * cos(r)
        pathPositions[o + 1] = y1 + p * sin(r)
        pathPositions[o + 2] = r
    }

    private func addAfterPosition(_ p: CGFloat, _ i: Int, _ o: Int) {
        let x1 = pathWorld[i + 2], y1 = pathWorld[i + 3]
        let r = atan2(y1 - pathWorld[i + 1], x1 - pathWorld[i])
        pathPositions[o] = x1 + p * cos(r)
        pathPositions[o + 1] = y1 + p * sin(r)
        pathPositions[o + 2] = r
    }

    private func addCurvePosition(
        _ p: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ cx1: CGFloat, _ cy1: CGFloat, _ cx2: CGFloat, _ cy2: CGFloat,
        _ x2: CGFloat, _ y2: CGFloat, _ o: Int, _ tangents: Bool
    ) {
        var p = p
        if p == 0 || p.isNaN {
            if runtime == .spine42 {
                pathPositions[o] = x1
                pathPositions[o + 1] = y1
                pathPositions[o + 2] = atan2(cy1 - y1, cx1 - x1)
                return
            }
            p = 0.0001
        }
        let tt = p * p, ttt = tt * p, u = 1 - p, uu = u * u, uuu = uu * u
        let ut = u * p, ut3 = ut * 3, uut3 = u * ut3, utt3 = ut3 * p
        let x = x1 * uuu + cx1 * uut3 + cx2 * utt3 + x2 * ttt, y = y1 * uuu + cy1 * uut3 + cy2 * utt3 + y2 * ttt
        pathPositions[o] = x
        pathPositions[o + 1] = y
        if tangents {
            if runtime == .spine42, p < 0.001 {
                pathPositions[o + 2] = atan2(cy1 - y1, cx1 - x1)
            } else {
                pathPositions[o + 2] = atan2(y - (y1 * uu + cy1 * ut * 2 + cy2 * tt), x - (x1 * uu + cx1 * ut * 2 + cx2 * tt))
            }
        }
    }

    // MARK: - Vertices

    /// VertexAttachment.computeWorldVertices: `count` values from vertex
    /// value `start`, written from `offset` every `stride`, unscaled;
    /// `relative` takes each bone relative to `origin`.
    private func computeWorldVertices(
        _ vertices: RigData.Vertices, slot: Int, start: Int, count: Int, into out: inout [CGFloat], offset: Int, stride: Int, relative: Bool = false
    ) {
        let end = count + offset
        let deformCount = slots[slot].deformCount
        let ox = relative ? origin.x : 0, oy = relative ? origin.y : 0
        if vertices.bones.isEmpty {
            let t = bones[data.slots[slot].bone].world
            var v = start, w = offset
            while w < end {
                let vx = deformCount > 0 ? slots[slot].deform[v] : vertices.values[v]
                let vy = deformCount > 0 ? slots[slot].deform[v + 1] : vertices.values[v + 1]
                out[w] = vx * t.a + vy * t.b + t.x - ox
                out[w + 1] = vx * t.c + vy * t.d + t.y - oy
                v += 2
                w += stride
            }
            return
        }
        let boneList = vertices.bones, values = vertices.values
        var v = 0, skip = 0, i = 0
        while i < start {
            let n = boneList[v]
            v += n + 1
            skip += n
            i += 2
        }
        var w = offset, b = skip * 3, f = skip * 2
        while w < end {
            var wx: CGFloat = 0, wy: CGFloat = 0
            let n = boneList[v] + v + 1
            v += 1
            while v < n {
                let t = bones[boneList[v]].world
                var vx = values[b], vy = values[b + 1]
                if deformCount > 0 {
                    vx += slots[slot].deform[f]
                    vy += slots[slot].deform[f + 1]
                }
                let weight = values[b + 2]
                wx += (vx * t.a + vy * t.b + t.x - ox) * weight
                wy += (vx * t.c + vy * t.d + t.y - oy) * weight
                v += 1
                b += 3
                f += 2
            }
            out[w] = wx
            out[w + 1] = wy
            w += stride
        }
    }
}
