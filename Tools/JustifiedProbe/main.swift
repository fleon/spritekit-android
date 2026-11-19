// Lays justified paragraphs out with TextKit 2, which is how UIKit's
// string drawing breaks lines, and prints its lines as the fixture
// `Text/Tests/Fixtures/Justified/textkit2-justified.tsv` holds them:
// face, size, width, sentence (an index into `texts`, which
// `JustifiedBreaksTests` repeats), and the lines joined by "|".
//
// The first three sentences are laid out at every width from 90 to 258
// points by 3 (the sweep the breaker was fitted to); the rest from 93 to
// 300 by 7 (held out while fitting).
//
// With `rtl` after the fonts' folder, right-to-left and mixed paragraphs
// instead, for `textkit2-justified-rtl.tsv`: Arabic in Noto Naskh Arabic
// UI, Hebrew in Montserrat (falling back to the system's Hebrew), and
// Latin with Arabic or Hebrew, runs between "|" in the second face; face,
// second face, size, width, sentence (an index into `rightToLeft`, which
// `JustifiedRightToLeftTests` repeats) and the lines.
import CoreText
import UIKit

let fonts = CommandLine.arguments[1]
for face in ["Montserrat", "KoHo-Bold", "NotoNaskhArabicUI-Bold"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "\(fonts)/\(face).ttf") as CFURL, .process, nil)
}

let texts = [
    "Are you sure you want to quit? You will lose this game.",
    "Unbelievably unbreakable word here and there again",
    "The quick brown fox jumps over the lazy dog twice",
    "Gather all the shells along the shore to fill your basket before the tide returns.",
    "Press and hold a key to see what it does before you use it in a sentence.",
    "Your train has been delayed by twenty minutes. Thank you for your patience today!",
    "Carry the parcel across the bridge and leave it beside the library door.",
    "A little patience goes a long way when the kettle refuses to boil tonight.",
    "Museum tickets reset at midnight so come back tomorrow for more tours.",
]

func lines(_ text: String, face: String, size: CGFloat, width: CGFloat, second: String? = nil) -> [String] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .justified
    let storage = NSTextContentStorage()
    let layout = NSTextLayoutManager()
    storage.addTextLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: width, height: 100_000))
    container.lineFragmentPadding = 0
    layout.textContainer = container
    let string = NSMutableAttributedString()
    for (index, part) in text.split(separator: "|", omittingEmptySubsequences: false).enumerated() where !part.isEmpty {
        let name = index % 2 == 1 ? second ?? face : face
        string.append(NSAttributedString(string: String(part), attributes: [.font: UIFont(name: name, size: size)!, .paragraphStyle: paragraph]))
    }
    storage.attributedString = string
    var lines: [String] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
        for line in fragment.textLineFragments {
            lines.append(line.attributedString.attributedSubstring(from: line.characterRange).string)
        }
        return true
    }
    return lines
}

let rightToLeft = [
    "ذهبنا إلى السوق في الصباح واشترينا الخبز والحليب والفاكهة الطازجة",
    "القطار يغادر المحطة كل ساعة ويصل إلى المدينة بعد الظهر",
    "تقع المكتبة بجانب الحديقة وتفتح أبوابها من التاسعة حتى المساء",
    "كان الطقس جميلا اليوم فجلسنا على الشاطئ نقرأ الكتب",
    "הרכבת יוצאת מהתחנה בכל שעה ומגיעה לעיר אחרי הצהריים",
    "הספרייה נמצאת ליד הגן ופתוחה מתשע בבוקר ועד הערב",
    "הלכנו לשוק בבוקר וקנינו לחם חלב ופירות טריים",
    "מזג האוויר היה נעים היום אז ישבנו על החוף וקראנו ספרים",
    "The museum מוזיאון opens at nine and closes בערב at six",
    "Our train |القطار| leaves at noon from |المحطة| seven",
]

if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "rtl" {
    // Arabic, Hebrew, mixed: each sentence's faces.
    let groups: [(Range<Int>, [(String, String)])] = [
        (0 ..< 4, [("NotoNaskhArabicUI-Bold", "NotoNaskhArabicUI-Bold")]),
        (4 ..< 9, [("Montserrat-Black", "Montserrat-Black"), ("Montserrat-Regular", "Montserrat-Regular")]),
        (9 ..< 10, [("Montserrat-Black", "NotoNaskhArabicUI-Bold")]),
    ]
    var out = ""
    for (texts, faces) in groups {
        for (face, second) in faces {
            for size in [11, 15, 20, 24] as [CGFloat] {
                for index in texts {
                    for width in stride(from: 93, through: 300, by: 7) as StrideThrough<CGFloat> {
                        let found = lines(rightToLeft[index], face: face, size: size, width: width, second: second)
                        out += "\(face)\t\(second)\t\(size)\t\(width)\t\(index)\t\(found.joined(separator: "|"))\n"
                    }
                }
            }
        }
    }
    print(out, terminator: "")
    exit(0)
}

let faces = ["Montserrat-Black", "Montserrat-Regular", "KoHo-Bold", "Geneva"]
let sizes: [CGFloat] = [11, 15, 20, 24, 31.5]
let sets: [(texts: Range<Int>, widths: StrideThrough<CGFloat>)] = [
    (0 ..< 3, stride(from: 90, through: 258, by: 3)),
    (3 ..< texts.count, stride(from: 93, through: 300, by: 7)),
]
var out = ""
for set in sets {
    for face in faces {
        for size in sizes {
            for index in set.texts {
                for width in set.widths {
                    out += "\(face)\t\(size)\t\(width)\t\(index)\t\(lines(texts[index], face: face, size: size, width: width).joined(separator: "|"))\n"
                }
            }
        }
    }
}
print(out, terminator: "")
