import Foundation
import Testing
@testable import SpriteKitShim

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// What real scenes need from the shim: the language match a game's
// localization makes, the path calls CoreGraphics works out
// itself (fillets and dashes), quaternions, and actions SpriteKit has that
// the scenes call. Each is checked against Apple's own on the Mac where
// Apple's exists.

@Suite("Scenes: picking a language")
struct LanguageMatchTests {
    /// The languages a game might ship, as BCP 47 codes.
    static let shipped = ["en", "de", "es", "es-MX", "fr", "id", "it", "ja", "ko", "nl", "pt-BR", "pt-PT", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

    @Test("Each device language picks the localisation Apple's picks", arguments: [
        "en-US", "en-GB", "de-DE", "fr-CA", "es-ES", "es-MX", "ja-JP", "ko-KR", "pt-BR", "pt-PT",
        "zh-Hans-CN", "zh-Hant-TW", "zh-TW", "zh-CN", "zh-HK", "th-TH", "uk-UA", "id-ID", "nl-NL", "vi-VN",
    ])
    func matchesApple(_ preference: String) {
        let ours = LocalizationMatch.best(of: Self.shipped, for: [preference])
        let apples: [String]? = [preference]
        let theirs = Bundle.preferredLocalizations(from: Self.shipped, forPreferences: apples).first
        #expect(ours == theirs)
    }

    @Test("A language the game does not ship falls through to the next preference")
    func fallsThrough() {
        #expect(LocalizationMatch.best(of: Self.shipped, for: ["sv-SE", "de-DE"]) == "de")
        #expect(LocalizationMatch.best(of: Self.shipped, for: ["sv-SE"]) == nil)
    }
}

@Suite("Scenes: path geometry")
struct PathGeometryTests {
    @Test("The pen ends where the last segment does")
    func currentPoint() {
        #expect(PathGeometry.currentPoint(after: []) == nil)
        #expect(PathGeometry.currentPoint(after: [.move(CGPoint(x: 1, y: 2)), .line(CGPoint(x: 5, y: 6))]) == CGPoint(x: 5, y: 6))
        #expect(PathGeometry.currentPoint(after: [.move(CGPoint(x: 1, y: 2)), .line(CGPoint(x: 5, y: 6)), .close]) == CGPoint(x: 1, y: 2))
    }

    #if canImport(CoreGraphics)
    @Test("A fillet between two tangents lands where CoreGraphics puts it")
    func tangentArc() {
        let cases: [(CGPoint, CGPoint, CGPoint, CGFloat)] = [
            (CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), 3),
            (CGPoint(x: 8, y: 2), CGPoint(x: 0, y: 12), CGPoint(x: -8, y: 2), 1.5),
            (CGPoint(x: -5, y: 1), CGPoint(x: 0, y: 9), CGPoint(x: 6, y: 1), 4),
        ]
        for (start, corner, end, radius) in cases {
            let apple = CGMutablePath()
            apple.move(to: start)
            apple.addArc(tangent1End: corner, tangent2End: end, radius: radius)
            let ours = [PathElement.move(start)] + PathGeometry.tangentArc(from: start, corner: corner, end: end, radius: radius)
            let applePoints = PathRasteriser.flatten(apple, scale: 8).flatMap(\.points)
            let ourPoints = PathRasteriser.flatten(ours, scale: 8).flatMap(\.points)
            // Same end, and every point of ours lies on Apple's curve.
            #expect(distance(applePoints.last, ourPoints.last) < 0.01)
            for point in ourPoints {
                let nearest = zip(applePoints, applePoints.dropFirst()).map { segment(point, $0.0, $0.1) }.min() ?? .infinity
                #expect(nearest < 0.05, "\(point) off CoreGraphics' fillet by \(nearest)")
            }
        }
    }

