import Foundation
import SpriteKitShim
import TextShaping

// A tiny command line over the text stack, for two reasons.
//
// First, `swift build` of a library never links, so without an executable
// nothing here proves the Android archives actually resolve — that HarfBuzz
// is C++ and needs libc++, that FreeType's symbols are all present. Building
// this for both ABIs does.
//
// Second, it is the quickest way to see what the shaper did with a string:
//
//   swift run TextProbe ../../Assets/Fonts KoHo-Bold 32 สวัสดี
//
// and, once there is a device, the same binary pushed over adb.

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    print("usage: TextProbe <fonts-directory> <font-name> <size> <text>")
    exit(2)
}

let engine = try TextEngine.install(fontsAt: arguments[1])
let font = FontKey(name: arguments[2], size: CGFloat(Double(arguments[3]) ?? 32))
let text = arguments[4...].joined(separator: " ")

guard let metrics = engine.fontMetrics(font) else {
    print("no such face: \(arguments[2])")
    print("registered: \(engine.library.registeredNames.joined(separator: ", "))")
    exit(1)
}

print("face     \(font.name) at \(font.size)pt")
print("metrics  ascent \(metrics.ascent), descent \(metrics.descent), line \(metrics.lineHeight)")

for run in engine.shape(text, font: font) ?? [] {
    print("run      \(run.script.rawValue), \(run.glyphs.count) glyphs, advance \(run.advance)")
    for glyph in run.glyphs {
        print("  glyph \(glyph.glyph) cluster \(glyph.cluster) advance \(glyph.xAdvance) offset (\(glyph.xOffset), \(glyph.yOffset))")
    }
}

let line = engine.measure(text, font: font)
print("line     advance \(line.advance), ink \(line.inkBounds)")

let placed = engine.placedGlyphs(text, font: font)
print("atlas    \(placed.count) drawn glyphs on \(engine.atlas.pages.count) page(s)")
