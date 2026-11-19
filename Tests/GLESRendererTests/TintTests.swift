import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

/// SpriteKit's tint against an iPhone 17 Pro simulator's SKView (and a
/// Mac's, which agrees), as `Tools/TintProbe` reads it back: a sprite's
/// texels times `v_color_mix`, the colour mixed from white by the blend
/// factor and premultiplied by its alpha (the node's, with the colour's own
/// mixed in by the factor). The vertex data comes from the batcher; the
/// shader's arithmetic is redone here as the GLSL does it.
@Suite("Tinting as SpriteKit tints")
struct TintTests {
    /// The probe's texels, premultiplied: red, green, blue, white, grey,
    /// black, half-clear red, half-clear white.
    static let texels: [[UInt8]] = [
        [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255],
        [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128],
    ]

    struct Case: CustomTestStringConvertible {
        var name: String, colour: SKColor, factor: CGFloat, alpha: CGFloat, expected: [[Int]]
        var testDescription: String { "\(name) f=\(factor) alpha=\(alpha)" }
    }

    /// `v_color_mix` as the vertex shader makes it from a vertex's tint
    /// floats (r g b a blend).
    static func colourMix(_ v: ArraySlice<Float>) -> [Float] {
        let i = v.startIndex, a = v[i + 3], blend = v[i + 4]
        return (0 ..< 3).map { (1 + (v[i + $0] - 1) * blend) * a } + [a]
    }

