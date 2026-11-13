import XCTest
@testable import SpriteKitShim

#if canImport(Darwin)
import CoreGraphics
#endif

/// The software `CGContext`'s own tests, run on the host.
///
/// `CGPath` here is the real CoreGraphics one and the paths are built with
/// its own API — the same arrangement as `PathRasteriserTests`, and for the
/// same reason: what the context sees on the Mac is what the game's
/// `UIBezierPath` helpers hand it on a device, read back through
/// `pathElements`.
///
/// Every assertion reads pixels back out of `makeImage()`. The bitmap is
/// RGBA8 **premultiplied** with row 0 at the top, and user space is points
/// with y growing down, which is what `UIGraphicsImageRenderer` hands the
/// game and what these tests hold it to.
final class BitmapContextTests: XCTestCase {

    // MARK: Filling

    func testFillsARectangleWhereItWasAsked() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.setFill(.red)
        context.fill(CGRect(x: 2, y: 4, width: 6, height: 5))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 4, 6).r, 255, "inside")
        XCTAssertEqual(pixel(image, 4, 6).a, 255)
        XCTAssertEqual(pixel(image, 4, 2).a, 0, "above the rectangle's top edge")
        XCTAssertEqual(pixel(image, 4, 10).a, 0, "below its bottom edge")
        XCTAssertEqual(pixel(image, 1, 6).a, 0, "left of it")
        XCTAssertEqual(pixel(image, 9, 6).a, 0, "right of it")
    }

    func testYGrowsDownTheBitmapAsItDoesInUIKit() throws {
        let context = BitmapContext(width: 10, height: 10)
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 2))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 5, 0).a, 255, "y = 0 is the top row")
        XCTAssertEqual(pixel(image, 5, 9).a, 0)
    }

    func testTheContextsScaleTurnsPointsIntoPixels() throws {
        let context = BitmapContext(width: 20, height: 20, scale: 2)
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 9, 9).a, 255, "5 points at 2x is 10 pixels")
        XCTAssertEqual(pixel(image, 10, 10).a, 0)
    }

    func testAlphaIsPremultipliedIntoTheStoredPixels() throws {
        let context = BitmapContext(width: 4, height: 4)
        context.setFill(SKColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))

        let image = try XCTUnwrap(context.makeImage())
        let p = pixel(image, 2, 2)
        assertNear(Int(p.a), 128, accuracy: 1)
        assertNear(Int(p.r), 128, accuracy: 1, "red at half alpha is stored halved")
    }

    func testSetAlphaMultipliesTheFill() throws {
        let context = BitmapContext(width: 4, height: 4)
        context.setAlpha(0.5)
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))

        let image = try XCTUnwrap(context.makeImage())
        assertNear(Int(pixel(image, 2, 2).a), 128, accuracy: 1)
    }

    func testEvenOddLeavesAHoleWhereWindingDoesNot() throws {
        func middle(_ rule: BitmapContext.PathFillRule) -> UInt8 {
            let context = BitmapContext(width: 24, height: 24)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 2, y: 2, width: 20, height: 20))
            path.addRect(CGRect(x: 7, y: 7, width: 10, height: 10))
            context.setFill(.white)
            context.addPath(path)
            context.fillPath(using: rule)
            return pixel(context.makeImage()!, 12, 12).a
        }
        XCTAssertEqual(middle(.winding), 255)
        XCTAssertEqual(middle(.evenOdd), 0)
    }

    func testAnEllipseFillsItsMiddleAndNotItsCorner() throws {
        let context = BitmapContext(width: 40, height: 40)
        context.setFill(.white)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: 40, height: 40))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 20, 20).a, 255)
        XCTAssertEqual(pixel(image, 1, 1).a, 0, "the corner is outside the circle")
    }

    func testEdgesAreAntialiasedRatherThanStepped() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.setFill(.white)
        context.fill(CGRect(x: 5.5, y: 0, width: 9, height: 20))

        let image = try XCTUnwrap(context.makeImage())
        assertNear(Int(pixel(image, 5, 10).a), 128, accuracy: 2, "a half-covered column is half opaque")
        XCTAssertEqual(pixel(image, 6, 10).a, 255)
    }

    // MARK: The graphics state

    func testRestoreGStatePutsBackTheTransformAndTheColour() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.setFill(.white)
        context.saveGState()
        context.translateBy(x: 10, y: 10)
        context.setFill(SKColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.restoreGState()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 2, 2).a, 255, "back at the origin, not translated")
        XCTAssertEqual(pixel(image, 2, 2).g, 255, "white again, not red")
    }

    func testTheTransformMovesAndScalesWhatIsDrawn() throws {
        let context = BitmapContext(width: 40, height: 40)
        context.translateBy(x: 10, y: 20)
        context.scaleBy(x: 2, y: 2)
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 15, 25).a, 255, "5 points scaled by 2 from (10, 20)")
        XCTAssertEqual(pixel(image, 21, 25).a, 0)
        XCTAssertEqual(pixel(image, 15, 19).a, 0)
    }

    func testAPathTakesTheTransformInForceWhenItWasAdded() throws {
        // CoreGraphics maps a point into device space as it is added, not
        // when the path is drawn — `Icon.swift` moves the CTM between two
        // `addPath` calls and depends on it.
        let context = BitmapContext(width: 40, height: 40)
        context.addPath(rectanglePath(CGRect(x: 0, y: 0, width: 4, height: 4)))
        context.translateBy(x: 20, y: 20)
        context.addPath(rectanglePath(CGRect(x: 0, y: 0, width: 4, height: 4)))
        context.setFill(.white)
        context.fillPath()

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 2, 2).a, 255, "the first square stayed at the origin")
        XCTAssertEqual(pixel(image, 22, 22).a, 255, "the second took the translation")
        XCTAssertEqual(pixel(image, 12, 12).a, 0)
    }

    // MARK: Stroking

    func testAStrokeDrawsABandAndLeavesTheMiddleAlone() throws {
        let context = BitmapContext(width: 40, height: 40)
        context.setStroke(.white)
        context.setLineWidth(4)
        context.addPath(rectanglePath(CGRect(x: 10, y: 10, width: 20, height: 20)))
        context.strokePath()

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 20, 10).a, 255, "on the top edge")
        XCTAssertEqual(pixel(image, 20, 20).a, 0, "the middle is not filled")
        XCTAssertEqual(pixel(image, 20, 5).a, 0, "nor outside the band")
    }

    func testStrokeWidthFollowsTheTransform() throws {
        let context = BitmapContext(width: 40, height: 40, scale: 2)
        context.setStroke(.white)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: 0, y: 10))
        context.addLine(to: CGPoint(x: 20, y: 10))
        context.strokePath()

        let image = try XCTUnwrap(context.makeImage())
        // 2 points at 2x is 4 pixels, centred on y = 20.
        XCTAssertEqual(pixel(image, 20, 20).a, 255)
        XCTAssertEqual(pixel(image, 20, 17).a, 0)
        XCTAssertEqual(pixel(image, 20, 23).a, 0)
    }

    // MARK: Clipping

    func testARectangleClipCutsAFill() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.clip(to: CGRect(x: 0, y: 0, width: 10, height: 20))
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 5, 10).a, 255)
        XCTAssertEqual(pixel(image, 15, 10).a, 0)
    }

    func testTwoClipsIntersectRatherThanReplacing() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.clip(to: CGRect(x: 0, y: 0, width: 10, height: 20))
        context.clip(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 5, 5).a, 255, "the corner both clips keep")
        XCTAssertEqual(pixel(image, 15, 5).a, 0)
        XCTAssertEqual(pixel(image, 5, 15).a, 0)
    }

    func testAPathClipIsAntialiasedLikeTheFillWouldHaveBeen() throws {
        // What `drawFace` does: clip to the rounded face, then draw a
        // gradient through it. The clip's edge has to be the fill's edge or
        // every button would step at its corners.
        let solid = BitmapContext(width: 40, height: 40)
        solid.setFill(.white)
        solid.fillEllipse(in: CGRect(x: 2, y: 2, width: 36, height: 36))

        let clipped = BitmapContext(width: 40, height: 40)
        clipped.addEllipse(in: CGRect(x: 2, y: 2, width: 36, height: 36))
        clipped.clip()
        clipped.setFill(.white)
        clipped.fill(CGRect(x: 0, y: 0, width: 40, height: 40))

        let a = try XCTUnwrap(solid.makeImage())
        let b = try XCTUnwrap(clipped.makeImage())
        for y in 0 ..< 40 {
            for x in 0 ..< 40 {
                assertNear(Int(pixel(a, x, y).a), Int(pixel(b, x, y).a), accuracy: 1,
                    "clipped and filled disagree at \(x), \(y)"
                )
            }
        }
    }

    func testReplacePathWithStrokedPathClipsToTheBandAlone() throws {
        // `drawFace`'s lit rim: stroke the face's outline, clip to that
        // stroke, then pour a gradient down it.
        let context = BitmapContext(width: 40, height: 40)
        context.addPath(rectanglePath(CGRect(x: 10, y: 10, width: 20, height: 20)))
        context.setLineWidth(4)
        context.replacePathWithStrokedPath()
        context.clip()
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 20, 10).a, 255, "the band itself")
        XCTAssertEqual(pixel(image, 20, 20).a, 0, "inside the outline")
        XCTAssertEqual(pixel(image, 20, 2).a, 0, "outside it")
    }

    // MARK: Gradients

    func testALinearGradientRunsAlongItsAxis() throws {
        let context = BitmapContext(width: 20, height: 20)
        let gradient = try XCTUnwrap(Gradient(colours: [.black, .white], locations: nil))
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 20),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        let image = try XCTUnwrap(context.makeImage())
        assertNear(Int(pixel(image, 10, 0).r), 6, accuracy: 8, "black at the start")
        assertNear(Int(pixel(image, 10, 10).r), 128, accuracy: 10, "halfway")
        assertNear(Int(pixel(image, 10, 19).r), 249, accuracy: 8, "white at the end")
    }

    func testAGradientStopsAtItsEndsWithoutTheExtendOptions() throws {
        let context = BitmapContext(width: 20, height: 20)
        let gradient = try XCTUnwrap(Gradient(colours: [.white, .white], locations: nil))
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 5, y: 0), end: CGPoint(x: 15, y: 0),
            options: []
        )

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 10, 10).a, 255, "between the two points")
        XCTAssertEqual(pixel(image, 1, 10).a, 0, "before the start, unpainted")
        XCTAssertEqual(pixel(image, 18, 10).a, 0, "after the end, unpainted")
    }

    func testARadialGradientIsItsFirstColourAtTheCentre() throws {
        let context = BitmapContext(width: 40, height: 40)
        let gradient = try XCTUnwrap(Gradient(
            colours: [.white, SKColor(white: 1, alpha: 0)], locations: [0, 1]
        ))
        let centre = CGPoint(x: 20, y: 20)
        context.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: 20,
            options: []
        )

        let image = try XCTUnwrap(context.makeImage())
        // Pixel (20, 20) samples at its centre, (20.5, 20.5) — half a pixel
        // diagonally off the gradient's own centre, which is t ≈ 0.035.
        assertNear(Int(pixel(image, 20, 20).a), 255, accuracy: 10, "solid in the middle")
        assertNear(Int(pixel(image, 30, 20).a), 128, accuracy: 16, "half way out, half faded")
        assertNear(Int(pixel(image, 39, 20).a), 0, accuracy: 8, "clear at the rim")
    }

    func testAGradientIsCutByTheClip() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.clip(to: CGRect(x: 0, y: 0, width: 10, height: 20))
        let gradient = try XCTUnwrap(Gradient(colours: [.white, .white], locations: nil))
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 20),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 5, 10).a, 255)
        XCTAssertEqual(pixel(image, 15, 10).a, 0)
    }

    // MARK: Blend modes

    func testClearErasesThePathAndLeavesEverythingRoundIt() throws {
        // `SheetNode` punches its hole this way. Coverage masks the result
        // rather than the source's alpha; the other reading would empty the
        // whole clip.
        let context = BitmapContext(width: 20, height: 20)
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setBlendMode(.clear)
        context.fill(CGRect(x: 5, y: 5, width: 10, height: 10))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 10, 10).a, 0, "the path is gone")
        XCTAssertEqual(pixel(image, 2, 2).a, 255, "everything round it stayed")
    }

    func testSourceInInsideATransparencyLayerTintsWhatTheLayerDrew() throws {
        // `BoardGroundingArt` draws a soft shape into a layer, then fills the
        // whole canvas with `.sourceIn` to colour it. The fill must take the
        // layer's alpha, not wipe the canvas.
        let context = BitmapContext(width: 20, height: 20)
        context.beginTransparencyLayer()
        context.setFill(.white)
        context.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
        context.setBlendMode(.sourceIn)
        context.setFill(SKColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.endTransparencyLayer()

        let image = try XCTUnwrap(context.makeImage())
        let inside = pixel(image, 10, 10)
        XCTAssertEqual(inside.a, 255, "the shape survived")
        XCTAssertEqual(inside.r, 255)
        XCTAssertEqual(inside.g, 0, "and took the tint")
        XCTAssertEqual(pixel(image, 1, 1).a, 0, "outside the shape nothing was painted")
    }

    func testATransparencyLayerCompositesWithTheAlphaInForceWhenItBegan() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.setAlpha(0.5)
        context.beginTransparencyLayer()
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        context.fill(CGRect(x: 5, y: 0, width: 10, height: 20))
        context.endTransparencyLayer()

        let image = try XCTUnwrap(context.makeImage())
        // The two rectangles overlap. Drawn straight they would reach 75%
        // where they cross; through a layer the pair is flattened first and
        // the whole thing is half opaque.
        assertNear(Int(pixel(image, 2, 10).a), 128, accuracy: 2)
        assertNear(Int(pixel(image, 7, 10).a), 128, accuracy: 2, "the overlap is not darker")
    }

    func testDestinationInKeepsOnlyWhereTheSourceCovers() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setBlendMode(.destinationIn)
        context.setFill(SKColor(white: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))

        let image = try XCTUnwrap(context.makeImage())
        assertNear(Int(pixel(image, 5, 10).a), 128, accuracy: 2, "halved where the source covers")
        XCTAssertEqual(pixel(image, 15, 10).a, 255, "untouched where it does not")
    }

    func testAGradientTakesTheAlphaInForce() throws {
        let context = BitmapContext(width: 10, height: 10)
        context.setAlpha(0.5)
        let gradient = try XCTUnwrap(Gradient(colours: [.white, .white], locations: nil))
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 10),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        assertNear(Int(pixel(try XCTUnwrap(context.makeImage()), 5, 5).a), 128, accuracy: 2)
    }

    func testATransparencyLayerCastsOneShadowForEverythingInIt() throws {
        // Two overlapping squares inside one layer: their shadows must not
        // stack into a darker band where they overlap, because the layer is
        // one shape by the time the shadow is cast.
        let context = BitmapContext(width: 60, height: 60)
        context.setShadow(offset: CGSize(width: 0, height: 20), blur: 0, colour: SKColor(white: 0, alpha: 0.5))
        context.beginTransparencyLayer()
        context.setFill(.white)
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 10))
        context.fill(CGRect(x: 20, y: 10, width: 20, height: 10))
        context.endTransparencyLayer()

        let image = try XCTUnwrap(context.makeImage())
        assertNear(Int(pixel(image, 15, 35).a), 128, accuracy: 2, "under one square")
        assertNear(Int(pixel(image, 25, 35).a), 128, accuracy: 2, "under the overlap, no darker")
        XCTAssertEqual(pixel(image, 25, 15).g, 255, "the layer itself is still white on top")
    }

    // MARK: Shadows

    func testAShadowFallsWhereItIsOffsetAndTheShapeStaysOnTop() throws {
        let context = BitmapContext(width: 60, height: 60)
        context.setShadow(offset: CGSize(width: 0, height: 8), blur: 6, colour: SKColor(white: 0, alpha: 1))
        context.setFill(.white)
        context.fill(CGRect(x: 20, y: 10, width: 20, height: 20))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 30, 20).g, 255, "the shape itself is still white")
        XCTAssertGreaterThan(pixel(image, 30, 36).a, 40, "a shadow below it")
        XCTAssertLessThan(pixel(image, 30, 36).g, 80, "and it is dark")
        XCTAssertEqual(pixel(image, 30, 2).a, 0, "nothing above the shape")
    }

    func testAShadowSoftensWithItsBlur() throws {
        func edgeAlpha(blur: CGFloat) -> Int {
            let context = BitmapContext(width: 60, height: 60)
            context.setShadow(offset: .zero, blur: blur, colour: SKColor(white: 0, alpha: 1))
            context.setFill(.white)
            context.fill(CGRect(x: 20, y: 20, width: 20, height: 20))
            return Int(pixel(context.makeImage()!, 30, 44).a)
        }
        XCTAssertEqual(edgeAlpha(blur: 0), 0, "a sharp shadow reaches nothing past the shape")
        XCTAssertGreaterThan(edgeAlpha(blur: 12), 20, "a soft one spreads past it")
    }

    func testAShadowIsNotCastByTheShadowItself() throws {
        // Two fills with a shadow set must not compound into a double-dark
        // band where their shadows overlap the other's shape.
        let context = BitmapContext(width: 40, height: 40)
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 0, colour: SKColor(white: 0, alpha: 1))
        context.setFill(.white)
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 10))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 20, 15).g, 255, "the shape is not darkened by its own shadow")
        XCTAssertEqual(pixel(image, 20, 22).g, 0, "the shadow shows below it")
    }

    // MARK: Images

    func testAnImageDrawsIntoTheRectItIsGiven() throws {
        let source = BitmapContext(width: 4, height: 4)
        source.setFill(SKColor(red: 0, green: 1, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let drawn = try XCTUnwrap(source.makeImage())

        let context = BitmapContext(width: 20, height: 20)
        context.interpolationQuality = .none
        context.draw(drawn, in: CGRect(x: 4, y: 4, width: 8, height: 8))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 8, 8).g, 255, "inside the rect")
        XCTAssertEqual(pixel(image, 2, 2).a, 0, "outside it")
        XCTAssertEqual(pixel(image, 15, 15).a, 0)
    }

    // MARK: The UIKit layer over it

    func testTheRendererMakesAnImageOfTheRightPixelSizeAndPointSize() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 20), format: format)
            .image { context in
                context.cgContext.setFill(.white)
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
            }

        XCTAssertEqual(image.cgImage?.width, 30)
        XCTAssertEqual(image.cgImage?.height, 60)
        XCTAssertEqual(image.size.width, 10, "the size stays in points")
        XCTAssertEqual(image.size.height, 20)
        XCTAssertEqual(image.scale, 3)
    }

    func testARendererMadeFromBoundsDrawsFromThatOrigin() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            bounds: CGRect(x: 100, y: 100, width: 10, height: 10), format: format
        ).image { context in
            context.cgContext.setFill(.white)
            context.cgContext.fill(CGRect(x: 100, y: 100, width: 4, height: 4))
        }

        let drawn = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixel(drawn, 1, 1).a, 255, "the bounds' own origin is the image's corner")
        XCTAssertEqual(pixel(drawn, 8, 8).a, 0)
    }

    func testATextureFromAnImageReportsItsPointsAndCarriesItsPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format)
            .image { context in
                context.cgContext.setFill(.white)
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
            }

        let texture = SKTexture(image: image)
        XCTAssertEqual(texture.size(), CGSize(width: 8, height: 6), "points, not pixels")
        let pixels = try XCTUnwrap(texture.ownPixels)
        XCTAssertEqual(pixels.width, 16)
        XCTAssertEqual(pixels.height, 12)
        XCTAssertEqual(pixels.pixels.count, 16 * 12 * 4)
    }

    func testAnOpaqueContextStartsBlackRatherThanClear() throws {
        let context = BitmapContext(width: 4, height: 4, opaque: true)
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 2, 2).a, 255)
        XCTAssertEqual(pixel(image, 2, 2).r, 0)
    }

    func testClearEmptiesARectWhateverTheBlendModeIs() throws {
        let context = BitmapContext(width: 20, height: 20)
        context.setFill(.white)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setBlendMode(.multiply)
        context.clear(CGRect(x: 5, y: 5, width: 10, height: 10))

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(pixel(image, 10, 10).a, 0)
        XCTAssertEqual(pixel(image, 2, 2).a, 255)
    }

    // MARK: Reading pixels back

    private func pixel(_ image: RasterImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * image.width + x) * 4
        guard i + 3 < image.pixels.count else { return (0, 0, 0, 0) }
        return (image.pixels[i], image.pixels[i + 1], image.pixels[i + 2], image.pixels[i + 3])
    }

    private func rectanglePath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect)
        return path
    }

    private func assertNear(
        _ a: Int, _ b: Int, accuracy: Int, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(message) (\(a) vs \(b))", file: file, line: line)
    }
}