    @Test("Dashes fall where CoreGraphics cuts them")
    func dashes() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        for phase in [CGFloat(0), 3, 9] {
            let apple = CGPath(rect: rect, transform: nil).copy(dashingWithPhase: phase, lengths: [6, 5])
            let ours = PathGeometry.dash(PathRasteriser.flatten(CGPath(rect: rect, transform: nil), scale: 1), phase: phase, lengths: [6, 5])
            let appleDashes = PathRasteriser.flatten(apple, scale: 1).filter { $0.points.count > 1 }
            let length = { (points: [CGPoint]) in zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
            #expect(ours.count == appleDashes.count, "phase \(phase)")
            #expect(abs(ours.map(length).reduce(0, +) - appleDashes.map { length($0.points) }.reduce(0, +)) < 0.01)
            for (a, b) in zip(ours, appleDashes) {
                #expect(distance(a.first, b.points.first) < 0.01)
            }
        }
    }
    #endif

    /// How far `p` lies from the segment `a`–`b`.
    private func segment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func distance(_ a: CGPoint?, _ b: CGPoint?) -> CGFloat {
        guard let a, let b else { return .infinity }
        return hypot(a.x - b.x, a.y - b.y)
    }
}

#if canImport(simd)
import simd

@Suite("Scenes: quaternions")
struct QuaternionTests {
    @Test("Axis-angle turns, products and normalising match simd")
    func matchesSimd() {
        let a = Quaternion(angle: 0.7, axis: SIMD3(0, 0, 1)) * Quaternion(angle: -0.3, axis: SIMD3(1, 0.5, 0))
        let b = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(0, 0, 1))) * simd_quatf(angle: -0.3, axis: simd_normalize(SIMD3<Float>(1, 0.5, 0)))
        #expect(simd_length(a.vector - b.vector) < 1e-5)
        let v = SIMD3<Float>(0.2, -1, 3)
        #expect(simd_length(a.act(v) - b.act(v)) < 1e-4)
        #expect(simd_length(a.normalized.vector - simd_normalize(b).vector) < 1e-5)
    }
}
#endif

@Suite("Scenes: actions")
struct SceneActionTests {
    /// Read back from SpriteKit's own renderer: a `moveBy` of 1 over a
    /// second, sampled at each tenth, for each timing mode.
    static let measuredCurves: [SKActionTimingMode: [CGFloat]] = [
        .easeIn: [0.0190, 0.0720, 0.1530, 0.2560, 0.3750, 0.5040, 0.6370, 0.7680, 0.8910, 1.0000],
        .easeOut: [0.1090, 0.2320, 0.3630, 0.4960, 0.6250, 0.7440, 0.8470, 0.9280, 0.9810, 1.0000],
        .easeInEaseOut: [0.0280, 0.1040, 0.2160, 0.3520, 0.5000, 0.6480, 0.7840, 0.8960, 0.9720, 1.0000],
    ]

    @Test("Timing modes follow SpriteKit's measured curves", arguments: [SKActionTimingMode.easeIn, .easeOut, .easeInEaseOut])
    func timingCurves(_ mode: SKActionTimingMode) {
        let node = SKNode()
        let action = SKAction.moveBy(x: 1, y: 0, duration: 1)
        action.timingMode = mode
        node.run(action)
        for expected in Self.measuredCurves[mode] ?? [] {
            node.tickActions(0.1)
            #expect(abs(node.position.x - expected) < 0.0006)
        }
    }

    @Test("A repeat carries what a frame runs past a round's end into the next")
    func repeatCarriesOver() {
        // SpriteKit: 7 after 0.7 s, 14 after 1.4 s (not 10).
        let node = SKNode()
        node.run(.repeatForever(.moveBy(x: 10, y: 0, duration: 1)))
        node.tickActions(0.7)
        #expect(abs(node.position.x - 7) < 1e-6)
        node.tickActions(0.7)
        #expect(abs(node.position.x - 14) < 1e-6)
    }

    @Test("Turning the short way round crosses zero rather than going the long way")
    func shortestArc() {
        let node = SKNode()
        node.zRotation = 0.1
        node.run(.rotate(toAngle: 2 * .pi - 0.1, duration: 1, shortestUnitArc: true))
        node.tickActions(0.5)
        #expect(abs(node.zRotation) < 1e-6)
        node.tickActions(0.5)
        #expect(abs(node.zRotation - -0.1) < 1e-6)
    }

