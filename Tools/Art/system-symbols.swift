// Renders SF Symbols into an asset catalog, for games whose code asks for
// them (`UIImage(systemName:withConfiguration:)`). Android has no symbol
// font, so the runtime looks a symbol up in the packed art instead, as
// `SystemSymbols/<name>` (UIImage.swift); this writes those image sets, to be
// packed with the game's own catalog (Tools/Art/xcassets-art.js).
//
// It is UIKit's rendering, not AppKit's: AppKit rounds a symbol image's size
// up to whole points (lock.fill 24 black is 26×29 there, 25×29 in UIKit), so
// it runs as a Mac Catalyst tool with a phone's traits at 3x. Build and run it
// through the wrapper:
//
//   Tools/Art/system-symbols.sh <out.xcassets> <name>:<pointSize>:<weight> ...
//   Tools/Art/system-symbols.sh Symbols.xcassets lock.fill:24:black
//
// Each symbol is drawn black on clear at the size UIKit gives the symbol
// image for that configuration on an iPhone, so a game that draws it into a
// rect and tints it gets the same shape.
import UIKit

let weights: [String: UIImage.SymbolWeight] = [
    "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular,
    "medium": .medium, "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
]

let arguments = CommandLine.arguments.dropFirst()
guard let output = arguments.first, arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: system-symbols.sh <out.xcassets> <name>:<pointSize>:<weight> ...\n".utf8))
    exit(2)
}

let scale: CGFloat = 3
let phone = UITraitCollection {
    $0.displayScale = scale
    $0.userInterfaceIdiom = .phone
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
        FileHandle.standardError.write(Data("bad symbol spec \(spec): want name:pointSize:weight\n".utf8))
        exit(2)
    }
    let name = parts[0]
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight).withTraitCollection(phone)
    guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else {
        FileHandle.standardError.write(Data("no symbol named \(name)\n".utf8))
        exit(1)
    }
    let size = symbol.size
    let format = UIGraphicsImageRendererFormat(for: phone)
    format.scale = scale
    format.opaque = false
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
    }
    guard let png = rendered.pngData(), let pixels = rendered.cgImage else { exit(1) }

    let set = folder.appendingPathComponent("\(name).imageset")
    try fileManager.createDirectory(at: set, withIntermediateDirectories: true)
    let file = "\(name)@3x.png"
    try png.write(to: set.appendingPathComponent(file))
    try writeJSON([
        "images": [["filename": file, "idiom": "universal", "scale": "3x"]],
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"],
    ], to: set.appendingPathComponent("Contents.json"))
    print("\(name): \(size.width)×\(size.height) pt, \(pixels.width)×\(pixels.height) px")
}
