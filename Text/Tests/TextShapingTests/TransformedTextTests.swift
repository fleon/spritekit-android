#if canImport(CoreText) && os(macOS)
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Text drawn through a context translated by a fraction (100.3, 99.6) and
/// then mirrored, rotated, sheared or rotated and scaled, against UIKit's
/// renderer on Catalyst (macOS 27.2, smoothing off): the ink's centroid and
/// box in device pixels and its coverage. UIKit snaps every filled glyph's
/// pen in device space, whatever the transform: x down to its pixel size's
/// step, the baseline down to the next row, a ten-thousandth of a pixel
/// either side of one counting as on it.
@Suite("Text through transformed contexts as UIKit draws it")
struct TransformedTextTests {
    struct Case: CustomTestStringConvertible {
        var transform: String, scale: CGFloat, text: String, font: String, size: CGFloat, method: String
        var centroid: CGPoint, box: [Int], ink: Int
        init(_ transform: String, _ scale: CGFloat, _ text: String, _ font: String, _ size: CGFloat, _ method: String,
             centroid: CGPoint, box: [Int], ink: Int) {
            self.transform = transform; self.scale = scale; self.text = text; self.font = font; self.size = size; self.method = method
            self.centroid = centroid; self.box = box; self.ink = ink
        }
        var testDescription: String { "\(transform) \(scale)x \(font) \(method)" }
    }