    @Test("Colorize moves a sprite's colour and blend factor from where they stand")
    func colorize() {
        let sprite = SKSpriteNode(color: .black, size: CGSize(width: 1, height: 1))
        sprite.colorBlendFactor = 0
        sprite.run(.colorize(with: .white, colorBlendFactor: 1, duration: 1))
        sprite.tickActions(0.5)
        #expect(abs(sprite.color.red - 0.5) < 1e-6)
        #expect(abs(sprite.colorBlendFactor - 0.5) < 1e-6)
    }

    @Test("setTexture swaps a sprite's texture, and resizes it when asked")
    func setTexture() {
        let sprite = SKSpriteNode(texture: nil, size: CGSize(width: 1, height: 1))
        let texture = SKTexture(color: .red, size: CGSize(width: 4, height: 3))
        sprite.run(.setTexture(texture, resize: true))
        sprite.tickActions(0)
        #expect(sprite.texture === texture)
        #expect(sprite.size == CGSize(width: 4, height: 3))
    }

    @Test("An untextured sprite draws its own colour whatever its blend factor")
    func untexturedColour() {
        let scene = SKScene(size: CGSize(width: 10, height: 10))
        let sprite = SKSpriteNode(texture: nil, color: .red, size: CGSize(width: 2, height: 2))
        scene.addChild(sprite)
        let factors = DrawList(scene: scene).commands.compactMap { command -> CGFloat? in
            guard case let .sprite(s) = command, s.color.red == 1 else { return nil }
            return s.colorBlendFactor
        }
        #expect(factors == [1])
    }

    @Test("A clear untextured sprite draws nothing")
    func clearUntextured() {
        let scene = SKScene(size: CGSize(width: 10, height: 10))
        scene.addChild(SKSpriteNode(color: .clear, size: CGSize(width: 2, height: 2)))
        let alphas = DrawList(scene: scene).commands.compactMap { command -> CGFloat? in
            guard case let .sprite(s) = command, s.texture == nil, s.size.width == 2 else { return nil }
            return s.alpha
        }
        #expect(alphas == [0])
    }

    @Test("A crop's contents and mask draw where the crop stands")
    func cropPlacement() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let holder = SKNode()
        holder.position = CGPoint(x: 0, y: -40)
        scene.addChild(holder)
        let crop = SKCropNode()
        crop.position = CGPoint(x: 0, y: 10)
        crop.maskNode = SKSpriteNode(color: .white, size: CGSize(width: 20, height: 20))
        holder.addChild(crop)
        let child = SKSpriteNode(color: .red, size: CGSize(width: 4, height: 4))
        child.position = CGPoint(x: 5, y: 0)
        crop.addChild(child)
        guard let command = DrawList(scene: scene).commands.compactMap({ command -> DrawList.Crop? in
            if case let .crop(crop) = command { return crop } else { return nil }
        }).first, case let .sprite(drawn)? = command.contents.commands.first,
              case let .sprite(mask)? = command.mask.commands.first else {
            Issue.record("no crop drawn")
            return
        }
        #expect(drawn.transform.tx == 5 && drawn.transform.ty == -30)
        #expect(mask.transform.tx == 0 && mask.transform.ty == -30)
    }

    @Test("A subclass can call SpriteKit's designated initialiser")
    func designatedInit() {
        final class Glow: SKSpriteNode {
            init(size: CGSize) { super.init(texture: nil, color: .white, size: size) }
        }
        #expect(Glow(size: CGSize(width: 3, height: 3)).size == CGSize(width: 3, height: 3))
    }
}

