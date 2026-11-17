#if SPRITEKIT_SHIM
import Foundation

/// How a font descriptor's family and weight become one registered face's
/// name (`UIFontDescriptor`; CoreText's descriptors can share it). Kept apart
/// from the Android-only font types so it is host-tested on a Mac
/// (`FontDescriptorTests`, against CoreText's own answers).
enum FontDescriptorResolution {
    /// Where CoreText puts each `UIFont.Weight` (by raw value) on OpenType's
    /// 100–900 scale, measured: heavy and black both land on 800.
    static func openTypeWeight(for weight: CGFloat) -> Int {
        let table: [(CGFloat, Int)] = [
            (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500),
            (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 800),
        ]
        return table.min { abs($0.0 - weight) < abs($1.0 - weight) }?.1 ?? 400
    }

    /// A variable font's named instances, by OpenType weight.
    static let styleNames: [Int: String] = [
        100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium",
        600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black",
    ]

    /// `<family>-<style>` at `weight`, else the nearest weight `isKnown`
    /// accepts (the heavier on a tie), else the family itself.
    static func name(family: String, weight: Int, isKnown: (String) -> Bool) -> String {
        let rounded = min(900, max(100, (weight + 50) / 100 * 100))
        let weights = styleNames.keys.sorted {
            abs($0 - rounded) == abs($1 - rounded) ? $0 > $1 : abs($0 - rounded) < abs($1 - rounded)
        }
        for weight in weights {
            guard let style = styleNames[weight] else { continue }
            let name = "\(family)-\(style)"
            if isKnown(name) { return name }
        }
        return family
    }
}
#endif