    static let cases: [Case] = [
        Case(name: "gold", colour: SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), factor: 0.0, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "gold", colour: SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), factor: 0.25, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 245, 0, 255], [0, 0, 216, 255], [255, 245, 216, 255], [128, 123, 108, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 123, 108, 128]]),
        Case(name: "gold", colour: SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), factor: 0.5, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 235, 0, 255], [0, 0, 178, 255], [255, 235, 178, 255], [128, 118, 89, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 118, 89, 128]]),
        Case(name: "gold", colour: SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), factor: 0.75, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 226, 0, 255], [0, 0, 140, 255], [255, 226, 140, 255], [128, 113, 70, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 113, 70, 128]]),
        Case(name: "gold", colour: SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), factor: 1.0, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 216, 0, 255], [0, 0, 101, 255], [255, 216, 101, 255], [128, 108, 51, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 108, 51, 128]]),
        Case(name: "slate", colour: SKColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), factor: 0.0, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "slate", colour: SKColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), factor: 0.25, alpha: 1.0, expected: [[204, 0, 0, 255], [0, 216, 0, 255], [0, 0, 229, 255], [204, 216, 229, 255], [102, 108, 115, 255], [0, 0, 0, 255], [102, 0, 0, 128], [102, 108, 115, 128]]),
        Case(name: "slate", colour: SKColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), factor: 0.5, alpha: 1.0, expected: [[153, 0, 0, 255], [0, 178, 0, 255], [0, 0, 204, 255], [153, 178, 204, 255], [77, 89, 102, 255], [0, 0, 0, 255], [77, 0, 0, 128], [77, 89, 102, 128]]),
        Case(name: "slate", colour: SKColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), factor: 0.75, alpha: 1.0, expected: [[101, 0, 0, 255], [0, 140, 0, 255], [0, 0, 178, 255], [101, 140, 178, 255], [51, 70, 89, 255], [0, 0, 0, 255], [51, 0, 0, 128], [51, 70, 89, 128]]),
        Case(name: "slate", colour: SKColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), factor: 1.0, alpha: 1.0, expected: [[50, 0, 0, 255], [0, 101, 0, 255], [0, 0, 153, 255], [50, 101, 153, 255], [25, 51, 77, 255], [0, 0, 0, 255], [25, 0, 0, 128], [25, 51, 77, 128]]),
        Case(name: "blue@0.5", colour: SKColor(red: 0, green: 0, blue: 1, alpha: 0.5), factor: 0.0, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "blue@0.5", colour: SKColor(red: 0, green: 0, blue: 1, alpha: 0.5), factor: 0.25, alpha: 1.0, expected: [[167, 0, 0, 223], [0, 167, 0, 223], [0, 0, 223, 223], [167, 167, 223, 223], [84, 84, 112, 223], [0, 0, 0, 223], [84, 0, 0, 112], [84, 84, 112, 112]]),
        Case(name: "blue@0.5", colour: SKColor(red: 0, green: 0, blue: 1, alpha: 0.5), factor: 0.5, alpha: 1.0, expected: [[95, 0, 0, 191], [0, 95, 0, 191], [0, 0, 191, 191], [95, 95, 191, 191], [48, 48, 96, 191], [0, 0, 0, 191], [48, 0, 0, 96], [48, 48, 96, 96]]),
        Case(name: "blue@0.5", colour: SKColor(red: 0, green: 0, blue: 1, alpha: 0.5), factor: 0.75, alpha: 1.0, expected: [[39, 0, 0, 159], [0, 39, 0, 159], [0, 0, 159, 159], [39, 39, 159, 159], [20, 20, 80, 159], [0, 0, 0, 159], [20, 0, 0, 80], [20, 20, 80, 80]]),
        Case(name: "blue@0.5", colour: SKColor(red: 0, green: 0, blue: 1, alpha: 0.5), factor: 1.0, alpha: 1.0, expected: [[0, 0, 0, 127], [0, 0, 0, 127], [0, 0, 127, 127], [0, 0, 127, 127], [0, 0, 64, 127], [0, 0, 0, 127], [0, 0, 0, 64], [0, 0, 64, 64]]),
        Case(name: "white", colour: SKColor(red: 1, green: 1, blue: 1, alpha: 1), factor: 0.0, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "white", colour: SKColor(red: 1, green: 1, blue: 1, alpha: 1), factor: 0.25, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "white", colour: SKColor(red: 1, green: 1, blue: 1, alpha: 1), factor: 0.5, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "white", colour: SKColor(red: 1, green: 1, blue: 1, alpha: 1), factor: 0.75, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "white", colour: SKColor(red: 1, green: 1, blue: 1, alpha: 1), factor: 1.0, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "black", colour: SKColor(red: 0, green: 0, blue: 0, alpha: 1), factor: 0.0, alpha: 1.0, expected: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255], [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128]]),
        Case(name: "black", colour: SKColor(red: 0, green: 0, blue: 0, alpha: 1), factor: 0.25, alpha: 1.0, expected: [[191, 0, 0, 255], [0, 191, 0, 255], [0, 0, 191, 255], [191, 191, 191, 255], [96, 96, 96, 255], [0, 0, 0, 255], [96, 0, 0, 128], [96, 96, 96, 128]]),
        Case(name: "black", colour: SKColor(red: 0, green: 0, blue: 0, alpha: 1), factor: 0.5, alpha: 1.0, expected: [[127, 0, 0, 255], [0, 127, 0, 255], [0, 0, 127, 255], [127, 127, 127, 255], [64, 64, 64, 255], [0, 0, 0, 255], [64, 0, 0, 128], [64, 64, 64, 128]]),
        Case(name: "black", colour: SKColor(red: 0, green: 0, blue: 0, alpha: 1), factor: 0.75, alpha: 1.0, expected: [[63, 0, 0, 255], [0, 63, 0, 255], [0, 0, 63, 255], [63, 63, 63, 255], [32, 32, 32, 255], [0, 0, 0, 255], [32, 0, 0, 128], [32, 32, 32, 128]]),
        Case(name: "black", colour: SKColor(red: 0, green: 0, blue: 0, alpha: 1), factor: 1.0, alpha: 1.0, expected: [[0, 0, 0, 255], [0, 0, 0, 255], [0, 0, 0, 255], [0, 0, 0, 255], [0, 0, 0, 255], [0, 0, 0, 255], [0, 0, 0, 128], [0, 0, 0, 128]]),
        Case(name: "gold", colour: SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), factor: 0.5, alpha: 0.5, expected: [[127, 0, 0, 127], [0, 117, 0, 127], [0, 0, 89, 127], [127, 117, 89, 127], [64, 59, 45, 127], [0, 0, 0, 127], [64, 0, 0, 64], [64, 59, 45, 64]]),
    ]

    @Test("A textured sprite's texels times its tint", arguments: cases)
    func sprite(_ item: Case) throws {
        let texture = SKTexture(data: Data(Self.texels.flatMap { $0 }), size: CGSize(width: Self.texels.count, height: 1))
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = SKSpriteNode(texture: texture, size: CGSize(width: 80, height: 10))
        node.color = item.colour
        node.colorBlendFactor = item.factor
        node.alpha = item.alpha
        scene.addChild(node)
        guard case let .batches(batches) = try #require(SpriteBatcher().passes(for: DrawList(scene: scene)).first) else {
            Issue.record("expected batches"); return
        }
        let tint = Self.colourMix(try #require(batches.first).vertices[4 ..< 9])
        for (texel, expected) in zip(Self.texels, item.expected) {
            let drawn = (0 ..< 4).map { Float(texel[$0]) * tint[$0] }
            // Within the rounding of two 8-bit stores.
            #expect(zip(drawn, expected).allSatisfy { abs($0 - Float($1)) <= 1.5 }, "\(texel): \(drawn) against \(expected)")
        }
    }

    @Test("An untextured sprite draws its colour whatever its blend factor")
    func untextured() throws {
        for (factor, expected) in [(0.0, [51, 102, 153, 255]), (0.5, [51, 102, 153, 255]), (1.0, [51, 102, 153, 255])] as [(CGFloat, [Int])] {
            let scene = SKScene(size: CGSize(width: 100, height: 100))
            let node = SKSpriteNode(color: SKColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), size: CGSize(width: 80, height: 10))
            node.colorBlendFactor = factor
            scene.addChild(node)
            guard case let .batches(batches) = try #require(SpriteBatcher().passes(for: DrawList(scene: scene)).first) else { return }
            let drawn = Self.colourMix(try #require(batches.first).vertices[4 ..< 9]).map { $0 * 255 }
            #expect(zip(drawn, expected).allSatisfy { abs($0 - Float($1)) <= 1.5 }, "f=\(factor): \(drawn)")
        }
        // A clear colour draws nothing, its alpha counted once.
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        scene.addChild(SKSpriteNode(color: SKColor(red: 1, green: 0, blue: 0, alpha: 0.5), size: CGSize(width: 10, height: 10)))
        guard case let .batches(batches) = try #require(SpriteBatcher().passes(for: DrawList(scene: scene)).first) else { return }
        #expect(Self.colourMix(try #require(batches.first).vertices[4 ..< 9]) == [0.5, 0, 0, 0.5])
    }

    @Test("A label's font colour tinted toward its colour")
    func label() {
        for (font, factor, expected) in [(SKColor(red: 1, green: 0, blue: 0, alpha: 1), 0.0, [255, 0, 0, 255]), (SKColor(red: 1, green: 0, blue: 0, alpha: 1), 0.5, [153, 0, 0, 255]), (SKColor(red: 1, green: 0, blue: 0, alpha: 1), 1.0, [50, 0, 0, 255]), (SKColor(red: 1, green: 1, blue: 1, alpha: 1), 0.0, [255, 255, 255, 255]), (SKColor(red: 1, green: 1, blue: 1, alpha: 1), 0.5, [153, 178, 204, 255]), (SKColor(red: 1, green: 1, blue: 1, alpha: 1), 1.0, [50, 101, 153, 255]), (SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.5), 0.0, [128, 108, 51, 128]), (SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.5), 0.5, [77, 75, 41, 128]), (SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.5), 1.0, [25, 43, 31, 128])] as [(SKColor, CGFloat, [Int])] {
            let label = SKLabelNode(text: "Tint")
            label.fontColor = font
            label.color = SKColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            label.colorBlendFactor = factor
            let colour = label.tinted(font)
            let drawn = [colour.red * colour.alpha, colour.green * colour.alpha, colour.blue * colour.alpha, colour.alpha].map { Float($0 * 255) }
            #expect(zip(drawn, expected).allSatisfy { abs($0 - Float($1)) <= 2 }, "f=\(factor): \(drawn) against \(expected)")
        }
    }
}
