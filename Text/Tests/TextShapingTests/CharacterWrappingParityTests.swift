#if canImport(CoreText) && os(macOS)
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// `.byCharWrapping` against UIKit on Mac Catalyst: sentences, spaced
/// letters and runs of spaces, at widths 60 to 200.
@Suite("Character wrapping as UIKit wraps") struct CharacterWrappingParityTests {
    static let texts = ["Are you sure you want to quit? You will lose this game.", "Find a player near you and play together", "a b c d e f g h i j k l m n o p", "Hello   wide   spaces   here"]

    static let cases: [(String, CGFloat, Int, CGFloat, w: CGFloat, h: CGFloat)] = [
        ("Montserrat-Black", 15.0, 0, 60.0, w: 58.769999999999996, h: 171.0),
        ("Montserrat-Black", 15.0, 0, 80.0, w: 78.75, h: 114.0),
        ("Montserrat-Black", 15.0, 0, 100.0, w: 98.475, h: 95.0),
        ("Montserrat-Black", 15.0, 0, 120.0, w: 118.21499999999999, h: 76.0),
        ("Montserrat-Black", 15.0, 0, 140.0, w: 137.83499999999998, h: 76.0),
        ("Montserrat-Black", 15.0, 0, 160.0, w: 158.385, h: 57.0),
        ("Montserrat-Black", 15.0, 0, 180.0, w: 176.775, h: 57.0),
        ("Montserrat-Black", 15.0, 0, 200.0, w: 198.20999999999998, h: 57.0),
        ("Montserrat-Black", 15.0, 1, 60.0, w: 58.004999999999995, h: 133.0),
        ("Montserrat-Black", 15.0, 1, 80.0, w: 79.365, h: 95.0),
        ("Montserrat-Black", 15.0, 1, 100.0, w: 98.595, h: 76.0),
        ("Montserrat-Black", 15.0, 1, 120.0, w: 111.09, h: 57.0),
        ("Montserrat-Black", 15.0, 1, 140.0, w: 139.77, h: 57.0),
        ("Montserrat-Black", 15.0, 1, 160.0, w: 153.255, h: 57.0),
        ("Montserrat-Black", 15.0, 1, 180.0, w: 170.715, h: 38.0),
        ("Montserrat-Black", 15.0, 1, 200.0, w: 195.26999999999998, h: 38.0),
        ("Montserrat-Black", 15.0, 2, 60.0, w: 58.904999999999994, h: 76.0),
        ("Montserrat-Black", 15.0, 2, 80.0, w: 78.57000000000001, h: 57.0),
        ("Montserrat-Black", 15.0, 2, 100.0, w: 98.235, h: 57.0),
        ("Montserrat-Black", 15.0, 2, 120.0, w: 118.15499999999999, h: 38.0),
        ("Montserrat-Black", 15.0, 2, 140.0, w: 132.165, h: 38.0),
        ("Montserrat-Black", 15.0, 2, 160.0, w: 156.57, h: 38.0),
        ("Montserrat-Black", 15.0, 2, 180.0, w: 176.67, h: 38.0),
        ("Montserrat-Black", 15.0, 2, 200.0, w: 191.7, h: 38.0),
        ("Montserrat-Black", 15.0, 3, 60.0, w: 55.92, h: 76.0),
        ("Montserrat-Black", 15.0, 3, 80.0, w: 74.85, h: 57.0),
        ("Montserrat-Black", 15.0, 3, 100.0, w: 99.72, h: 57.0),
        ("Montserrat-Black", 15.0, 3, 120.0, w: 117.195, h: 38.0),
        ("Montserrat-Black", 15.0, 3, 140.0, w: 137.21999999999997, h: 38.0),
        ("Montserrat-Black", 15.0, 3, 160.0, w: 156.165, h: 38.0),
        ("Montserrat-Black", 15.0, 3, 180.0, w: 178.14, h: 38.0),
        ("Montserrat-Black", 15.0, 3, 200.0, w: 198.615, h: 38.0),
        ("KoHo-Bold", 20.0, 0, 60.0, w: 58.6, h: 234.0),
        ("KoHo-Bold", 20.0, 0, 80.0, w: 76.96000000000001, h: 182.0),
        ("KoHo-Bold", 20.0, 0, 100.0, w: 97.58, h: 130.0),
        ("KoHo-Bold", 20.0, 0, 120.0, w: 118.75999999999999, h: 130.0),
        ("KoHo-Bold", 20.0, 0, 140.0, w: 136.38000000000002, h: 104.0),
        ("KoHo-Bold", 20.0, 0, 160.0, w: 159.0, h: 104.0),
        ("KoHo-Bold", 20.0, 0, 180.0, w: 175.94, h: 78.0),
        ("KoHo-Bold", 20.0, 0, 200.0, w: 198.62000000000003, h: 78.0),
        ("KoHo-Bold", 20.0, 1, 60.0, w: 59.760000000000005, h: 182.0),
        ("KoHo-Bold", 20.0, 1, 80.0, w: 79.24000000000001, h: 130.0),
        ("KoHo-Bold", 20.0, 1, 100.0, w: 99.78, h: 104.0),
        ("KoHo-Bold", 20.0, 1, 120.0, w: 118.86000000000001, h: 104.0),
        ("KoHo-Bold", 20.0, 1, 140.0, w: 138.74, h: 78.0),
        ("KoHo-Bold", 20.0, 1, 160.0, w: 154.52000000000004, h: 78.0),
        ("KoHo-Bold", 20.0, 1, 180.0, w: 179.62, h: 78.0),
        ("KoHo-Bold", 20.0, 1, 200.0, w: 190.06, h: 52.0),
        ("KoHo-Bold", 20.0, 2, 60.0, w: 57.239999999999995, h: 130.0),
        ("KoHo-Bold", 20.0, 2, 80.0, w: 76.7, h: 104.0),
        ("KoHo-Bold", 20.0, 2, 100.0, w: 94.0, h: 78.0),
        ("KoHo-Bold", 20.0, 2, 120.0, w: 115.64000000000001, h: 78.0),
        ("KoHo-Bold", 20.0, 2, 140.0, w: 139.38, h: 52.0),
        ("KoHo-Bold", 20.0, 2, 160.0, w: 150.4, h: 52.0),
        ("KoHo-Bold", 20.0, 2, 180.0, w: 178.07999999999998, h: 52.0),
        ("KoHo-Bold", 20.0, 2, 200.0, w: 199.94, h: 52.0),
        ("KoHo-Bold", 20.0, 3, 60.0, w: 57.04, h: 130.0),
        ("KoHo-Bold", 20.0, 3, 80.0, w: 75.74000000000001, h: 104.0),
        ("KoHo-Bold", 20.0, 3, 100.0, w: 97.28, h: 78.0),
        ("KoHo-Bold", 20.0, 3, 120.0, w: 119.46, h: 52.0),
        ("KoHo-Bold", 20.0, 3, 140.0, w: 139.94, h: 52.0),
        ("KoHo-Bold", 20.0, 3, 160.0, w: 159.9, h: 52.0),
        ("KoHo-Bold", 20.0, 3, 180.0, w: 178.88000000000002, h: 52.0),
        ("KoHo-Bold", 20.0, 3, 200.0, w: 195.68, h: 52.0),
        ("Geneva", 11.0, 0, 60.0, w: 58.37841796875, h: 84.0),
        ("Geneva", 11.0, 0, 80.0, w: 79.44384765625, h: 56.0),
        ("Geneva", 11.0, 0, 100.0, w: 98.72607421875, h: 56.0),
        ("Geneva", 11.0, 0, 120.0, w: 118.82470703125, h: 42.0),
        ("Geneva", 11.0, 0, 140.0, w: 139.4443359375, h: 42.0),
        ("Geneva", 11.0, 0, 160.0, w: 159.94580078125, h: 28.0),
        ("Geneva", 11.0, 0, 180.0, w: 176.57470703125, h: 28.0),
        ("Geneva", 11.0, 0, 200.0, w: 193.3271484375, h: 28.0),
        ("Geneva", 11.0, 1, 60.0, w: 58.13134765625, h: 56.0),
        ("Geneva", 11.0, 1, 80.0, w: 77.38134765625, h: 42.0),
        ("Geneva", 11.0, 1, 100.0, w: 97.71630859375, h: 42.0),
        ("Geneva", 11.0, 1, 120.0, w: 117.08984375, h: 28.0),
        ("Geneva", 11.0, 1, 140.0, w: 139.884765625, h: 28.0),
        ("Geneva", 11.0, 1, 160.0, w: 158.8447265625, h: 28.0),
        ("Geneva", 11.0, 1, 180.0, w: 173.6796875, h: 28.0),
        ("Geneva", 11.0, 1, 200.0, w: 198.26318359375, h: 28.0),
        ("Geneva", 11.0, 2, 60.0, w: 59.09814453125, h: 42.0),
        ("Geneva", 11.0, 2, 80.0, w: 78.5146484375, h: 28.0),
        ("Geneva", 11.0, 2, 100.0, w: 97.39404296875, h: 28.0),
        ("Geneva", 11.0, 2, 120.0, w: 117.14892578125, h: 28.0),
        ("Geneva", 11.0, 2, 140.0, w: 137.56982421875, h: 28.0),
        ("Geneva", 11.0, 2, 160.0, w: 147.86083984375, h: 14.0),
        ("Geneva", 11.0, 2, 180.0, w: 147.86083984375, h: 14.0),
        ("Geneva", 11.0, 2, 200.0, w: 147.86083984375, h: 14.0),
        ("Geneva", 11.0, 3, 60.0, w: 57.25048828125, h: 42.0),
        ("Geneva", 11.0, 3, 80.0, w: 77.4833984375, h: 28.0),
        ("Geneva", 11.0, 3, 100.0, w: 96.19091796875, h: 28.0),
        ("Geneva", 11.0, 3, 120.0, w: 119.130859375, h: 28.0),
        ("Geneva", 11.0, 3, 140.0, w: 136.13037109375, h: 28.0),
        ("Geneva", 11.0, 3, 160.0, w: 142.462890625, h: 14.0),
        ("Geneva", 11.0, 3, 180.0, w: 142.462890625, h: 14.0),
        ("Geneva", 11.0, 3, 200.0, w: 142.462890625, h: 14.0),
    ]

    @Test("Bounding rects match UIKit's")
    func rects() {
        _ = Fonts.engine
        var failures: [String] = []
        for (font, size, text, width, w, h) in Self.cases {
            let runs = [TextBlock.Run(Self.texts[text], font: FontKey(name: font, size: size), style: TextBlock.Style(wrapping: .characters))]
            let rect = TextBlock.boundingRect(of: runs, size: CGSize(width: width, height: 10_000), usesLineFragmentOrigin: true, usesFontLeading: false)
            if abs(rect.width - w) > 1e-4 || abs(rect.height - h) > 1e-4 {
                failures.append("\(font) \(size) text \(text) at \(width): \(rect.width)×\(rect.height) against \(w)×\(h)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(Self.cases.count):\n\(failures.joined(separator: "\n"))")
    }
}
#endif
