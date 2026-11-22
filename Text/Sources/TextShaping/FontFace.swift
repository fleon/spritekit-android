#if canImport(CTextShaping)
import CTextShaping
import Foundation
import PlatformServices
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
/// face each rather than one read each. A file on disk is mapped rather than
/// read: a system collection (Noto CJK) is tens of megabytes, of which a
/// line touches a few pages.
public final class FontFile: @unchecked Sendable {
    /// The file's bytes, owned by the file: mapped from disk, or a copy of
    /// bytes handed over. FreeType and HarfBuzz keep pointers into them for
    /// as long as the file lives (every face keeps it), so they are never
    /// borrowed from a `Data`, whose storage a closure only lends.
    let bytes: UnsafeRawBufferPointer
    private let isMapped: Bool
    public let path: String
    private let lock = NSLock()
    /// HarfBuzz's face of each index, over `bytes` themselves (no table
    /// copies), shared by every size.
    private var hbFaces: [Int: OpaquePointer] = [:]

    public init(path: String) throws {
        guard let bytes = MappedFile.map(path) else {
            throw FontError.fileUnreadable(path)
        }
        self.path = path
        self.bytes = bytes
        isMapped = true
    }

    public init(data: Data, name: String) {
        path = name
        let copy = UnsafeMutableRawBufferPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
        data.copyBytes(to: copy.bindMemory(to: UInt8.self))
        bytes = UnsafeRawBufferPointer(rebasing: copy[0 ..< data.count])
        isMapped = false
    }

    deinit {
        for face in hbFaces.values { hb_face_destroy(face) }
        if isMapped {
            MappedFile.unmap(bytes)
        } else {
            bytes.baseAddress.map { UnsafeMutableRawPointer(mutating: $0).deallocate() }
        }
    }

    /// How many faces the file holds: one, or a collection's count.
    var faceCount: Int {
        guard let base = bytes.baseAddress,
              let blob = hb_blob_create(base.assumingMemoryBound(to: CChar.self), UInt32(bytes.count),
                                        HB_MEMORY_MODE_READONLY, nil, nil) else { return 0 }
        defer { hb_blob_destroy(blob) }
        return Int(hb_face_count(blob))
    }

    /// The face at `index` as HarfBuzz reads it straight from the bytes,
    /// which live as long as the file.
    func hbFace(index: Int) -> OpaquePointer? {
        lock.withLock {
            if let face = hbFaces[index] { return face }
            var face: OpaquePointer?
            if let base = bytes.baseAddress,
               let blob = hb_blob_create(base.assumingMemoryBound(to: CChar.self), UInt32(bytes.count),
                                         HB_MEMORY_MODE_READONLY, nil, nil) {
                face = hb_face_create(blob, UInt32(index))
                hb_blob_destroy(blob)
            }
            if let face {
                hb_face_make_immutable(face)
                hbFaces[index] = face
            }
            return face
        }
    }

    /// The PostScript names of the file's named instances, in order. A game
    /// asks for a variable font's instances by name ("SomeFont-Black"), so
    /// this is how a name becomes an axis setting rather than a missing
    /// face.
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
    /// FreeType's library keeps a list of every face opened on it, which
    /// `FT_New_Memory_Face` and `FT_Done_Face` edit without a lock of their
    /// own; faces are made and closed on many threads (and closed wherever
    /// their last user lets go), so both go through this.
    private static let libraryLock = NSLock()

    let file: FontFile
    let size: CGFloat
    private let lock = NSRecursiveLock()
    private(set) var ftFace: FT_Face?
    /// HarfBuzz's own OpenType font over the same face, at a scale of
    /// `subunits` to the font unit: what lines are shaped and measured with.
    /// HarfBuzz over FreeType takes its advances from FreeType in 1/64
    /// points, rounding every glyph's, and FreeType's outlines come scaled to
    /// the same grid; Core Text, which a game is laid out by on Apple,
    /// works from the font's own tables in floating point. Laid out to whole
    /// points as SpriteKit lays labels out, those few hundredths tip frames a
    /// point either way, so measuring here is as fine as Core Text's.
    private(set) var exactFont: OpaquePointer?
    /// Points per unit of `exactFont`.
    private(set) var pointsPerUnit: CGFloat = 0
    static let subunits: Int32 = 64
    /// A variable instance's advance deltas, for the fractions HarfBuzz
    /// rounds away (`AdvanceVariations`); nil for a static face or the
    /// default instance.
    private(set) var advanceVariations: AdvanceVariations?
    private(set) var instanceNames: [String] = []
    /// A colour face (emoji): strikes (CBDT, sbix) or COLR glyphs, laid
    /// out and drawn as Core Text lays out Apple Color Emoji (`EmojiMetrics`).
    private(set) var hasColourGlyphs = false

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
    /// Embedded bitmap strikes are skipped, as Core Text skips them: a face
    /// with strikes at some sizes (Geneva's 9 to 24 ppem) draws its outlines
    /// at those sizes too.
    static let loadFlags = FT_Int32(FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP)

