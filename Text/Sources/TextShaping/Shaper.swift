#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

extension FaceHandle {
    /// Shapes one stretch of one script.
    ///
    /// Clusters come back as UTF-8 byte offsets into `text`, which is what
    /// HarfBuzz works in, shifted by `byteOffset` so a run's clusters read
    /// against the whole string.
    func shape(_ text: String, script: TextScript, byteOffset: Int = 0) -> ShapedRun {
        run { unsafeShape(text, script: script, byteOffset: byteOffset) }
    }

    private func unsafeShape(_ text: String, script: TextScript, byteOffset: Int) -> ShapedRun {
        guard let exactFont, let buffer = hb_buffer_create(), !text.isEmpty else {
            return ShapedRun(glyphs: [], script: script, byteOffset: byteOffset)
        }
        defer { hb_buffer_destroy(buffer) }

        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { bytes in
            bytes.baseAddress?.withMemoryRebound(to: CChar.self, capacity: bytes.count) { chars in
                hb_buffer_add_utf8(buffer, chars, Int32(bytes.count), 0, Int32(bytes.count))
            }
        }
        hb_buffer_set_direction(buffer, script.isRightToLeft ? HB_DIRECTION_RTL : HB_DIRECTION_LTR)
        hb_buffer_set_script(buffer, script.hbScript)
        hb_buffer_set_language(buffer, hb_language_from_string(script.language, -1))
        // Keep clusters as plain byte offsets rather than merged runs, so a
        // test can see a reordering for what it is.
        hb_buffer_set_cluster_level(buffer, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS)

        hb_shape(exactFont, buffer, nil, 0)

        var count: UInt32 = 0
        guard let infos = hb_buffer_get_glyph_infos(buffer, &count),
              let positions = hb_buffer_get_glyph_positions(buffer, &count) else {
            return ShapedRun(glyphs: [], script: script, byteOffset: byteOffset)
        }

        var glyphs: [ShapedGlyph] = []
        glyphs.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            glyphs.append(ShapedGlyph(
                glyph: infos[index].codepoint,
                cluster: byteOffset + Int(infos[index].cluster),
                // Plus the advance delta's fraction HarfBuzz rounded away (variable instances).
                xAdvance: CGFloat(positions[index].x_advance) * pointsPerUnit
                    + CGFloat(advanceVariations?.fraction(of: infos[index].codepoint) ?? 0) * pointsPerUnit * CGFloat(FaceHandle.subunits),
                yAdvance: CGFloat(positions[index].y_advance) * pointsPerUnit,
                xOffset: CGFloat(positions[index].x_offset) * pointsPerUnit,
                yOffset: CGFloat(positions[index].y_offset) * pointsPerUnit
            ))
        }
        return ShapedRun(glyphs: glyphs, script: script, byteOffset: byteOffset)
    }

    /// Shapes a whole string, one run per script.
    func shapeRuns(_ text: String) -> [ShapedRun] {
        run {
        itemise(text).map { item in
            let offset = text.utf8.distance(from: text.startIndex, to: item.range.lowerBound)
            return shape(String(text[item.range]), script: item.script, byteOffset: offset)
        }
        }
    }

    /// The ink box of a line, measured from the pen's origin on the
    /// baseline, in points: positive up, as SpriteKit's coordinates run.
    func inkBounds(of runs: [ShapedRun]) -> CGRect {
        run { unsafeInkBounds(of: runs) }
    }

    private func unsafeInkBounds(of runs: [ShapedRun]) -> CGRect {
        var pen: CGFloat = 0
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var any = false

        for run in runs {
            for glyph in run.glyphs {
                if let box = unsafeOutlineBox(glyph.glyph) {
                    let x = pen + glyph.xOffset
                    let y = glyph.yOffset
                    minX = min(minX, x + box.minX)
                    maxX = max(maxX, x + box.maxX)
                    minY = min(minY, y + box.minY)
                    maxY = max(maxY, y + box.maxY)
                    any = true
                }
                pen += glyph.xAdvance
            }
        }

        guard any else {
            // Nothing drawn — a line of spaces. It still has width, which is
            // what a centred label is positioned by.
            return CGRect(x: 0, y: 0, width: pen, height: 0)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// One glyph's outline box at this size, in points, baseline-relative.
    func outlineBox(_ glyph: UInt32) -> CGRect? {
        run { unsafeOutlineBox(glyph) }
    }

    /// The outline's control box, every point of it on the curve or off, in
    /// whole font units, as Core Text bounds glyphs in a line (its image
    /// bounds, its glyph-path bounds, and so SpriteKit's label frames).
    /// Drawn by HarfBuzz at `exactFont`'s scale, so the named instance's
    /// variations are in it.
    private func unsafeOutlineBox(_ glyph: UInt32) -> CGRect? {
        guard let exactFont, let funcs = FaceHandle.inkFuncs else { return nil }
        var box = InkBox()
        hb_font_draw_glyph(exactFont, glyph, funcs, &box)
        if box.minX > box.maxX {
            // No outline: a colour bitmap's own box (emoji), where it has one.
            var extents = hb_glyph_extents_t()
            guard hb_font_get_glyph_extents(exactFont, glyph, &extents) != 0, extents.width != 0, extents.height != 0 else { return nil }
            box.add(Double(extents.x_bearing), Double(extents.y_bearing))
            box.add(Double(extents.x_bearing + extents.width), Double(extents.y_bearing + extents.height))
        }
        guard box.minX <= box.maxX, box.minY <= box.maxY else { return nil }
        let unit = Double(FaceHandle.subunits)
        let scale = Double(pointsPerUnit) * unit
        let minX = (box.minX / unit).rounded(.down), maxX = (box.maxX / unit).rounded(.up)
        let minY = (box.minY / unit).rounded(.down), maxY = (box.maxY / unit).rounded(.up)
        return CGRect(x: minX * scale, y: minY * scale, width: (maxX - minX) * scale, height: (maxY - minY) * scale)
    }

    /// Collects the box round an outline's points as HarfBuzz draws it.
    private static let inkFuncs: OpaquePointer? = {
        guard let funcs = hb_draw_funcs_create() else { return nil }
        hb_draw_funcs_set_move_to_func(funcs, { _, data, _, x, y, _ in
            data?.assumingMemoryBound(to: InkBox.self).pointee.add(Double(x), Double(y))
        }, nil, nil)
        hb_draw_funcs_set_line_to_func(funcs, { _, data, _, x, y, _ in
            data?.assumingMemoryBound(to: InkBox.self).pointee.add(Double(x), Double(y))
        }, nil, nil)
        hb_draw_funcs_set_quadratic_to_func(funcs, { _, data, _, cx, cy, x, y, _ in
            guard let box = data?.assumingMemoryBound(to: InkBox.self) else { return }
            box.pointee.add(Double(cx), Double(cy))
            box.pointee.add(Double(x), Double(y))
        }, nil, nil)
        hb_draw_funcs_set_cubic_to_func(funcs, { _, data, _, c1x, c1y, c2x, c2y, x, y, _ in
            guard let box = data?.assumingMemoryBound(to: InkBox.self) else { return }
            box.pointee.add(Double(c1x), Double(c1y))
            box.pointee.add(Double(c2x), Double(c2y))
            box.pointee.add(Double(x), Double(y))
        }, nil, nil)
        hb_draw_funcs_make_immutable(funcs)
        return funcs
    }()
}

/// The box round an outline's points.
struct InkBox {
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity

    mutating func add(_ x: Double, _ y: Double) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}

#endif

extension FaceHandle {
    /// What one rendered glyph is: 8-bit coverage, where it sits relative to
    /// the pen, and the rows to copy. The buffer belongs to FreeType's glyph
    /// slot and is only valid inside `body`, which is why this is a closure
    /// and not a return value.
    /// A glyph's outline at the face's size, in its units (points), y up
    /// from the pen on the baseline: what stroked text strokes.
    func outline(_ glyph: UInt32) -> [PathElement] {
        run {
            guard let ftFace, FT_Load_Glyph(ftFace, glyph, FaceHandle.loadFlags) == FT_Err_Ok,
                  let slot = ftFace.pointee.glyph, slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE else { return [] }
            final class Sink { var elements: [PathElement] = [] }
            func point(_ vector: UnsafePointer<FT_Vector>?) -> CGPoint {
                guard let vector else { return .zero }
                return CGPoint(x: CGFloat(vector.pointee.x) / 64, y: CGFloat(vector.pointee.y) / 64)
            }
            func sink(_ user: UnsafeMutableRawPointer?) -> Sink? {
                user.map { Unmanaged<Sink>.fromOpaque($0).takeUnretainedValue() }
            }
            var funcs = FT_Outline_Funcs(
                move_to: { to, user in
                    guard let sink = sink(user) else { return 1 }
                    if !sink.elements.isEmpty { sink.elements.append(.close) }
                    sink.elements.append(.move(point(to)))
                    return 0
                },
                line_to: { to, user in
                    sink(user)?.elements.append(.line(point(to)))
                    return 0
                },
                conic_to: { control, to, user in
                    sink(user)?.elements.append(.quadCurve(to: point(to), control: point(control)))
                    return 0
                },
                cubic_to: { control1, control2, to, user in
                    sink(user)?.elements.append(.curve(to: point(to), control1: point(control1), control2: point(control2)))
                    return 0
                },
                shift: 0, delta: 0
            )
            let collected = Sink()
            let user = Unmanaged.passUnretained(collected).toOpaque()
            guard FT_Outline_Decompose(&slot.pointee.outline, &funcs, user) == 0 else { return [] }
            if !collected.elements.isEmpty { collected.elements.append(.close) }
            return collected.elements
        } ?? []
    }

    /// `offset` moves an outline glyph by a fraction of a pixel (y up)
    /// before it's rendered, so a glyph drawn at a sub-pixel pen position
    /// keeps its shape there rather than snapping to the grid.
    func renderGlyph<T>(
        _ glyph: UInt32,
        offset: CGPoint = .zero,
        _ body: (_ pixels: UnsafePointer<UInt8>?, _ width: Int, _ height: Int,
                 _ pitch: Int, _ left: Int, _ top: Int) -> T
    ) -> T? {
        run {
            guard let ftFace,
                  FT_Load_Glyph(ftFace, glyph, FaceHandle.loadFlags) == FT_Err_Ok,
                  let slot = ftFace.pointee.glyph else { return nil }
            if offset != .zero, slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE {
                FT_Outline_Translate(&slot.pointee.outline, FT_Pos((offset.x * 64).rounded()), FT_Pos((offset.y * 64).rounded()))
            }
            if slot.pointee.format != FT_GLYPH_FORMAT_BITMAP,
               FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) != FT_Err_Ok {
                return nil
            }
            let bitmap = slot.pointee.bitmap
            // Only 8-bit grey is handled; anything else (a colour or mono
            // strike) would need its own path, which isn't here yet.
            if bitmap.width > 0, bitmap.rows > 0,
               bitmap.pixel_mode != UInt8(FT_PIXEL_MODE_GRAY.rawValue) {
                return nil
            }
            return body(
                bitmap.buffer,
                Int(bitmap.width),
                Int(bitmap.rows),
                Int(bitmap.pitch),
                Int(slot.pointee.bitmap_left),
                Int(slot.pointee.bitmap_top)
            )
        }
    }
}
