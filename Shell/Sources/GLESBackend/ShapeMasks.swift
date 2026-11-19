#if canImport(Android)
import Android
#endif
import CAndroidShell
import Foundation
import GLESRenderer
import ShellCore
import SpriteKitShim

/// Rasterised shapes, kept as R8 coverage textures.
///
/// `SKShapeNode`'s path is a value the game rebuilds freely — the loading
/// spinner writes a new one every frame — so the cache cannot key on the
/// path object's identity, or an animated shape would hold a texture per
/// frame for ever and a *reused* path would never be recognised. It keys on
/// what the shape actually draws: the digest of its segments, the fill rule,
/// the stroke's width, cap and join, and the scale it was rasterised at.
///
/// Hashing a few hundred points is far cheaper than rasterising them, so a
/// still shape costs a hash a frame and an animated one costs what it would
/// have cost CoreGraphics.
final class ShapeMasks {
    /// What one shape resolved to this frame.
    struct Entry {
        var name: GLuint
        /// The mask's rectangle in the shape's own coordinates.
        var bounds: CGRect
    }

    private struct Key: Hashable {
        var digest: Int
        var kind: Int               // 0 fill, 1 stroke
        var rule: Int
        var width: Int              // hundredths of a point
        var cap: Int
        var join: Int
        var scale: Int              // hundredths of a pixel per point
        var edge: Int = 0           // twentieths of a screen pixel per point
    }

    private struct Cached {
        var name: GLuint
        var bounds: CGRect
        var bytes: Int
        var used: UInt64
    }

    /// Masks are a few hundred kilobytes each at worst and the HUD has a
    /// handful on screen. The cap is what stops an animated path (a new
    /// mask a frame) from growing without bound.
    private let budget = 24 * 1024 * 1024

    private var cache: [Key: Cached] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    /// The clock as the frame began: masks staged since are drawn later in
    /// the frame, so they're never evicted before it ends.
    private var frameStart: UInt64 = 0

    private(set) var rasterised = 0
    /// What rasterising and uploading the masks has cost so far, in seconds:
    /// a shape whose path changes every frame pays both every frame.
    private(set) var rasteriseSeconds = 0.0
    private(set) var uploadSeconds = 0.0

    /// The mask for a shape's fill, rasterised on a miss. Nil when the path
    /// encloses nothing.
    func fill(_ path: CGPath, rule: PathRasteriser.FillRule, scale: CGFloat, owner: ObjectIdentifier? = nil) -> Entry? {
        let key = Key(
            digest: digest(of: path), kind: 0, rule: rule == .evenOdd ? 1 : 0,
            width: 0, cap: 0, join: 0, scale: quantised(scale)
        )
        return entry(for: key, owner: owner.map { OwnerKey(node: $0, kind: 0) }) {
            // SpriteKit's edges, as the shapes drawn as triangles have.
            SpriteKitMasks.fill(path, rule: rule, scale: scale)
        }
    }

    /// The mask for a shape's stroke.
    func stroke(
        _ path: CGPath,
        width: CGFloat,
        cap: CGLineCap,
        join: CGLineJoin,
        scale: CGFloat,
        edgePixels: CGFloat,
        owner: ObjectIdentifier? = nil
    ) -> Entry? {
        let edge = quantised(edgePixels)
        let key = Key(
            digest: digest(of: path), kind: 1, rule: 0,
            width: Int((width * 100).rounded()), cap: cap.rawValue, join: join.rawValue,
            scale: quantised(scale), edge: edge
        )
        return entry(for: key, owner: owner.map { OwnerKey(node: $0, kind: 1) }) {
            // SpriteKit's edge, in the screen's pixels (`Edges.spriteKit`).
            SpriteKitMasks.stroke(path, width: width, cap: cap, join: join, scale: scale, edgePixels: CGFloat(edge) / 20)
        }
    }

    func beginFrame() {
        frameStart = clock + 1
        lag.beginFrame()
        landMade()
    }

    // MARK: Masks made off the frame thread

    /// Whether a shape whose path changes draws its last mask while the new
    /// one is made on a worker (`MaskLag`). Off for a fixed frame step, where
    /// a capture wants every frame exactly as drawn.
    nonisolated(unsafe) static var lagsChangingPaths = true

    private struct OwnerKey: Hashable {
        var node: ObjectIdentifier
        var kind: Int
    }

    private var lag = MaskLag<Key, OwnerKey>()
    /// The work for each key a shape has asked for and a worker may make.
    private var work: [OwnerKey: (key: Key, make: @Sendable () -> PathRasteriser.Mask?)] = [:]
    private let madeLock = NSLock()
    nonisolated(unsafe) private var made: [(owner: OwnerKey, key: Key, mask: PathRasteriser.Mask?)] = []
    private static let worker = MaskWorker()

    private func start(_ key: Key, for owner: OwnerKey, _ make: @escaping @Sendable () -> PathRasteriser.Mask?) {
        Self.worker.add { [weak self] in
            let mask = make()
            guard let self else { return }
            self.madeLock.lock()
            self.made.append((owner, key, mask))
            self.madeLock.unlock()
        }
    }

