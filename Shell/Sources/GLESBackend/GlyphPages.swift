import CAndroidShell
import Foundation
import GLESRenderer
import ShellCore
import SpriteKitShim
import TextShaping

/// The glyph atlas as GL textures.
///
/// `GlyphAtlas` deliberately touches no GL: it rasterises into 8-bit pages
/// and records what changed. This is the other end of that — one `R8`
/// texture per page, grown as the atlas grows and re-uploaded only where it
/// was written.
///
/// A frame of text in a new language adds glyphs to a page the frame before
/// drew from, so "upload it all, every frame" would mean a megabyte of
/// `glTexImage2D` per frame for a label that has not changed. Instead each
/// page carries a `generation` and a `dirty` rect: the generation says
/// whether anything was written at all, and the rect says how little has to
/// go up — usually one glyph's worth.
final class GlyphPages {
    private let atlas: GlyphAtlas
    private var names: [Int: GLuint] = [:]
    private var generations: [Int: Int] = [:]
    private var sizes: [Int: CGSize] = [:]

    /// Uploads this frame, for the log line that proves the dirty rect is
    /// doing its job rather than hiding a full upload.
    private(set) var uploads = 0
    private(set) var uploadedBytes = 0

    init(atlas: GlyphAtlas) {
        self.atlas = atlas
    }

    /// Brings every page's texture up to date. Called once a frame, before
    /// the labels are drawn, so a glyph rasterised while laying this frame
    /// out is on the GPU by the time its quad is.
    func sync() {
        for (index, page) in atlas.pages.enumerated() {
            sizes[index] = CGSize(width: page.width, height: page.height)

            guard let name = names[index] else {
                upload(whole: page, at: index)
                continue
            }
            guard generations[index] != page.generation else { continue }
            guard let dirty = page.dirty else {
                generations[index] = page.generation
                continue
            }
            upload(dirty, of: page, to: name)
            generations[index] = page.generation
            page.clearDirty()
        }
    }

    /// The texture for a page, or 0 if it has not been made yet.
    func name(of page: Int) -> GLuint { names[page] ?? 0 }

    func size(of page: Int) -> CGSize? { sizes[page] }

    func removeAll() {
        for name in names.values {
            var name = name
            glDeleteTextures(1, &name)
        }
        names.removeAll()
        generations.removeAll()
        sizes.removeAll()
    }

    // MARK: Uploading

    private func upload(whole page: AtlasPage, at index: Int) {
        var name: GLuint = 0
        glGenTextures(1, &name)
        guard name != 0 else {
            Log.error("glGenTextures gave 0 for glyph page \(index)")
            return
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), name)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)

        // One byte a pixel, so one byte of row alignment: the default four
        // would skew every page whose width is not a multiple of four.
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)

        // R8 rather than the old GL_ALPHA: ES 3.0 has sized single-channel
        // formats, and the coverage shader reads `.r`.
        page.pixels.withUnsafeBufferPointer { bytes in
            glTexImage2D(
                GLenum(GL_TEXTURE_2D), 0, GL_R8,
                GLsizei(page.width), GLsizei(page.height), 0,
                GLenum(GL_RED), GLenum(GL_UNSIGNED_BYTE), bytes.baseAddress
            )
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        names[index] = name
        generations[index] = page.generation
        uploads += 1
        uploadedBytes += page.width * page.height
        page.clearDirty()
        Log.info("glyph page \(index): \(page.width)x\(page.height) R8 uploaded whole")
    }

    private func upload(_ dirty: CGRect, of page: AtlasPage, to name: GLuint) {
        let x = max(0, Int(dirty.minX))
        let y = max(0, Int(dirty.minY))
        let width = min(page.width - x, Int(dirty.width.rounded(.up)))
        let height = min(page.height - y, Int(dirty.height.rounded(.up)))
        guard width > 0, height > 0 else { return }

        // `glPixelStorei(GL_UNPACK_ROW_LENGTH)` would let the sub-rectangle
        // be read straight out of the page, but ES 3.0 only guarantees it
        // for ES 3.0 contexts and a stale value would corrupt every later
        // upload, so the rows are copied out instead. A dirty rect is one
        // glyph wide in the common case; this is bytes, not kilobytes.
        var patch = [UInt8](repeating: 0, count: width * height)
        page.pixels.withUnsafeBufferPointer { source in
            patch.withUnsafeMutableBufferPointer { destination in
                for row in 0 ..< height {
                    let from = (y + row) * page.width + x
                    let to = row * width
                    destination.baseAddress!.advanced(by: to)
                        .update(from: source.baseAddress!.advanced(by: from), count: width)
                }
            }
        }

        glBindTexture(GLenum(GL_TEXTURE_2D), name)
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
        patch.withUnsafeBufferPointer { bytes in
            glTexSubImage2D(
                GLenum(GL_TEXTURE_2D), 0,
                GLint(x), GLint(y), GLsizei(width), GLsizei(height),
                GLenum(GL_RED), GLenum(GL_UNSIGNED_BYTE), bytes.baseAddress
            )
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        uploads += 1
        uploadedBytes += width * height
    }
}

