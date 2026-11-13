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
        guard let hbFont, let buffer = hb_buffer_create(), !text.isEmpty else {
            return ShapedRun(glyphs: [], script: script, byteOffset: byteOffset)
        }
        defer { hb_buffer_destroy(buffer) }

        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { bytes in
            bytes.baseAddress?.withMemoryRebound(to: CChar.self, capacity: bytes.count) { chars in
                hb_buffer_add_utf8(buffer, chars, Int32(bytes.count), 0, Int32(bytes.count))
            }
        }
        hb_buffer_set_direction(buffer, HB_DIRECTION_LTR)
        hb_buffer_set_script(buffer, script.hbScript)
        hb_buffer_set_language(buffer, hb_language_from_string(script.language, -1))
        // Keep clusters as plain byte offsets rather than merged runs, so a
        // test can see a reordering for what it is.
        hb_buffer_set_cluster_level(buffer, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS)

        hb_shape(hbFont, buffer, nil, 0)

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
                xAdvance: CGFloat(positions[index].x_advance) / 64,
                yAdvance: CGFloat(positions[index].y_advance) / 64,
                xOffset: CGFloat(positions[index].x_offset) / 64,
                yOffset: CGFloat(positions[index].y_offset) / 64
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
    /// baseline, in points: positive up, as the game's coordinates run.
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

    private func unsafeOutlineBox(_ glyph: UInt32) -> CGRect? {
        guard let ftFace else { return nil }
        guard FT_Load_Glyph(ftFace, glyph, FaceHandle.loadFlags) == FT_Err_Ok,
              let slot = ftFace.pointee.glyph,
              slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE else { return nil }

        var outline = slot.pointee.outline
        guard outline.n_points > 0 else { return nil }
        var box = FT_BBox()
        FT_Outline_Get_CBox(&outline, &box)
        return CGRect(
            x: CGFloat(box.xMin) / 64,
            y: CGFloat(box.yMin) / 64,
            width: CGFloat(box.xMax - box.xMin) / 64,
            height: CGFloat(box.yMax - box.yMin) / 64
        )
    }
}

#endif

extension FaceHandle {
    /// What one rendered glyph is: 8-bit coverage, where it sits relative to
    /// the pen, and the rows to copy. The buffer belongs to FreeType's glyph
    /// slot and is only valid inside `body`, which is why this is a closure
    /// and not a return value.
    func renderGlyph<T>(
        _ glyph: UInt32,
        _ body: (_ pixels: UnsafePointer<UInt8>?, _ width: Int, _ height: Int,
                 _ pitch: Int, _ left: Int, _ top: Int) -> T
    ) -> T? {
        run {
            guard let ftFace,
                  FT_Load_Glyph(ftFace, glyph, FaceHandle.loadFlags) == FT_Err_Ok,
                  let slot = ftFace.pointee.glyph else { return nil }
            if slot.pointee.format != FT_GLYPH_FORMAT_BITMAP,
               FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) != FT_Err_Ok {
                return nil
            }
            let bitmap = slot.pointee.bitmap
            // Only 8-bit grey is handled; anything else (a colour or mono
            // strike) would need its own path and the game has none.
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