    init(file: FontFile, size: CGFloat, instance: String?, index: Int = 0, variations: [String: Double] = [:]) throws {
        guard let library = FaceHandle.library else { throw FontError.libraryUnavailable }
        self.file = file
        self.size = size

        var face: FT_Face?
        let error = FaceHandle.libraryLock.withLock {
            FT_New_Memory_Face(library, file.bytes.baseAddress?.assumingMemoryBound(to: FT_Byte.self),
                               FT_Long(file.bytes.count), FT_Long(index), &face)
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

        if !variations.isEmpty {
            FaceHandle.setDesignCoordinates(face, variations)
        }

        // 72 dpi so one point is one pixel unit, and 26.6 fixed point so a
        // fractional size survives — games scale labels freely.
        let sized = FT_Set_Char_Size(face, 0, FT_F26Dot6((size * 64).rounded()), 72, 72)
        // A face of bitmap strikes only (colour emoji) takes no other size;
        // it is shaped and measured from its tables all the same.
        let isScalable = FT_Long(face.pointee.face_flags) & FT_FACE_FLAG_SCALABLE != 0
        guard sized == FT_Err_Ok || !isScalable else { throw FontError.sizeRejected(sized) }

        if let hbFace = file.hbFace(index: index), let exact = hb_font_create(hbFace) {
            hasColourGlyphs = hb_ot_color_has_png(hbFace) != 0 || hb_ot_color_has_paint(hbFace) != 0
                || hb_ot_color_has_layers(hbFace) != 0
            let units = Int32(face.pointee.units_per_EM) * FaceHandle.subunits
            hb_font_set_scale(exact, units, units)
            // HarfBuzz counts named instances from 0, FreeType from 1.
            if let instance, let index = instanceNames.firstIndex(of: instance) {
                hb_font_set_var_named_instance(exact, UInt32(index))
            }
            if !variations.isEmpty {
                let settings = variations.map { hb_variation_t(tag: FaceHandle.tag($0.key), value: Float($0.value)) }
                hb_font_set_variations(exact, settings, UInt32(settings.count))
            }
            exactFont = exact
            pointsPerUnit = units > 0 ? size / CGFloat(units) : 0
            var length: UInt32 = 0
            if let coordinates = hb_font_get_var_coords_normalized(exact, &length), length > 0,
               let blob = hb_face_reference_table(hbFace, FaceHandle.tag("HVAR")) {
                defer { hb_blob_destroy(blob) }
                var size: UInt32 = 0
                if let data = hb_blob_get_data(blob, &size), size > 0 {
                    let table = [UInt8](UnsafeRawBufferPointer(start: data, count: Int(size)))
                    advanceVariations = AdvanceVariations(
                        hvar: table, normalizedCoordinates: Array(UnsafeBufferPointer(start: coordinates, count: Int(length)))
                    )
                }
            }
        }
    }

    /// Whether the face has a glyph for `scalar` (its cmap maps it).
    func covers(_ scalar: Unicode.Scalar) -> Bool {
        run {
            guard let exactFont else { return false }
            var glyph: hb_codepoint_t = 0
            return hb_font_get_nominal_glyph(exactFont, scalar.value, &glyph) != 0 && glyph != 0
        }
    }

    /// Sets a variable face's axes by tag; the others keep their defaults.
    private static func setDesignCoordinates(_ face: FT_Face, _ variations: [String: Double]) {
        var master: UnsafeMutablePointer<FT_MM_Var>?
        guard FT_Long(face.pointee.face_flags) & FT_FACE_FLAG_MULTIPLE_MASTERS != 0,
              FT_Get_MM_Var(face, &master) == FT_Err_Ok, let master, let axes = master.pointee.axis else { return }
        defer { FT_Done_MM_Var(FaceHandle.library, master) }
        var coordinates = (0 ..< Int(master.pointee.num_axis)).map { index -> FT_Fixed in
            let axis = axes[index]
            guard let value = variations.first(where: { tag($0.key) == UInt32(axis.tag) })?.value else { return axis.def }
            return FT_Fixed((min(max(value, Double(axis.minimum) / 65536), Double(axis.maximum) / 65536) * 65536).rounded())
        }
        FT_Set_Var_Design_Coordinates(face, FT_UInt(coordinates.count), &coordinates)
    }

    /// An OpenType table tag.
    static func tag(_ name: String) -> hb_tag_t {
        name.utf8.prefix(4).reduce(0) { $0 << 8 | hb_tag_t($1) }
    }

    deinit {
        FaceHandle.libraryLock.withLock {
            if let exactFont { hb_font_destroy(exactFont) }
            if let ftFace { FT_Done_Face(ftFace) }
        }
    }

    /// The face's own PostScript name (a variable font's default instance).
    var postScriptName: String? {
        ftFace.flatMap(FaceHandle.postScriptName)
    }

    private static func postScriptName(_ face: FT_Face) -> String? {
        FT_Get_Postscript_Name(face).map { String(cString: $0) }
    }

    private static func readInstanceNames(_ face: FT_Face) -> [String] {
        readInstances(face).map(\.name)
    }

    /// A variable font's named instances: each one's PostScript name, its
    /// style (subfamily) name and its `wght` value, if it has the axis.
    private static func readInstances(_ face: FT_Face) -> [(name: String, style: String, wght: Int?)] {
        guard FT_Long(face.pointee.face_flags) & FT_FACE_FLAG_MULTIPLE_MASTERS != 0 else {
            return []
        }
        var master: UnsafeMutablePointer<FT_MM_Var>?
        guard FT_Get_MM_Var(face, &master) == FT_Err_Ok, let master else { return [] }
        defer { FT_Done_MM_Var(FaceHandle.library, master) }

        let count = Int(master.pointee.num_namedstyles)
        guard count > 0, let styles = master.pointee.namedstyle else { return [] }
        let axes = master.pointee.axis.map { axis in
            (0..<Int(master.pointee.num_axis)).map { axis[$0].tag }
        } ?? []
        let wghtAxis = axes.firstIndex(of: 0x7767_6874)
        return (0..<count).map { index in
            let style = sfntName(face, id: styles[index].strid) ?? ""
            let wght = wghtAxis.flatMap { axis in
                styles[index].coords.map { Int((Double($0[axis]) / 65536).rounded()) }
            }
            return (sfntName(face, id: styles[index].psid) ?? style, style, wght)
        }
    }

    /// The file's faces as a font descriptor matches them: each named
    /// instance, else the face itself, with its family, style, weight
    /// (an instance's `wght`, else the OS/2 weight class) and slant.
    var catalogFaces: [CatalogFace] {
        run {
            guard let face = ftFace else { return [] }
            let family = face.pointee.family_name.map { String(cString: $0) } ?? ""
            let italic = FT_Long(face.pointee.style_flags) & FT_Long(FT_STYLE_FLAG_ITALIC) != 0
            var weightClass = 400
            if let os2 = FT_Get_Sfnt_Table(face, FT_SFNT_OS2)?.assumingMemoryBound(to: TT_OS2.self),
               os2.pointee.version != 0xFFFF {
                weightClass = Int(os2.pointee.usWeightClass)
            }
            let instances = FaceHandle.readInstances(face).filter { !$0.name.isEmpty }
            guard instances.isEmpty else {
                return instances.map {
                    CatalogFace(
                        name: $0.name, family: family, style: $0.style, weightClass: $0.wght ?? weightClass,
                        isItalic: italic, isInstance: true
                    )
                }
            }
            guard let name = FaceHandle.postScriptName(face) else { return [] }
            let style = face.pointee.style_name.map { String(cString: $0) } ?? ""
            return [CatalogFace(name: name, family: family, style: style, weightClass: weightClass, isItalic: italic, isInstance: false)]
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
        let upem = CGFloat(ftFace.pointee.units_per_EM)
        let scale = upem > 0 ? self.size / upem : 0
        // A scalable face's size metrics are rounded out to whole pixels
        // (ascender up, descender down), a point apiece at 72 dpi; CoreText's
        // are the font's units scaled, so those are read instead.
        let face = ftFace.pointee
        let isScalable = face.face_flags & FT_Long(FT_FACE_FLAG_SCALABLE) != 0 && scale > 0
        // Core Text keeps each as a fraction of the em in 16.16 fixed point,
        // so a face of 1000 units comes out a hair off the exact value (and a
        // whole one can tip a rounded-up height), where 2048 units are exact.
        func scaled16(_ units: Int) -> CGFloat {
            (CGFloat(units) / upem * 65536).rounded() / 65536 * self.size
        }
        let ascent = isScalable ? scaled16(Int(face.ascender)) : CGFloat(scaled.ascender) / 64
        let descent = isScalable ? scaled16(-Int(face.descender)) : -CGFloat(scaled.descender) / 64 // FreeType's is negative
        // The line gap in font units, so a face with none has exactly none.
        let leading = isScalable
            ? scaled16(max(0, Int(face.height) - Int(face.ascender) + Int(face.descender)))
            : max(0, CGFloat(scaled.height) / 64 - ascent - descent)

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
            leading: leading,
            capHeight: capHeight,
            xHeight: xHeight
        )
    }
}

#endif