    static let cases: [Case] = [
        Case("identity", 1, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 100.9909, y: 99.1563), box: [56, 85, 143, 109], ink: 277116),
        Case("identity", 1, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 108.1687, y: 93.8461), box: [56, 85, 159, 100], ink: 142855),
        Case("identity", 1, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 79.2961, y: 94.0903), box: [39, 73, 132, 124], ink: 123148),
        Case("identity", 3, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 303.8686, y: 298.5203), box: [170, 256, 431, 327], ink: 2499486),
        Case("identity", 3, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 325.9274, y: 282.5803), box: [168, 255, 480, 300], ink: 1295128),
        Case("identity", 3, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 239.0675, y: 283.2882), box: [118, 220, 397, 374], ink: 1114817),
        Case("mirrorY", 1, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 100.9909, y: 99.8431), box: [56, 90, 143, 114], ink: 277106),
        Case("mirrorY", 1, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 108.1679, y: 105.1536), box: [56, 99, 159, 114], ink: 142862),
        Case("mirrorY", 1, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 79.2838, y: 104.8898), box: [39, 75, 132, 126], ink: 122760),
        Case("mirrorY", 3, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 303.8685, y: 298.4793), box: [170, 270, 431, 341], ink: 2499452),
        Case("mirrorY", 3, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 325.9269, y: 314.4197), box: [168, 297, 480, 342], ink: 1295136),
        Case("mirrorY", 3, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 239.0687, y: 313.7118), box: [118, 223, 397, 377], ink: 1114810),
        Case("rot30", 1, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 100.7588, y: 100.1922), box: [58, 67, 144, 130], ink: 277600),
        Case("rot30", 1, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 109.7495, y: 99.2791), box: [63, 66, 156, 130], ink: 142864),
        Case("rot30", 1, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 84.5016, y: 84.9593), box: [39, 49, 138, 114], ink: 122308),
        Case("rot30", 3, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 303.5699, y: 300.8580), box: [173, 201, 434, 388], ink: 2502389),
        Case("rot30", 3, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 330.5820, y: 297.9320), box: [190, 197, 469, 389], ink: 1298153),
        Case("rot30", 3, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 254.7481, y: 255.0947), box: [116, 148, 415, 344], ink: 1114560),
        Case("rot90", 1, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 99.8437, y: 100.8661), box: [90, 56, 114, 143], ink: 277096),
        Case("rot90", 1, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 105.1539, y: 108.2578), box: [99, 56, 114, 159], ink: 142854),
        Case("rot90", 1, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 104.8919, y: 79.1591), box: [75, 39, 126, 132], ink: 122770),
        Case("rot90", 3, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 300.4795, y: 302.8649), box: [272, 169, 343, 430], ink: 2499425),
        Case("rot90", 3, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 316.4197, y: 324.9267), box: [299, 167, 344, 479], ink: 1295121),
        Case("rot90", 3, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 315.7114, y: 237.7926), box: [225, 117, 379, 396], ink: 1114815),
        Case("shear", 1, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 100.8711, y: 99.1699), box: [51, 85, 147, 109], ink: 277563),
        Case("shear", 1, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 106.0454, y: 93.8524), box: [50, 85, 160, 100], ink: 142539),
        Case("shear", 1, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 77.2228, y: 94.1372), box: [33, 73, 127, 124], ink: 122383),
        Case("shear", 3, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 303.6593, y: 298.5173), box: [154, 256, 442, 327], ink: 2499257),
        Case("shear", 3, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 319.5234, y: 282.5518), box: [151, 255, 479, 300], ink: 1293104),
        Case("shear", 3, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 232.8733, y: 283.2933), box: [101, 220, 383, 374], ink: 1114490),
        Case("rot30scale3", 1, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 109.2320, y: 153.1458), box: [30, 83, 199, 199], ink: 1435460),
        Case("rot30scale3", 1, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 119.1877, y: 141.1293), box: [47, 79, 199, 199], ink: 649564),
        Case("rot30scale3", 1, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 100.8344, y: 71.3627), box: [0, 0, 199, 145], ink: 637430),
        Case("rot30scale3", 3, "Level", "Montserrat-Black", 31.5, "at", centroid: CGPoint(x: 329.5654, y: 458.9907), box: [93, 248, 599, 599], ink: 12945260),
        Case("rot30scale3", 3, "Level Select", "KoHo-Bold", 20.0, "at", centroid: CGPoint(x: 359.6366, y: 423.6514), box: [142, 237, 599, 599], ink: 5858074),
        Case("rot30scale3", 3, "Are you sure you want to quit?", "Montserrat-Regular", 15.0, "in", centroid: CGPoint(x: 304.1547, y: 214.7783), box: [0, 0, 599, 436], ink: 5760869),
    ]

    @Test("Filled text lands where UIKit fills it, through any transform", arguments: cases)
    func filled(_ item: Case) throws {
        _ = Fonts.engine
        let context = BitmapContext(width: Int(200 * item.scale), height: Int(200 * item.scale), scale: item.scale)
        context.translateBy(x: 100.3, y: 99.6)
        switch item.transform {
        case "rot30": context.rotate(by: .pi / 6)
        case "rot90": context.rotate(by: .pi / 2)
        case "shear": context.concatenate(CGAffineTransform(a: 1, b: 0, c: 0.4, d: 1, tx: 0, ty: 0))
        case "mirrorY": context.scaleBy(x: 1, y: -1)
        case "rot30scale3": context.rotate(by: .pi / 6); context.scaleBy(x: 3, y: 3)
        default: break
        }
        let unit: CGFloat = item.transform == "rot30scale3" ? 1 / 3 : 1
        let run = TextBlock.Run(item.text, font: FontKey(name: item.font, size: item.size), colour: .white)
        if item.method == "at" {
            let block = try #require(TextBlock(runs: [run], maxWidth: nil))
            block.draw(in: CGRect(origin: CGPoint(x: -45.2 * unit, y: -20.7 * unit), size: block.size(in: nil)), context: context)
        } else {
            let block = try #require(TextBlock(runs: [run], maxWidth: 120))
            block.draw(in: CGRect(x: -60.2, y: -30.7, width: 120, height: 80), context: context)
        }
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var box = [context.width, context.height, -1, -1], sx = 0.0, sy = 0.0, sum = 0.0
        for y in 0 ..< context.height {
            for x in 0 ..< context.width {
                let a = Double(data[(y * context.width + x) * 4 + 3])
                guard a > 0 else { continue }
                box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                sx += a * Double(x); sy += a * Double(y); sum += a
            }
        }
        // A seventh of a pixel a scale: FreeType's and CoreGraphics' rasterisers.
        #expect(hypot(sx / sum - item.centroid.x, sy / sum - item.centroid.y) < 0.15 * item.scale,
                "centroid (\(sx / sum), \(sy / sum)) against \(item.centroid)")
        #expect(zip(box, item.box).allSatisfy { abs($0 - $1) <= 1 }, "box \(box) against \(item.box)")
        #expect(abs(sum / Double(item.ink) - 1) < 0.03, "ink \(sum) against \(item.ink)")
    }

    /// "lil" (Montserrat-Black) at x -10.3 after a translate by 50 plus a
    /// fraction, at 3x: where the fraction is .3 or .8, three times the x
    /// comes out a hair under a whole pixel (119.99999999999999), which
    /// UIKit floors as on it. Its ink's centroid on Catalyst.
    static let edges: [(transform: String, size: CGFloat, fraction: CGFloat, centroid: CGPoint)] = [
        ("identity", 11.0, 0.00, CGPoint(x: 134.5471, y: 107.9687)),
        ("identity", 11.0, 0.30, CGPoint(x: 135.5471, y: 108.9687)),
        ("identity", 11.0, 0.55, CGPoint(x: 136.2134, y: 109.9687)),
        ("identity", 11.0, 0.80, CGPoint(x: 137.0401, y: 110.9678)),
        ("identity", 31.5, 0.00, CGPoint(x: 164.2330, y: 141.5950)),
        ("identity", 31.5, 0.30, CGPoint(x: 165.2330, y: 142.5950)),
        ("identity", 31.5, 0.55, CGPoint(x: 165.9033, y: 143.5950)),
        ("identity", 31.5, 0.80, CGPoint(x: 166.9033, y: 144.5950)),
        ("rot90", 11.0, 0.00, CGPoint(x: 191.0324, y: 135.2015)),
        ("rot90", 11.0, 0.30, CGPoint(x: 192.0324, y: 135.8715)),
        ("rot90", 11.0, 0.55, CGPoint(x: 192.5263, y: 136.8715)),
        ("rot90", 11.0, 0.80, CGPoint(x: 193.5263, y: 137.8715)),
        ("rot90", 31.5, 0.00, CGPoint(x: 157.4055, y: 165.2311)),
        ("rot90", 31.5, 0.30, CGPoint(x: 158.4055, y: 165.9014)),
        ("rot90", 31.5, 0.55, CGPoint(x: 158.4055, y: 166.9014)),
        ("rot90", 31.5, 0.80, CGPoint(x: 159.4055, y: 167.9014)),
        ("rot270", 11.0, 0.00, CGPoint(x: 107.4738, y: 164.7985)),
        ("rot270", 11.0, 0.30, CGPoint(x: 108.4738, y: 165.7985)),
        ("rot270", 11.0, 0.55, CGPoint(x: 109.4738, y: 166.4586)),
        ("rot270", 11.0, 0.80, CGPoint(x: 109.9677, y: 167.1285)),
        ("rot270", 31.5, 0.00, CGPoint(x: 140.5953, y: 134.7670)),
        ("rot270", 31.5, 0.30, CGPoint(x: 141.5953, y: 135.4265)),
        ("rot270", 31.5, 0.55, CGPoint(x: 142.5953, y: 136.0968)),
        ("rot270", 31.5, 0.80, CGPoint(x: 143.5953, y: 137.0968)),
        ("mirrorY", 11.0, 0.00, CGPoint(x: 134.5471, y: 192.0311)),
        ("mirrorY", 11.0, 0.30, CGPoint(x: 135.5471, y: 192.0311)),
        ("mirrorY", 11.0, 0.55, CGPoint(x: 136.2134, y: 193.0311)),
        ("mirrorY", 11.0, 0.80, CGPoint(x: 137.0401, y: 194.0319)),
        ("mirrorY", 31.5, 0.00, CGPoint(x: 164.2330, y: 158.4047)),
        ("mirrorY", 31.5, 0.30, CGPoint(x: 165.2330, y: 158.4047)),
        ("mirrorY", 31.5, 0.55, CGPoint(x: 165.9032, y: 159.4047)),
        ("mirrorY", 31.5, 0.80, CGPoint(x: 166.9032, y: 160.4047)),
    ]

    @Test("A pen a hair under a pixel snaps as on it, as UIKit's does")
    func pixelEdge() throws {
        _ = Fonts.engine
        for item in Self.edges {
            let context = BitmapContext(width: 300, height: 300, scale: 3)
            context.translateBy(x: 50 + item.fraction, y: 50 + item.fraction)
            switch item.transform {
            case "rot90": context.rotate(by: .pi / 2)
            case "rot270": context.rotate(by: -.pi / 2)
            case "mirrorY": context.scaleBy(x: 1, y: -1)
            default: break
            }
            let block = try #require(TextBlock(runs: [TextBlock.Run("lil", font: FontKey(name: "Montserrat-Black", size: item.size), colour: .white)], maxWidth: nil))
            block.draw(in: CGRect(origin: CGPoint(x: -10.3, y: -20.7), size: block.size(in: nil)), context: context)
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            var sx = 0.0, sy = 0.0, sum = 0.0
            for y in 0 ..< context.height {
                for x in 0 ..< context.width {
                    let a = Double(data[(y * context.width + x) * 4 + 3])
                    sx += a * Double(x); sy += a * Double(y); sum += a
                }
            }
            #expect(hypot(sx / sum - item.centroid.x, sy / sum - item.centroid.y) < 0.1,
                    "\(item.transform) \(item.size) +\(item.fraction): centroid (\(sx / sum), \(sy / sum)) against \(item.centroid)")
        }
    }

    /// "Level" (Montserrat-Black 15) drawn at a point after a translate by
    /// a fraction and a flip (`scaleBy(1, -1)`), at 1x and 3x: UIKit's ink
    /// box, which the axis-aligned path's row snapping must land on.
    static let flipped: [(scale: CGFloat, translate: CGPoint, at: CGPoint, box: [Int])] = [
        (1.0, CGPoint(x: 0.0, y: 60.0), CGPoint(x: 4.0, y: 4.0), [4, 40, 46, 52]),
        (1.0, CGPoint(x: 0.0, y: 60.0), CGPoint(x: 4.3, y: 3.6), [4, 41, 46, 53]),
        (1.0, CGPoint(x: 0.3, y: 60.37), CGPoint(x: 4.0, y: 4.0), [4, 41, 46, 53]),
        (1.0, CGPoint(x: 0.3, y: 60.37), CGPoint(x: 4.3, y: 3.6), [5, 41, 46, 53]),
        (1.0, CGPoint(x: 2.5, y: 55.5), CGPoint(x: 4.0, y: 4.0), [7, 36, 48, 48]),
        (1.0, CGPoint(x: 2.5, y: 55.5), CGPoint(x: 4.3, y: 3.6), [7, 36, 48, 48]),
        (1.0, CGPoint(x: 1.7, y: 48.62), CGPoint(x: 4.0, y: 4.0), [6, 29, 47, 41]),
        (1.0, CGPoint(x: 1.7, y: 48.62), CGPoint(x: 4.3, y: 3.6), [6, 30, 48, 42]),
        (1.0, CGPoint(x: 0.0, y: 63.81), CGPoint(x: 4.0, y: 4.0), [4, 44, 46, 56]),
        (1.0, CGPoint(x: 0.0, y: 63.81), CGPoint(x: 4.3, y: 3.6), [4, 45, 46, 57]),
        (3.0, CGPoint(x: 0.0, y: 60.0), CGPoint(x: 4.0, y: 4.0), [14, 122, 138, 156]),
        (3.0, CGPoint(x: 0.0, y: 60.0), CGPoint(x: 4.3, y: 3.6), [14, 124, 139, 158]),
        (3.0, CGPoint(x: 0.3, y: 60.37), CGPoint(x: 4.0, y: 4.0), [14, 124, 139, 158]),
        (3.0, CGPoint(x: 0.3, y: 60.37), CGPoint(x: 4.3, y: 3.6), [15, 125, 140, 159]),
        (3.0, CGPoint(x: 2.5, y: 55.5), CGPoint(x: 4.0, y: 4.0), [21, 109, 145, 143]),
        (3.0, CGPoint(x: 2.5, y: 55.5), CGPoint(x: 4.3, y: 3.6), [22, 110, 146, 144]),
        (3.0, CGPoint(x: 1.7, y: 48.62), CGPoint(x: 4.0, y: 4.0), [19, 88, 143, 122]),
        (3.0, CGPoint(x: 1.7, y: 48.62), CGPoint(x: 4.3, y: 3.6), [20, 90, 144, 124]),
        (3.0, CGPoint(x: 0.0, y: 63.81), CGPoint(x: 4.0, y: 4.0), [14, 134, 138, 168]),
        (3.0, CGPoint(x: 0.0, y: 63.81), CGPoint(x: 4.3, y: 3.6), [14, 135, 139, 169]),
    ]

    @Test("A context flipped after a fractional translate draws where UIKit draws")
    func flippedAfterFraction() throws {
        _ = Fonts.engine
        for item in Self.flipped {
            let context = BitmapContext(width: Int(250 * item.scale), height: Int(70 * item.scale), scale: item.scale)
            context.translateBy(x: item.translate.x, y: item.translate.y)
            context.scaleBy(x: 1, y: -1)
            let block = try #require(TextBlock(runs: [TextBlock.Run("Level", font: FontKey(name: "Montserrat-Black", size: 15), colour: .white)], maxWidth: nil))
            block.draw(in: CGRect(origin: item.at, size: block.size(in: nil)), context: context)
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            var box = [context.width, context.height, -1, -1]
            for y in 0 ..< context.height {
                for x in 0 ..< context.width where data[(y * context.width + x) * 4 + 3] > 0 {
                    box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                }
            }
            #expect(box == item.box, "\(item.translate) at \(item.at) \(item.scale)x: \(box) against \(item.box)")
        }
    }
}
#endif
