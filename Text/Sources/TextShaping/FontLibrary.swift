#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

/// What the game's font names resolve to.
///
/// The game asks for faces by the names in `GeometryHelpers.swift` —
/// "ChironGoRoundTC-Black", "-ExtraBold", "-SemiBold" and "KoHo-Bold" — and
/// the first three are named instances of one variable file, not separate
/// files. Registering a file makes all of its instances available at once.
public final class FontLibrary: @unchecked Sendable {
    public static let shared = FontLibrary()

    private let lock = NSLock()
    private var files: [String: FontFile] = [:]                 // path -> file
    /// Each registered file's faces, as CoreText's descriptors list them.
    private var fileFaces: [String: [String]] = [:]             // path -> faces
    private var names: [String: (file: FontFile, instance: String?)] = [:]
    private var faces: [Key: FaceHandle] = [:]
    private var missing: Set<Key> = []
    /// What an unnamed label falls back to, set by the first registration.
    private var defaultName: String?

    private struct Key: Hashable {
        var name: String
        /// Sizes are rounded to 1/64 pt, which is FreeType's own grain, so
        /// animating a label's scale cannot make a face per frame.
        var sixtyFourths: Int
    }

    public init() {}

    /// Registers a font file and every face it holds.
    ///
    /// Returns the names that can now be asked for: the face's own
    /// PostScript name and, for a variable font, each named instance.
    @discardableResult
    public func register(path: String) throws -> [String] {
        let file = try lock.withLock { () -> FontFile in
            if let existing = files[path] { return existing }
            let made = try FontFile(path: path)
            files[path] = made
            return made
        }
        return try register(file: file, key: path)
    }

    @discardableResult
    public func register(data: Data, name: String) throws -> [String] {
        let file = FontFile(data: data, name: name)
        lock.withLock { files[name] = file }
        return try register(file: file, key: name)
    }

    /// The faces of a registered file (by its path, or the name its bytes
    /// were registered under), as CoreText's descriptors list them: a
    /// variable font's named instances, else its one PostScript name. Nil for
    /// a file never registered.
    public func faces(ofFile key: String) -> [String]? {
        lock.withLock { fileFaces[key] }
    }

    /// The faces of the font file at `path`, read without registering it.
    public static func faces(ofFontAt path: String) throws -> [String] {
        try faces(of: FaceHandle(file: FontFile(path: path), size: 16, instance: nil))
    }

    /// Whether `name` (a PostScript, instance or family name) is registered.
    public func hasName(_ name: String) -> Bool {
        lock.withLock { names[name] != nil }
    }

    private static func faces(of probe: FaceHandle) -> [String] {
        let instances = probe.instanceNames.filter { !$0.isEmpty }
        if !instances.isEmpty { return instances }
        return probe.postScriptName.map { [$0] } ?? []
    }

    private func register(file: FontFile, key: String) throws -> [String] {
        // One throwaway face at a nominal size, only to read the name table.
        let probe = try FaceHandle(file: file, size: 16, instance: nil)
        lock.withLock { fileFaces[key] = Self.faces(of: probe) }
        var registered: [String] = []

        if let ftFace = probe.ftFace,
           let family = ftFace.pointee.family_name.map({ String(cString: $0) }) {
            registered.append(family)
        }
        if let ftFace = probe.ftFace,
           let postScript = FT_Get_Postscript_Name(ftFace).map({ String(cString: $0) }) {
            registered.append(postScript)
        }
        registered.append(contentsOf: probe.instanceNames.filter { !$0.isEmpty })

        lock.withLock {
            for name in registered where names[name] == nil {
                names[name] = (file, probe.instanceNames.contains(name) ? name : nil)
            }
            if defaultName == nil { defaultName = registered.first }
        }
        return registered
    }

    /// Every name that can be asked for, for diagnostics and tests.
    public var registeredNames: [String] {
        lock.withLock { names.keys.sorted() }
    }

    /// Nil when the name was never registered. Repeated calls hand back the
    /// same face, so a glyph atlas keyed on it stays stable.
    func face(_ font: FontKey) -> FaceHandle? {
        let size = max(font.size, 1.0 / 64)
        let key = Key(
            name: font.name.isEmpty ? (lock.withLock { defaultName } ?? "") : font.name,
            sixtyFourths: Int((size * 64).rounded())
        )
        return lock.withLock {
            if let cached = faces[key] { return cached }
            guard !missing.contains(key), let entry = names[key.name] else {
                missing.insert(key)
                return nil
            }
            guard let made = try? FaceHandle(
                file: entry.file,
                size: CGFloat(key.sixtyFourths) / 64,
                instance: entry.instance
            ) else {
                missing.insert(key)
                return nil
            }
            faces[key] = made
            return made
        }
    }

    /// Drops every cached face. The registered names stay.
    public func flush() {
        lock.withLock {
            faces.removeAll()
            missing.removeAll()
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

#endif
