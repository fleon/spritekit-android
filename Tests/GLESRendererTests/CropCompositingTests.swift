import XCTest
@testable import GLESRenderer
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// Which crops draw offscreen (`CropCompositing`), and over what.
final class CropCompositingTests: XCTestCase {

    private func shape(fill: SKColor = .white, stroke: SKColor = .clear, lineWidth: CGFloat = 0, alpha: CGFloat = 1) -> DrawList.Shape {
        DrawList.Shape(
            transform: .identity, path: CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil),
            fillColor: fill, strokeColor: stroke, lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter, alpha: alpha
        )
    }

    private func spriteBatch(_ rect: CGRect) -> SpriteBatcher.Pass {
        var batch = SpriteBatcher.Batch(blendMode: .alpha)
        for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.maxY)] {
            batch.vertices += [Float(x), Float(y), 0, 0, 1, 1, 1, 1, 0]
        }
        batch.indices = [0, 1, 0]
        return .batches([batch])
    }

    func testASpriteMaskStaysOnTheStencil() {
        for mode in [CropCompositing.Mode.stencil, .hybrid, .composited] {
            XCTAssertFalse(CropCompositing.composites([spriteBatch(CGRect(x: 0, y: 0, width: 10, height: 10))], mode: mode))
        }
    }

    func testAnOpaqueShapeMaskIsCompositedOnlyWhenEveryShapeMaskIs() {
        let mask: [SpriteBatcher.Pass] = [.shape(shape())]
        XCTAssertFalse(CropCompositing.composites(mask, mode: .stencil))
        XCTAssertFalse(CropCompositing.composites(mask, mode: .hybrid))
        XCTAssertTrue(CropCompositing.composites(mask, mode: .composited))
    }

    func testTranslucentAndStrokedShapeMasksAreCompositedInTheHybrid() {
        XCTAssertTrue(CropCompositing.composites([.shape(shape(fill: SKColor(white: 1, alpha: 0.3)))], mode: .hybrid))
        XCTAssertTrue(CropCompositing.composites([.shape(shape(alpha: 0.5))], mode: .hybrid))
        XCTAssertTrue(CropCompositing.composites([.shape(shape(stroke: .white, lineWidth: 1))], mode: .hybrid))
        XCTAssertFalse(CropCompositing.composites([.shape(shape(fill: .clear, stroke: .white, lineWidth: 0))], mode: .hybrid))
    }

    func testAMaskHoldingACropOrEffectStaysOnTheStencil() {
        let nested: SpriteBatcher.Pass = .crop(transform: .identity, mask: [.shape(shape())], contents: [])
        XCTAssertFalse(CropCompositing.composites([.shape(shape()), nested], mode: .composited))
    }

    func testTheBoundsAreWhereTheMasksVerticesReach() throws {
        let mask = [spriteBatch(CGRect(x: 4, y: -2, width: 10, height: 6)), spriteBatch(CGRect(x: -1, y: 0, width: 2, height: 30))]
        let bounds = try XCTUnwrap(CropCompositing.bounds(of: mask))
        XCTAssertEqual(bounds, CGRect(x: -1, y: -2, width: 15, height: 32))
        XCTAssertNil(CropCompositing.bounds(of: []), "an empty mask reaches nowhere")
        XCTAssertNil(CropCompositing.bounds(of: [.shape(shape())]), "a shape not yet staged can't be measured")
    }

    // MARK: Where a crop sits

    // These run on the draw list and the batcher's passes, which decide how
    // a crop draws; the GL that draws it (the stencil, the composite) is the
    // Android shell's and builds only there.

    @MainActor
    private func list(_ build: (SKScene) -> Void) -> DrawList {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        build(scene)
        return DrawList(scene: scene)
    }

    @MainActor
    private func shapeCrop(at point: CGPoint) -> SKCropNode {
        let crop = SKCropNode()
        let mask = SKShapeNode(circleOfRadius: 12)
        mask.fillColor = .white
        mask.strokeColor = .clear
        crop.maskNode = mask
        crop.addChild(SKSpriteNode(color: .red, size: CGSize(width: 30, height: 30)))
        crop.position = point
        return crop
    }

    /// The crop pass among `passes`, an effect's contents included, with
    /// the effect it sits in, if any.
    private func findCrop(_ passes: [SpriteBatcher.Pass]) -> (mask: [SpriteBatcher.Pass], contents: [SpriteBatcher.Pass], inEffect: Bool)? {
        for pass in passes {
            switch pass {
            case let .crop(_, mask, contents): return (mask, contents, false)
            case let .effect(_, _, _, _, _, _, _, _, _, contents):
                if let found = findCrop(contents) { return (found.mask, found.contents, true) }
            default: continue
            }
        }
        return nil
    }

    private func maskShape(_ mask: [SpriteBatcher.Pass]) -> DrawList.Shape? {
        for case let .shape(shape) in mask { return shape }
        return nil
    }

    /// A gradient sprite as the mask, in a plain node, beside `extra`.
    @MainActor
    private func spriteMaskCrop(beside extra: SKNode?) -> SKCropNode {
        let crop = SKCropNode()
        let mask = SKNode()
        mask.addChild(SKSpriteNode(color: .white, size: CGSize(width: 20, height: 20)))
        if let extra { mask.addChild(extra) }
        crop.maskNode = mask
        crop.addChild(SKSpriteNode(color: .red, size: CGSize(width: 30, height: 30)))
        return crop
    }

    @MainActor
    func testAShapeAnywhereInTheMaskMakesItsSpritesMultiply() throws {
        let hidden = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        hidden.isHidden = true
        let clear = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        clear.alpha = 0
        let hiddenGroup = SKNode()
        hiddenGroup.isHidden = true
        hiddenGroup.addChild(SKShapeNode(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        for (name, extra) in [("hidden", hidden), ("alpha 0", clear), ("under a hidden node", hiddenGroup)] as [(String, SKNode)] {
            let crop = try XCTUnwrap(findCrop(SpriteBatcher().passes(for: list { $0.addChild(spriteMaskCrop(beside: extra)) })), name)
            XCTAssertTrue(CropCompositing.composites(crop.mask, mode: .composited), name)
            XCTAssertTrue(CropCompositing.composites(crop.mask, mode: .hybrid), name)
            XCTAssertNil(maskShape(crop.mask)?.path, "\(name): the shape that stands in draws nothing")
        }
        let shaped = spriteMaskCrop(beside: nil)
        shaped.addChild(SKShapeNode(rect: CGRect(x: 0, y: 0, width: 4, height: 4)))
        let inContents = try XCTUnwrap(findCrop(SpriteBatcher().passes(for: list { $0.addChild(shaped) })))
        XCTAssertTrue(CropCompositing.composites(inContents.mask, mode: .composited), "a shape in the contents")
        let alone = try XCTUnwrap(findCrop(SpriteBatcher().passes(for: list { $0.addChild(spriteMaskCrop(beside: nil)) })))
        XCTAssertFalse(CropCompositing.composites(alone.mask, mode: .composited), "sprites alone clip, all or nothing")
        XCTAssertNil(maskShape(alone.mask))
    }

    @MainActor
    func testAShapeMaskedCropInsideAnEffectNodeIsCompositedAsOneOutsideIs() throws {
        let at = CGPoint(x: 30, y: 40)
        let alone = try XCTUnwrap(findCrop(SpriteBatcher().passes(for: list { $0.addChild(shapeCrop(at: at)) })))
        XCTAssertFalse(alone.inEffect)
        XCTAssertTrue(CropCompositing.composites(alone.mask, mode: .composited))
        let aloneShape = try XCTUnwrap(maskShape(alone.mask))
        XCTAssertEqual(aloneShape.transform.tx, 30, accuracy: 1e-9)
        XCTAssertEqual(aloneShape.transform.ty, 40, accuracy: 1e-9)

        for rasterized in [false, true] {
            let drawn = try XCTUnwrap(findCrop(SpriteBatcher().passes(for: list { scene in
                let effect = SKEffectNode()
                effect.shouldRasterize = rasterized
                effect.position = at
                effect.addChild(shapeCrop(at: .zero))
                scene.addChild(effect)
            })), "rasterized \(rasterized)")
            XCTAssertTrue(CropCompositing.composites(drawn.mask, mode: .composited), "rasterized \(rasterized)")
            XCTAssertEqual(drawn.contents.count, alone.contents.count, "rasterized \(rasterized)")
            let shape = try XCTUnwrap(maskShape(drawn.mask))
            if rasterized {
                // In the effect's own space: the composite and the crop are
                // drawn there, then the effect carries both onto the scene.
                XCTAssertTrue(drawn.inEffect)
                XCTAssertEqual(shape.transform.tx, 0, accuracy: 1e-9)
                XCTAssertEqual(shape.transform.ty, 0, accuracy: 1e-9)
            } else {
                // An effect that passes through draws its children in place:
                // the crop where it would be alone.
                XCTAssertFalse(drawn.inEffect)
                XCTAssertEqual(shape.transform.tx, aloneShape.transform.tx, accuracy: 1e-9)
                XCTAssertEqual(shape.transform.ty, aloneShape.transform.ty, accuracy: 1e-9)
            }
        }
    }

    @MainActor
    func testACropWithNoMaskDrawsItsContentsUnclippedAndAMaskSetAgainClips() throws {
        let crop = shapeCrop(at: CGPoint(x: 20, y: 20))
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        scene.addChild(crop)
        let batcher = SpriteBatcher()
        func passes() -> [SpriteBatcher.Pass] { batcher.passes(for: DrawList(scene: scene)) }

        XCTAssertNotNil(findCrop(passes()), "masked: a crop")
        let mask = crop.maskNode
        crop.maskNode = nil
        let unmasked = passes()
        XCTAssertNil(findCrop(unmasked), "no mask: no crop pass")
        guard case let .batches(batches)? = unmasked.first else { return XCTFail("the contents drawn in place") }
        XCTAssertEqual(batches.reduce(0) { $0 + $1.quadCount }, 1)
        crop.maskNode = mask
        let again = try XCTUnwrap(findCrop(passes()), "the mask set again clips again")
        XCTAssertTrue(CropCompositing.composites(again.mask, mode: .composited))
    }

    @MainActor
    func testTheDrawListCarriesAShapeNodesGlowAliasingAndBlendMode() throws {
        let node = SKShapeNode(circleOfRadius: 5)
        node.glowWidth = 3
        node.isAntialiased = false
        node.blendMode = .screen
        node.miterLimit = 4
        let drawn = list { $0.addChild(node) }
        guard case let .shape(shape)? = drawn.commands.first else { return XCTFail("expected a shape") }
        XCTAssertEqual(shape.glowWidth, 3)
        XCTAssertFalse(shape.isAntialiased)
        XCTAssertEqual(shape.blendMode, .screen)
        XCTAssertEqual(node.miterLimit, 4, "kept on the node, as SpriteKit keeps it")
    }
}
