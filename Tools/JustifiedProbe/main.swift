// Lays justified paragraphs out with TextKit 2, which is how UIKit's
// string drawing breaks lines, and prints its lines as the fixture
// `Text/Tests/Fixtures/Justified/textkit2-justified.tsv` holds them:
// face, size, width, sentence (an index into `texts`, which
// `JustifiedBreaksTests` repeats), and the lines joined by "|".
//
// The first three sentences are laid out at every width from 90 to 258
// points by 3 (the sweep the breaker was fitted to); the rest from 93 to
// 300 by 7 (held out while fitting).
import CoreText
import UIKit

let fonts = CommandLine.arguments[1]
for face in ["Montserrat", "KoHo-Bold"] {
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

func lines(_ text: String, face: String, size: CGFloat, width: CGFloat) -> [String] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .justified
    let storage = NSTextContentStorage()
    let layout = NSTextLayoutManager()
    storage.addTextLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: width, height: 100_000))
    container.lineFragmentPadding = 0
    layout.textContainer = container
    storage.attributedString = NSAttributedString(string: text, attributes: [.font: UIFont(name: face, size: size)!, .paragraphStyle: paragraph])
    var lines: [String] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
        for line in fragment.textLineFragments {
            lines.append(line.attributedString.attributedSubstring(from: line.characterRange).string)
        }
        return true
    }
    return lines
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
