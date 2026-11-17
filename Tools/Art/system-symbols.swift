// Renders SF Symbols into an asset catalog, for games whose code asks for
// them (`UIImage(systemName:withConfiguration:)`). Android has no symbol
// font, so the runtime looks a symbol up in the packed art instead, as
// `SystemSymbols/<name>` (UIImage.swift); this writes those image sets, to be
// packed with the game's own catalog (Tools/Art/xcassets-art.js).
//
// Run on a Mac, where the symbols are, with Xcode's Swift (`xcrun`; a
// swiftly toolchain cannot load AppKit):
//
//   xcrun swift Tools/Art/system-symbols.swift <out.xcassets> <name>:<pointSize>:<weight> ...
//   xcrun swift Tools/Art/system-symbols.swift Symbols.xcassets lock.fill:24:black
//
// Each symbol is drawn black on clear at 3x, at the size AppKit gives the
// symbol image for that configuration (the size UIKit's has too), so a game
// that draws it into a rect and tints it gets the same shape.
import AppKit

let weights: [String: NSFont.Weight] = [
    "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular,
    "medium": .medium, "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
]

let arguments = CommandLine.arguments.dropFirst()
guard let output = arguments.first, arguments.count > 1 else {
    FileHandle.standardError.write("usage: system-symbols.swift <out.xcassets> <name>:<pointSize>:<weight> ...\n".data(using: .utf8)!)
    exit(2)
}

let fileManager = FileManager.default
let catalog = URL(fileURLWithPath: output)
let folder = catalog.appendingPathComponent("SystemSymbols")
try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: url)
}

try writeJSON(["info": ["author": "xcode", "version": 1]], to: catalog.appendingPathComponent("Contents.json"))
try writeJSON(["info": ["author": "xcode", "version": 1], "properties": ["provides-namespace": true]],
              to: folder.appendingPathComponent("Contents.json"))

for spec in arguments.dropFirst() {
    let parts = spec.split(separator: ":").map(String.init)
    guard parts.count == 3, let pointSize = Double(parts[1]), let weight = weights[parts[2]] else {
        FileHandle.standardError.write("bad symbol spec \(spec): want name:pointSize:weight\n".data(using: .utf8)!)
        exit(2)
    }
    let name = parts[0]
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
        FileHandle.standardError.write("no symbol named \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let scale = 3
    let size = symbol.size
    let pixelsWide = Int((size.width * CGFloat(scale)).rounded(.up))
    let pixelsHigh = Int((size.height * CGFloat(scale)).rounded(.up))
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { exit(1) }
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    symbol.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    let set = folder.appendingPathComponent("\(name).imageset")
    try fileManager.createDirectory(at: set, withIntermediateDirectories: true)
    let file = "\(name)@3x.png"
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: set.appendingPathComponent(file))
    try writeJSON([
        "images": [["filename": file, "idiom": "universal", "scale": "3x"]],
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"],
    ], to: set.appendingPathComponent("Contents.json"))
    print("\(name): \(size.width)×\(size.height) pt, \(pixelsWide)×\(pixelsHigh) px")
}