    /// Uploads what the workers have made, and starts what each shape has
    /// asked for since.
    private func landMade() {
        madeLock.lock()
        let landed = made
        made.removeAll()
        madeLock.unlock()
        for item in landed {
            if let mask = item.mask, !mask.isEmpty, cache[item.key] == nil, let name = upload(mask) {
                rasterised += 1
                cache[item.key] = Cached(name: name, bounds: mask.bounds, bytes: mask.byteCount, used: clock)
                bytes += mask.byteCount
            }
            if let next = lag.finished(owner: item.owner, key: item.key), let wanted = work[item.owner], wanted.key == next {
                start(next, for: item.owner, wanted.make)
            }
        }
        if !landed.isEmpty { evictIfNeeded() }
    }

    func removeAll() {
        for entry in cache.values {
            var name = entry.name
            glDeleteTextures(1, &name)
        }
        cache.removeAll()
        bytes = 0
    }

    // MARK: Behind it

    private func entry(for key: Key, owner: OwnerKey? = nil, make: @escaping @Sendable () -> PathRasteriser.Mask?) -> Entry? {
        clock += 1
        if let owner, Self.lagsChangingPaths {
            let (decision, startKey) = lag.resolve(owner: owner, key: key) { cache[$0] != nil }
            switch decision {
            case let .ready(ready), let .previous(ready):
                if case .previous = decision {
                    work[owner] = (key, make)
                    if let startKey { start(startKey, for: owner, make) }
                }
                guard var hit = cache[ready] else { return nil }
                hit.used = clock
                cache[ready] = hit
                return Entry(name: hit.name, bounds: hit.bounds)
            case .now:
                defer { if cache[key] != nil { lag.drewNow(owner: owner, key: key) } }
                return entryNow(for: key, make: make)
            }
        }
        return entryNow(for: key, make: make)
    }

    private func entryNow(for key: Key, make: () -> PathRasteriser.Mask?) -> Entry? {
        if var hit = cache[key] {
            hit.used = clock
            cache[key] = hit
            return Entry(name: hit.name, bounds: hit.bounds)
        }
        let started = MediaTime.source()
        guard let mask = make(), !mask.isEmpty else { return nil }
        let rasterised = MediaTime.source()
        rasteriseSeconds += rasterised - started
        guard let name = upload(mask) else { return nil }
        uploadSeconds += MediaTime.source() - rasterised

        self.rasterised += 1
        cache[key] = Cached(name: name, bounds: mask.bounds, bytes: mask.byteCount, used: clock)
        bytes += mask.byteCount
        evictIfNeeded()
        return Entry(name: name, bounds: mask.bounds)
    }

    private func evictIfNeeded() {
        guard bytes > budget else { return }
        for (key, entry) in cache.sorted(by: { $0.value.used < $1.value.used }) where entry.used < frameStart {
            var name = entry.name
            glDeleteTextures(1, &name)
            cache.removeValue(forKey: key)
            bytes -= entry.bytes
            if bytes <= budget / 2 { break }
        }
    }

    private func upload(_ mask: PathRasteriser.Mask) -> GLuint? {
        var name: GLuint = 0
        glGenTextures(1, &name)
        guard name != 0 else {
            Log.error("glGenTextures gave 0 for a shape mask")
            return nil
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), name)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        // A mask's own margin is transparent, so clamping cannot smear its
        // last column across the quad's edge.
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
        mask.pixels.withUnsafeBufferPointer { bytes in
            glTexImage2D(
                GLenum(GL_TEXTURE_2D), 0, GL_R8,
                GLsizei(mask.width), GLsizei(mask.height), 0,
                GLenum(GL_RED), GLenum(GL_UNSIGNED_BYTE), bytes.baseAddress
            )
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        return name
    }

    /// Scale is quantised so that a shape easing through a scale animation
    /// does not rasterise at every intermediate size. A twentieth of a pixel
    /// per point is below what the eye reads as a resampling step.
    private func quantised(_ scale: CGFloat) -> Int { Int((scale * 20).rounded()) }

    /// A hash of what the path draws (`PathDigest`), shared with the
    /// shapes drawn as triangles.
    private func digest(of path: CGPath) -> Int { PathDigest.of(path) }
}

/// The thread masks are made on: one of its own, at the lowest priority, so
/// it takes only what the frame thread leaves of the CPU. A phone has two
/// fast cores; a mask job given a share of one made frames late even with
/// the frame thread's own work halved.
nonisolated private final class MaskWorker: @unchecked Sendable {
    private let lock = NSCondition()
    private var jobs: [() -> Void] = []

    init() {
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "ShapeMasks"
        thread.start()
    }

    func add(_ job: @escaping () -> Void) {
        lock.lock()
        jobs.append(job)
        lock.signal()
        lock.unlock()
    }

    private func run() {
        // The calling thread's niceness, as Linux counts it.
        #if canImport(Android)
        setpriority(PRIO_PROCESS, 0, 19)
        #endif
        while true {
            lock.lock()
            while jobs.isEmpty { lock.wait() }
            let job = jobs.removeFirst()
            lock.unlock()
            job()
        }
    }
}