/// Where `CoverageGeometry` gets its glyphs: the text engine shapes, the
/// atlas rasterises, and this turns both into the renderer's own terms.
///
/// The two are asked for at **different sizes on purpose**. Shaping happens
/// at the label's own point size, because that is the size the node measured
/// itself at and the positions have to land where `contentFrame` says they
/// will. Rasterising happens at the size times the screen's density, because
/// the atlas rasterises one pixel per point and a 24-point label magnified
/// three times on a phone would be a blur. The bitmap comes back in device
/// pixels and is divided back into points here.
///
/// Shaping is cached per line: a label that has not changed asks for the same
/// string every frame and HarfBuzz is not free. The atlas caches per glyph
/// behind that, so a second label in the same font pays nothing.
final class EngineGlyphSource: CoverageGeometry.GlyphSource {
    private let engine: TextEngine
    private var lines: [Key: [CoverageGeometry.Glyph]] = [:]
    private var pageSizes: [CGSize] = []

    /// Pixels per point, set by the renderer whenever the drawable changes.
    /// Glyphs are rasterised at this density.
    var deviceScale: CGFloat = 1 {
        didSet { if deviceScale != oldValue { lines.removeAll() } }
    }

    private struct Key: Hashable {
        var text: String
        var font: String
        var size: Int
        var density: Int
    }

    init(engine: TextEngine) {
        self.engine = engine
    }

    func glyphs(for line: String, font: FontKey) -> [CoverageGeometry.Glyph] {
        let key = Key(
            text: line,
            font: font.name,
            size: Int((font.size * 64).rounded()),
            density: Int((deviceScale * 64).rounded())
        )
        if let cached = lines[key] { return cached }

        guard font.size > 0, let runs = engine.shape(line, font: font) else { return [] }

        // The atlas rounds a size to FreeType's 1/64 grain, so the scale the
        // glyph really came out at is read back from the rounded size rather
        // than assumed — half a pixel of drift over a line is visible.
        let wanted = max(font.size * max(deviceScale, 0.01), 1.0 / 64)
        let rasterSize = (wanted * 64).rounded() / 64
        let raster = FontKey(name: font.name, size: rasterSize)
        let density = rasterSize / font.size

        var made: [CoverageGeometry.Glyph] = []
        var pen: CGFloat = 0
        for run in runs {
            for glyph in run.glyphs {
                let entry = engine.atlas.glyph(
                    GlyphAtlas.Key(font: raster.name, size: raster.size, glyph: glyph.glyph),
                    font: raster
                )
                if let entry, !entry.isEmpty {
                    let left = pen + glyph.xOffset + entry.bearing.x / density
                    let top = glyph.yOffset + entry.bearing.y / density
                    let width = entry.size.width / density
                    let height = entry.size.height / density
                    made.append(CoverageGeometry.Glyph(
                        page: entry.page,
                        rect: entry.rect,
                        frame: CGRect(x: left, y: top - height, width: width, height: height),
                        cluster: glyph.cluster
                    ))
                }
                pen += glyph.xAdvance
            }
        }

        // A screen's worth of distinct strings is tens, not thousands; this
        // only grows when the text does.
        if lines.count > 512 { lines.removeAll(keepingCapacity: true) }
        lines[key] = made
        return made
    }

    /// Page sizes come from the atlas rather than from the GL side, because
    /// asking for a glyph is what *makes* a page: a line shaped here may
    /// open one the uploader has not seen yet, and its quad still needs the
    /// right texture coordinates this frame.
    func pageSize(_ page: Int) -> CGSize? {
        if page < 0 { return nil }
        if page >= pageSizes.count { refreshPageSizes() }
        return page < pageSizes.count ? pageSizes[page] : nil
    }

    private func refreshPageSizes() {
        pageSizes = engine.atlas.pages.map { CGSize(width: $0.width, height: $0.height) }
    }

    func flush() {
        lines.removeAll()
        pageSizes.removeAll()
    }
}
