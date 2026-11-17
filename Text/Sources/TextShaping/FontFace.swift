#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

public enum FontError: Error, CustomStringConvertible {
    case libraryUnavailable
    case fileUnreadable(String)
    case faceUnreadable(String, Int32)
    case sizeRejected(Int32)
    case glyphUnreadable(UInt32, Int32)
    case noSuchInstance(String)

    public var description: String {
        switch self {
        case .libraryUnavailable: return "FreeType would not start"
        case .fileUnreadable(let path): return "cannot read \(path)"
        case .faceUnreadable(let path, let code): return "FreeType error \(code) reading \(path)"
        case .sizeRejected(let code): return "FreeType error \(code) setting the size"
        case .glyphUnreadable(let glyph, let code): return "FreeType error \(code) loading glyph \(glyph)"
        case .noSuchInstance(let name): return "no named instance \(name)"
        }
    }
}

/// A font file read once and kept, so the many sizes a screen uses cost one
/// face each rather than one read each. Chiron GoRound TC is 50 MB.
public final class FontFile {
    let bytes: [UInt8]
    public let path: String

    public init(path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw FontError.fileUnreadable(path)
        }
        self.path = path
        bytes = [UInt8](data)
    }

    public init(data: Data, name: String) {
        path = name
        bytes = [UInt8](data)
    }

    /// The PostScript names of the file's named instances, in order. Chiron
    /// is a variable font and the game asks for its instances by name
    /// ("ChironGoRoundTC-Black"), so this is how a name becomes an axis
    /// setting rather than a missing face.
    public func namedInstances() throws -> [String] {
        let face = try FaceHandle(file: self, size: 16, instance: nil)
        return face.instanceNames
    }
}

/// Everything FreeType and HarfBuzz hold for one face at one size.
///
/// FreeType faces carry their size as state and are not thread-safe, so a
/// face is made per size rather than resized, over bytes shared with every
/// other size of the same file.
///
/// A face is also *stateful within one size*: `FT_Load_Glyph` writes into
/// the face's single glyph slot, so two threads measuring different strings
/// in the same font overwrite each other's glyph. Everything that touches
/// FreeType or HarfBuzz therefore goes through `run`, and nothing hands a
/// raw `FT_Face` out past it. The lock is recursive because shaping a line
/// loads each of its glyphs in turn.
final class FaceHandle {
    private static let library: FT_Library? = {
        var library: FT_Library?
        return FT_Init_FreeType(&library) == FT_Err_Ok ? library : nil
    }()

    let file: FontFile
    let size: CGFloat
    private let lock = NSRecursiveLock()
    private(set) var ftFace: FT_Face?
    private(set) var hbFont: OpaquePointer?
    /// HarfBuzz's own OpenType font over the same face, at a scale of
    /// `subunits` to the font unit: what lines are shaped and measured with.
    /// HarfBuzz over FreeType takes its advances from FreeType in 1/64
    /// points, rounding every glyph's, and FreeType's outlines come scaled to
    /// the same grid; Core Text, which the game is laid out by on Apple,
    /// works from the font's own tables in floating point. Laid out to whole
    /// points as SpriteKit lays labels out, those few hundredths tip frames a
    /// point either way, so measuring here is as fine as Core Text's.
    private(set) var exactFont: OpaquePointer?
    /// Points per unit of `exactFont`.
    private(set) var pointsPerUnit: CGFloat = 0
    static let subunits: Int32 = 64
    private(set) var instanceNames: [String] = []

    /// Holds the face while `body` uses it. Every call into FreeType or
    /// HarfBuzz on this face is inside one of these.
    @discardableResult
    func run<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Hinting off everywhere. HarfBuzz takes its advances from FreeType, so
    /// shaping and rasterising must load glyphs the same way or the advances
    /// a line is measured with would not be the advances it is drawn with.
    /// It also keeps measurement stable across sizes, which hinting is not.
    static let loadFlags = FT_Int32(FT_LOAD_NO_HINTING)

    init(file: FontFile, size: CGFloat, instance: String?) throws {
        guard let library = FaceHandle.library else { throw FontError.libraryUnavailable }
        self.file = file
        self.size = size

        var face: FT_Face?
        let error = file.bytes.withUnsafeBufferPointer { buffer in
            FT_New_Memory_Face(library, buffer.baseAddress, FT_Long(buffer.count), 0, &face)
        }
        guard error == FT_Err_Ok, let face else {
            throw FontError.faceUnreadable(file.path, error)
        }
        ftFace = face

        instanceNames = FaceHandle.readInstanceNames(face)

        if let instance, !instance.isEmpty {
            // FT_Set_Named_Instance counts from 1; 0 means the default.
            if let index = instanceNames.firstIndex(of: instance) {
                FT_Set_Named_Instance(face, FT_UInt(index + 1))
            } else if instance != FaceHandle.postScriptName(face) {
                throw FontError.noSuchInstance(instance)
            }
        }

        // 72 dpi so one point is one pixel unit, and 26.6 fixed point so a
        // fractional size survives — the game scales labels freely.
        let sized = FT_Set_Char_Size(face, 0, FT_F26Dot6((size * 64).rounded()), 72, 72)
        guard sized == FT_Err_Ok else { throw FontError.sizeRejected(sized) }

        hbFont = hb_ft_font_create_referenced(face)
        if let hbFont {
            hb_ft_font_set_load_flags(hbFont, Int32(FaceHandle.loadFlags))
            if let hbFace = hb_font_get_face(hbFont), let exact = hb_font_create(hbFace) {
                let units = Int32(face.pointee.units_per_EM) * FaceHandle.subunits
                hb_font_set_scale(exact, units, units)
                // HarfBuzz counts named instances from 0, FreeType from 1.
                if let instance, let index = instanceNames.firstIndex(of: instance) {
                    hb_font_set_var_named_instance(exact, UInt32(index))
                }
                exactFont = exact
                pointsPerUnit = units > 0 ? size / CGFloat(units) : 0
            }
        }
    }

