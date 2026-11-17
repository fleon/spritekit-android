import CAndroidShell
import Foundation
import ShellCore
import SpriteKitShim

/// Linked programs kept between launches (`glGetProgramBinary`), in the app's
/// cache, and loaded the next time in place of compiling and linking them
/// (`glProgramBinary`).
///
/// Each file is named by a hash of the program's translated sources and sits
/// in a folder named by the driver (its vendor, renderer and version), so a
/// driver update starts a folder afresh and the old one is deleted. The app's
/// build is left out on purpose: a program's sources say all there is to say
/// about it (with `layout`), so the programs an update didn't change load as
/// they did. That's where this beats the driver's own cache, Android's EGL
/// blob cache in the app's `code_cache`, which keeps a relaunch's programs
/// as well but is emptied by every update (a Galaxy M31).
///
/// A binary the driver turns down (a driver updated under the same version
/// string), a file cut short or one that doesn't match its sources is deleted
/// and the program built from source again, then kept anew. Programs are kept
/// until the folder holds `capacity`; past that the least recently used
/// (programs an update left behind among them) go at the next launch.
///
/// `debug.<app>.programcache`, read at start: `off` neither loads nor
/// keeps any, `clear` deletes every kept program first (every launch while
/// it's set: cold launches, for measuring).
///
/// Used from the frame thread and the program builder's (`GLBuilderThread`)
/// at once; GL calls go to whichever context is current on the caller's.
nonisolated final class ProgramCache: @unchecked Sendable {
    /// What the folder may hold.
    static let capacity = 32 * 1024 * 1024
    /// Pruned down to this share of `capacity` when it's over.
    static let pruneTo = 0.75
    /// Bumped whenever how programs are linked changes outside their sources
    /// (`GLDevice.Attribute`'s bindings, the file's layout).
    static let layout: UInt32 = 1
    private static let magic: UInt32 = 0x5357_5042 // "SWPB"
    private static let headerSize = 40

    private let folder: URL
    private let lock = NSLock()
    /// Files in the folder (or on their way), by name, with their sizes.
    private var kept: [String: Int] = [:]
    private var keptBytes = 0
    private let writes = DispatchQueue(label: "ProgramCache.writes", qos: .utility)

    private var stats = Stats()

    struct Stats {
        var loaded = 0
        var loadSeconds: TimeInterval = 0
        var built = 0
        var buildSeconds: TimeInterval = 0
        var rejected = 0
        var saved = 0
        var savedBytes = 0

        var text: String {
            String(
                format: "programs: %d from cache in %.0f ms, %d built in %.0f ms, %d rejected, %d kept (%d KB)",
                loaded, loadSeconds * 1000, built, buildSeconds * 1000, rejected, saved, savedBytes / 1024
            )
        }
    }

    /// Made on a thread with a context current. Nil when it's turned off,
    /// the driver offers no binary formats or there's nowhere to keep them.
    init?(driver: String) {
        let setting = DebugProperty.string("programcache")
        if setting == "off" {
            Log.info("program cache off")
            return nil
        }
        var formats: GLint = 0
        glGetIntegerv(GLenum(GL_NUM_PROGRAM_BINARY_FORMATS), &formats)
        guard formats > 0 else {
            Log.info("program cache off: the driver has no program binary formats")
            return nil
        }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let root = caches.appendingPathComponent("programs", isDirectory: true)
        let tag = "\(Self.layout)|\(driver)"
        let name = String(format: "%016llx", Self.hash(Array(tag.utf8), seed: Self.seeds.0))
        folder = root.appendingPathComponent(name, isDirectory: true)

        let files = FileManager.default
        // Folders kept for another driver are no use now.
        for other in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] where other != name || setting == "clear" {
            try? files.removeItem(at: root.appendingPathComponent(other))
        }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(tag.utf8).write(to: folder.appendingPathComponent("driver.txt"))
        } catch {
            Log.warning("program cache off: \(error)")
            return nil
        }
        prune()
        Log.info("program cache \(name): \(kept.count) programs, \(keptBytes / 1024) KB\(setting == "clear" ? " (cleared)" : "")")
    }

    /// Loads the program for these sources, or builds it with `build` (which
    /// links a program created with `create`) and keeps it. Returns 0 when
    /// building fails.
    func program(vertex: String, fragment: String, create: () -> GLuint, build: (GLuint) -> Bool) -> GLuint {
        let key = Self.key(vertex: vertex, fragment: fragment)
        let file = key.name + ".bin"
        lock.lock()
        let has = kept[file] != nil
        lock.unlock()

        if has {
            let started = MediaTime.source()
            if let program = load(file, key: key, create: create) {
                count { $0.loaded += 1; $0.loadSeconds += MediaTime.source() - started }
                // Used: the last to go when the folder's pruned.
                let url = folder.appendingPathComponent(file)
                writes.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
                return program
            }
            count { $0.rejected += 1 }
            forget(file)
        }

        let started = MediaTime.source()
        let program = create()
        guard program != 0 else { return 0 }
        glProgramParameteri(program, GLenum(GL_PROGRAM_BINARY_RETRIEVABLE_HINT), GL_TRUE)
        guard build(program) else {
            glDeleteProgram(program)
            return 0
        }
        count { $0.built += 1; $0.buildSeconds += MediaTime.source() - started }
        keep(program, file: file, key: key)
        return program
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return stats.text
    }

    private func count(_ change: (inout Stats) -> Void) {
        lock.lock()
        change(&stats)
        lock.unlock()
    }

    // MARK: Files

    /// The header: magic, layout, binary format, payload length, the
    /// payload's hash, the sources' two hashes and their combined length.
    private func load(_ file: String, key: Key, create: () -> GLuint) -> GLuint? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)),
              data.count > Self.headerSize else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> GLuint? in
            func word(_ offset: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            func long(_ offset: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            let length = Int(word(12))
            guard word(0) == Self.magic, word(4) == Self.layout,
                  length == data.count - Self.headerSize,
                  long(24) == key.first, long(32) == key.second, UInt64(word(20)) == key.length else { return nil }
            let payload = UnsafeRawBufferPointer(rebasing: raw[Self.headerSize...])
            guard UInt32(truncatingIfNeeded: Self.hash(payload, seed: Self.seeds.0)) == word(16) else { return nil }
            let program = create()
            guard program != 0 else { return nil }
            glProgramBinary(program, GLenum(word(8)), payload.baseAddress, GLsizei(length))
            var linked: GLint = 0
            glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
            guard linked == GL_TRUE else {
                // A format it doesn't know leaves an error behind: not ours to report.
                while glGetError() != GLenum(GL_NO_ERROR) {}
                glDeleteProgram(program)
                return nil
            }
            return program
        }
    }

    private func keep(_ program: GLuint, file: String, key: Key) {
        var length: GLint = 0
        glGetProgramiv(program, GLenum(GL_PROGRAM_BINARY_LENGTH), &length)
        guard length > 0 else { return }
        lock.lock()
        let size = Int(length) + Self.headerSize
        let fits = kept[file] == nil && keptBytes + size <= Self.capacity
        if fits {
            keptBytes += size
            kept[file] = size
        }
        lock.unlock()
        guard fits else { return }

        var data = Data(count: Self.headerSize + Int(length))
        var written: GLsizei = 0
        var format: GLenum = 0
        let ok = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            let payload = UnsafeMutableRawBufferPointer(rebasing: raw[Self.headerSize...])
            glGetProgramBinary(program, length, &written, &format, payload.baseAddress)
            guard written == length else { return false }
            let digest = UInt32(truncatingIfNeeded: Self.hash(UnsafeRawBufferPointer(payload), seed: Self.seeds.0))
            raw.storeBytes(of: Self.magic, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: Self.layout, toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt32(format), toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: UInt32(length), toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: digest, toByteOffset: 16, as: UInt32.self)
            raw.storeBytes(of: UInt32(truncatingIfNeeded: key.length), toByteOffset: 20, as: UInt32.self)
            raw.storeBytes(of: key.first, toByteOffset: 24, as: UInt64.self)
            raw.storeBytes(of: key.second, toByteOffset: 32, as: UInt64.self)
            return true
        }
        guard ok else {
            forget(file)
            return
        }
        let url = folder.appendingPathComponent(file)
        let finished = data
        writes.async { [self] in
            do {
                try finished.write(to: url, options: .atomic)
                count { $0.saved += 1; $0.savedBytes += finished.count }
            } catch {
                Log.warning("couldn't keep a program: \(error)")
                forget(file)
            }
        }
    }

    private func forget(_ file: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        lock.lock()
        if let size = kept.removeValue(forKey: file) { keptBytes -= size }
        lock.unlock()
    }

    /// Lists the folder, deleting the least recently used files past
    /// `capacity` and any half-written ones.
    private func prune() {
        let files = FileManager.default
        var entries: [(name: String, size: Int, used: Date)] = []
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".bin") {
            let url = folder.appendingPathComponent(name)
            guard let attributes = try? files.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int, size > Self.headerSize else {
                try? files.removeItem(at: url)
                continue
            }
            entries.append((name, size, attributes[.modificationDate] as? Date ?? .distantPast))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        if total > Self.capacity {
            for entry in entries.sorted(by: { $0.used < $1.used }) where Double(total) > Double(Self.capacity) * Self.pruneTo {
                try? files.removeItem(at: folder.appendingPathComponent(entry.name))
                total -= entry.size
                entries.removeAll { $0.name == entry.name }
            }
        }
        kept = Dictionary(entries.map { ($0.name, $0.size) }, uniquingKeysWith: { first, _ in first })
        keptBytes = total
    }

    // MARK: Keys

    struct Key {
        var first: UInt64
        var second: UInt64
        var length: UInt64

        var name: String { String(format: "%016llx%016llx", first, second) }
    }

    private static let seeds: (UInt64, UInt64) = (0xcbf2_9ce4_8422_2325, 0x6c62_272e_07bb_0142)

    static func key(vertex: String, fragment: String) -> Key {
        var bytes = Array(vertex.utf8)
        bytes.append(0)
        bytes.append(contentsOf: fragment.utf8)
        return Key(first: hash(bytes, seed: seeds.0), second: hash(bytes.reversed(), seed: seeds.1), length: UInt64(bytes.count))
    }

    /// FNV-1a, 64 bits.
    static func hash<Bytes: Sequence>(_ bytes: Bytes, seed: UInt64) -> UInt64 where Bytes.Element == UInt8 {
        var value = seed
        for byte in bytes {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01b3
        }
        return value
    }
}
