#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

/// Where Core Text puts an emoji, measured from Apple Color Emoji on macOS
/// 27.2 at every size from 6 to 34 points: what a colour glyph is laid out
/// and drawn by here, whichever emoji face the device has, so emoji sit
/// and space as they do on iOS.
///
/// Core Text draws the face larger than its point size up to 24 points (a
/// quarter larger up to 16), an image as tall as it is wide whose bottom
/// sits a little below the baseline, and spaces it by that image plus the
/// face's tracking at the size, to whole points.
enum EmojiMetrics {
    /// The image's side at point size `size`: up to 16 points a quarter
    /// larger, worked out as Core Text works it, the size over 20 times 25,
    /// to the last bit (11 points' is a hair over 13.75, which tips a frame
    /// rounded out to whole points).
    static func imageSize(_ size: CGFloat) -> CGFloat {
        size <= 16 ? size / 20 * 25 : size < 24 ? 12 + size / 2 : size
    }

    /// Its bottom edge, up from the baseline.
    static func bottom(_ size: CGFloat) -> CGFloat {
        size <= 16 ? -size / 4 : size < 24 ? -4 + (size - 16) / 8 : -size / 8
    }

    /// Apple Color Emoji's tracking (its `trak` table's one track) at the
    /// size, in whole units of 800 to the em: interpolated between the
    /// table's sizes and floored, as Core Text applies it.
    static func tracking(_ size: CGFloat) -> CGFloat {
        let sizes: [CGFloat] = [0, 9, 16, 22, 29], values: [CGFloat] = [0, 46, 46, 30, 0]
        guard size < sizes[sizes.count - 1] else { return 0 }
        let upper = sizes.firstIndex { $0 > size } ?? sizes.count - 1
        let t = (size - sizes[upper - 1]) / (sizes[upper] - sizes[upper - 1])
        return (values[upper - 1] + (values[upper] - values[upper - 1]) * t).rounded(.down)
    }

    /// The pen's advance past it: the image and the tracking, to the
    /// nearest whole point.
    static func advance(_ size: CGFloat) -> CGFloat {
        let image = imageSize(size)
        return (image + tracking(size) * image / 800).rounded()
    }

    /// The image's box from the pen on the baseline, y up, as Core Text
    /// bounds it: in from the pen by two fifths of the tracking, and from 24
    /// points a ten-thousandth of a point larger than the image, which tips
    /// a frame rounded out to whole points.
    static func box(_ size: CGFloat) -> CGRect {
        let image = imageSize(size)
        let side = size >= 24 ? image + 0.0001 : image
        return CGRect(x: 0.4 * tracking(size) * image / 800, y: bottom(size), width: side, height: side)
    }
}

extension FaceHandle {
    /// A colour glyph as premultiplied RGBA, `pixels` square, top row
    /// first: the glyph's advance-wide square, its image centred in it.
    /// A strike's PNG (CBDT, sbix) is decoded with the platform's decoder
    /// (`UIImage.decoder`) and resampled; a COLR glyph is painted at the
    /// size by HarfBuzz's rasteriser. Nil for a glyph with no colour.
    func colourImage(_ glyph: UInt32, pixels: Int) -> RasterImage? {
        guard pixels > 0, pixels <= 1024 else { return nil }
        return run {
            guard let exactFont, let face = hb_font_get_face(exactFont) else { return nil }
            // The strike nearest the size drawn, as Core Text picks one (an
            // emoji face's small strikes are drawn for small sizes).
            if let font = hb_font_create(face) {
                hb_font_set_ppem(font, UInt32(pixels), UInt32(pixels))
                defer { hb_font_destroy(font) }
                if let image = strike(glyph, font: font, pixels: pixels) { return image }
            }
            guard hb_ot_color_glyph_has_paint(face, glyph) != 0 || hb_ot_color_has_layers(face) != 0 else { return nil }
            return paint(glyph, face: face, pixels: pixels)
        }
    }

    /// A strike's PNG for the glyph, decoded and fitted. Called inside `run`.
    private func strike(_ glyph: UInt32, font: OpaquePointer, pixels: Int) -> RasterImage? {
        if let blob = hb_ot_color_glyph_reference_png(font, glyph) {
            defer { hb_blob_destroy(blob) }
            var length: UInt32 = 0
            if let bytes = hb_blob_get_data(blob, &length), length > 0,
               let image = UIImage.decoder?(Data(bytes: bytes, count: Int(length))) {
                return ColourBitmap.fit(image, into: pixels)
            }
        }
        return nil
    }