    deinit {
        if let exactFont { hb_font_destroy(exactFont) }
        if let hbFont { hb_font_destroy(hbFont) }
        if let ftFace { FT_Done_Face(ftFace) }
    }

    /// The face's own PostScript name (a variable font's default instance).
    var postScriptName: String? {
        ftFace.flatMap(FaceHandle.postScriptName)
    }

    private static func postScriptName(_ face: FT_Face) -> String? {
        FT_Get_Postscript_Name(face).map { String(cString: $0) }
    }

    private static func readInstanceNames(_ face: FT_Face) -> [String] {
        guard FT_Long(face.pointee.face_flags) & FT_FACE_FLAG_MULTIPLE_MASTERS != 0 else {
            return []
        }
        var master: UnsafeMutablePointer<FT_MM_Var>?
        guard FT_Get_MM_Var(face, &master) == FT_Err_Ok, let master else { return [] }
        defer { FT_Done_MM_Var(FaceHandle.library, master) }

        let count = Int(master.pointee.num_namedstyles)
        guard count > 0, let styles = master.pointee.namedstyle else { return [] }
        return (0..<count).map { index in
            sfntName(face, id: styles[index].psid)
                ?? sfntName(face, id: styles[index].strid)
                ?? ""
        }
    }

    /// Reads one name-table entry. Names are stored per platform and
    /// encoding; the Windows/Unicode entries are UTF-16BE and the Macintosh
    /// ones are effectively ASCII for the names we want, so both are handled
    /// and anything else is skipped.
    private static func sfntName(_ face: FT_Face, id: FT_UInt) -> String? {
        let count = FT_Get_Sfnt_Name_Count(face)
        for index in 0..<count {
            var entry = FT_SfntName()
            guard FT_Get_Sfnt_Name(face, index, &entry) == FT_Err_Ok,
                  FT_UInt(entry.name_id) == id,
                  let string = entry.string else { continue }
            let bytes = UnsafeBufferPointer(start: string, count: Int(entry.string_len))
            if entry.platform_id == 3 || entry.platform_id == 0 {
                var scalars = ""
                var i = 0
                while i + 1 < bytes.count {
                    let unit = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
                    if let scalar = Unicode.Scalar(unit) { scalars.unicodeScalars.append(scalar) }
                    i += 2
                }
                if !scalars.isEmpty { return scalars }
            } else {
                let scalars = String(decoding: bytes, as: UTF8.self)
                if !scalars.isEmpty { return scalars }
            }
        }
        return nil
    }

    var metrics: FontMetrics { run { unsafeMetrics } }

    private var unsafeMetrics: FontMetrics {
        guard let ftFace, let size = ftFace.pointee.size else {
            return FontMetrics(ascent: 0, descent: 0, leading: 0, capHeight: 0, xHeight: 0)
        }
        let scaled = size.pointee.metrics
        let ascent = CGFloat(scaled.ascender) / 64
        let descent = -CGFloat(scaled.descender) / 64          // FreeType's is negative
        let lineHeight = CGFloat(scaled.height) / 64
        let upem = CGFloat(ftFace.pointee.units_per_EM)
        let scale = upem > 0 ? self.size / upem : 0

        var capHeight = ascent * 0.7
        var xHeight = ascent * 0.5
        if let os2 = FT_Get_Sfnt_Table(ftFace, FT_SFNT_OS2)?
            .assumingMemoryBound(to: TT_OS2.self), os2.pointee.version >= 2 {
            if os2.pointee.sCapHeight > 0 { capHeight = CGFloat(os2.pointee.sCapHeight) * scale }
            if os2.pointee.sxHeight > 0 { xHeight = CGFloat(os2.pointee.sxHeight) * scale }
        }

        return FontMetrics(
            ascent: ascent,
            descent: descent,
            // UIKit's lineHeight is ascent + descent + leading, and
            // FreeType's `height` is the whole line, so the leading is
            // whatever that line leaves over.
            leading: max(0, lineHeight - ascent - descent),
            capHeight: capHeight,
            xHeight: xHeight
        )
    }
}

#endif