@Suite("Scenes: points")
struct PointScaleTests {
    @Test("A point is the display's density-independent pixel, not the art's scale")
    func pointIsADp() {
        // A phone of 1080 × 2400 px at 420 dpi, so 2.625 px a dp.
        let view = SKView(bounds: .zero)
        view.resize(drawable: CGSize(width: 1080, height: 2400), displayScale: 2.625)
        #expect(view.contentScaleFactor == 2.625)
        #expect(abs(view.bounds.width - 411.43) < 0.01)
        #expect(abs(view.bounds.height - 914.29) < 0.01)
    }

    @Test("With no display scale the view keeps the one it had")
    func noScaleKeepsLast() {
        let view = SKView(bounds: .zero)
        view.contentScaleFactor = 2
        view.resize(drawable: CGSize(width: 1000, height: 2000), displayScale: 0)
        #expect(view.bounds.size == CGSize(width: 500, height: 1000))
    }
}

@Suite("Scenes: frames")
struct AccumulatedFrameTests {
    /// SpriteKit on the Mac: a node at (10, 5), scaled 2, holding a 10-point
    /// sprite at (3, 0), then a hidden one at (100, 0), then a transparent
    /// one at (-100, 0).
    @Test("The accumulated frame is in the parent's space, hidden and transparent children in it")
    func matchesSpriteKit() {
        let root = SKNode()
        root.position = CGPoint(x: 10, y: 5)
        root.setScale(2)
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        sprite.position = CGPoint(x: 3, y: 0)
        root.addChild(sprite)
        #expect(root.calculateAccumulatedFrame() == CGRect(x: 6, y: -5, width: 20, height: 20))
        let hidden = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        hidden.position = CGPoint(x: 100, y: 0)
        hidden.isHidden = true
        root.addChild(hidden)
        #expect(root.calculateAccumulatedFrame() == CGRect(x: 6, y: -5, width: 214, height: 20))
        let clear = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        clear.position = CGPoint(x: -100, y: 0)
        clear.alpha = 0
        root.addChild(clear)
        #expect(root.calculateAccumulatedFrame() == CGRect(x: -200, y: -5, width: 420, height: 20))
    }
}

@Suite("Scenes: slicing")
struct ScaledSliceTests {
    @Test("A 9-sliced sprite scaled to a sliver keeps its caps, as SpriteKit's does")
    func capsKeepTheirSize() {
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        let fill = SKSpriteNode(texture: SKTexture(color: .white, size: CGSize(width: 100, height: 20)), size: CGSize(width: 100, height: 20))
        fill.centerRect = CGRect(x: 0.1, y: 0, width: 0.8, height: 1)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.xScale = 0.2
        scene.addChild(fill)
        let widths = DrawList(scene: scene).commands.compactMap { command -> CGFloat? in
            guard case let .sprite(s) = command else { return nil }
            return s.size.width * abs(s.transform.a)
        }
        // Two 10-point caps and nothing between, 20 points in all: a pill,
        // where scaling the whole would have squeezed each cap to 2 points.
        #expect(abs(widths.reduce(0, +) - 20) < 0.001)
        #expect(widths.filter { $0 > 0.001 }.allSatisfy { abs($0 - 10) < 0.001 })
    }

    @Test("A page dot stretched across is a pill: its caps fitted to the dot, not the texture")
    func pageDotPill() {
        // A page dot: an 8-point dot from a 16-point texture, sliced at
        // 0.45…0.55 across, stretched to 24 points by its scale.
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let dot = SKSpriteNode(texture: SKTexture(color: .white, size: CGSize(width: 16, height: 16)), size: CGSize(width: 8, height: 8))
        dot.centerRect = CGRect(x: 0.45, y: 0, width: 0.1, height: 1)
        dot.xScale = 3
        scene.addChild(dot)
        let widths = DrawList(scene: scene).commands.compactMap { command -> CGFloat? in
            guard case let .sprite(s) = command else { return nil }
            return s.size.width * abs(s.transform.a)
        }
        // Caps of 4 (half the dot's height: round ends), 16 between.
        #expect(widths.count == 3)
        #expect(abs(widths[0] - 4) < 0.001 && abs(widths[1] - 16) < 0.001 && abs(widths[2] - 4) < 0.001)
    }
}