    /// Paints a COLR glyph with its advance `pixels` wide, centred
    /// vertically on its ink. Called inside `run`.
    private func paint(_ glyph: UInt32, face: OpaquePointer, pixels: Int) -> RasterImage? {
        guard let font = hb_font_create(face) else { return nil }
        defer { hb_font_destroy(font) }
        let upem = Double(hb_face_get_upem(face))
        let advance = Double(hb_font_get_glyph_h_advance(font, glyph))
        guard upem > 0, advance > 0 else { return nil }
        let scale = Int32((Double(pixels) * upem / advance).rounded())
        hb_font_set_scale(font, scale, scale)
        var extents = hb_glyph_extents_t()
        guard hb_font_get_glyph_extents(font, glyph, &extents) != 0,
              let paint = hb_raster_paint_create_or_fail() else { return nil }
        defer { hb_raster_paint_destroy(paint) }
        guard hb_raster_paint_set_glyph_extents(paint, &extents) != 0,
              hb_raster_paint_glyph_or_fail(paint, font, glyph) != 0,
              let image = hb_raster_paint_render(paint) else { return nil }
        defer { hb_raster_paint_recycle_image(paint, image) }
        var area = hb_raster_extents_t()
        hb_raster_image_get_extents(image, &area)
        guard let buffer = hb_raster_image_get_buffer(image), area.width > 0, area.height > 0 else { return nil }
        // Into the square: across from the pen, down so the ink is centred.
        var out = [UInt8](repeating: 0, count: pixels * pixels * 4)
        let top = (pixels - Int(area.height)) / 2
        for row in 0 ..< Int(area.height) {
            // hb-raster's rows run bottom to top.
            let source = buffer + (Int(area.height) - 1 - row) * Int(area.stride)
            let y = top + row
            guard y >= 0, y < pixels else { continue }
            for column in 0 ..< Int(area.width) {
                let x = Int(area.x_origin) + column
                guard x >= 0, x < pixels else { continue }
                let from = source + column * 4, to = (y * pixels + x) * 4
                // BGRA to RGBA, both premultiplied.
                out[to] = from[2]; out[to + 1] = from[1]; out[to + 2] = from[0]; out[to + 3] = from[3]
            }
        }
        return RasterImage(width: pixels, height: pixels, pixels: out)
    }
}

/// Resampling a strike's bitmap to the size it's drawn at.
enum ColourBitmap {
    /// `image` centred in a square as wide as its wider side, resampled to
    /// `pixels` square: averaged over each target pixel's footprint going
    /// down, bilinear going up.
    static func fit(_ image: RasterImage, into pixels: Int) -> RasterImage {
        let side = max(image.width, image.height)
        let left = (side - image.width) / 2, top = (side - image.height) / 2
        let ratio = Double(side) / Double(pixels)
        var out = [UInt8](repeating: 0, count: pixels * pixels * 4)
        func sample(_ x: Int, _ y: Int, _ channel: Int) -> Double {
            let sx = x - left, sy = y - top
            guard sx >= 0, sy >= 0, sx < image.width, sy < image.height else { return 0 }
            return Double(image.pixels[(sy * image.width + sx) * 4 + channel])
        }
        for y in 0 ..< pixels {
            for x in 0 ..< pixels {
                for channel in 0 ..< 4 {
                    var value = 0.0
                    if ratio > 1 {
                        // The footprint [x0, x1) × [y0, y1) in source pixels, weighted by overlap.
                        let x0 = Double(x) * ratio, x1 = x0 + ratio, y0 = Double(y) * ratio, y1 = y0 + ratio
                        var total = 0.0
                        for sy in Int(y0) ..< Int(y1.rounded(.up)) {
                            let wy = min(Double(sy + 1), y1) - max(Double(sy), y0)
                            for sx in Int(x0) ..< Int(x1.rounded(.up)) {
                                let w = (min(Double(sx + 1), x1) - max(Double(sx), x0)) * wy
                                value += sample(sx, sy, channel) * w
                                total += w
                            }
                        }
                        value /= max(total, 1e-9)
                    } else {
                        let fx = (Double(x) + 0.5) * ratio - 0.5, fy = (Double(y) + 0.5) * ratio - 0.5
                        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                        let tx = fx - Double(x0), ty = fy - Double(y0)
                        value = (sample(x0, y0, channel) * (1 - tx) + sample(x0 + 1, y0, channel) * tx) * (1 - ty)
                            + (sample(x0, y0 + 1, channel) * (1 - tx) + sample(x0 + 1, y0 + 1, channel) * tx) * ty
                    }
                    out[(y * pixels + x) * 4 + channel] = UInt8(max(0, min(255, value.rounded())))
                }
            }
        }
        return RasterImage(width: pixels, height: pixels, pixels: out)
    }
}
#endif
