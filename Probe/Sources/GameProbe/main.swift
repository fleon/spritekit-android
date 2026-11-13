import Foundation
import SpriteKitShim
import TextShaping
@testable import GameCompat

// Runs the game's own text layout on the device.
//
// `Source/Utils/TextHelpers.swift` compiles here unchanged, which a build
// proves. What a build cannot prove is that it *works*: `wrappedLines` runs
// an NSAttributedString through a CTTypesetter, and on Android both of those
// are stand-ins — corelibs Foundation's attributed string holding a Swift
// class, and the CoreText shim reading it back. This calls the real
// functions, on a device, so that round-trip is checked rather than assumed.
//
//   Probe/run-probe.sh
//
// Exits non-zero on the first thing that is wrong, so it reads as a test.

var failures = 0
func check(_ passed: Bool, _ what: String) {
    print(passed ? "ok   \(what)" : "FAIL \(what)")
    if !passed { failures += 1 }
}

let fonts = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/data/local/tmp/fonts"
_ = try TextEngine.install(fontsAt: fonts)

// MARK: wrappedLines — the real one, out of Source/

let english = "Tap a Switchling to send it one step, and bump another to trade arrows"
let font = appFont(.black, size: 18)
let lines = wrappedLines(english, maxWidth: 180, font: font)

print("lines:", lines)
check(lines.count > 3, "English wraps onto several lines")
check(lines.joined(separator: " ") == english, "nothing is lost in the wrapping")
check(lines.allSatisfy { font.size(of: $0).width <= 180.5 }, "no line is wider than asked")

// Thai, which has no spaces to break at.
let thai = String(repeating: "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}", count: 4)
let thaiFont = UIFont(name: "KoHo-Bold", size: 24)!
let thaiLines = wrappedLines(thai, maxWidth: 80, font: thaiFont)
print("thai:", thaiLines)
check(!thai.contains(" "), "the Thai sample really has no spaces")
check(thaiLines.count > 1, "Thai wraps anyway")
check(thaiLines.joined() == thai, "nothing is lost in the Thai wrapping")

// MARK: capitalsOffset — the NSAttributedString + CTLine round-trip

check(abs(font.capitalsOffset("HELLO")) < 0.6, "capitals need almost no correction")
check(font.capitalsOffset("HELLOg") < -1, "a descender needs a real one, downwards")

// MARK: TextBlockNode — a real SKNode subclass out of Source/

let block = TextBlockNode(
    english,
    maxWidth: 180,
    weight: .black,
    fontSize: 18,
    color: .white
)
print("block:", block.width, "x", block.height, "in", block.children.count, "labels")
check(block.children.count == lines.count, "one label per line")
check(block.width > 0 && block.width <= 180.5, "the block is no wider than asked")
check(block.height > 0, "the block has height")
check(block.children.allSatisfy { ($0 as? SKLabelNode)?.contentFrame.width ?? 0 > 0 },
      "every label measured itself")

print(failures == 0 ? "\nall good" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
