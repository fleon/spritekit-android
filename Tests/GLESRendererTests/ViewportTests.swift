import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim
import RuntimeTestSupport

@Suite("Projection")
struct ProjectionTests {
    /// The emulator's screen, and a scene size a game might give for it.
    /// 1080x2400 px at 3x is 360x800 pt; held in landscape the game runs
    /// 2400x1080 px, 800x360 pt.
    private var phone: Viewport {
        Viewport(drawableSize: CGSize(width: 2400, height: 1080),
                 sceneSize: CGSize(width: 800, height: 360))
    }

    @Test("The scene's corners land on the edges of clip space")
    func corners() {
        let v = phone
        let bottomLeft = v.clipPosition(of: .zero)
        let topRight = v.clipPosition(of: CGPoint(x: 800, y: 360))

        #expect(near(bottomLeft.x, -1, 0.0001))
        #expect(near(bottomLeft.y, -1, 0.0001))
        #expect(near(topRight.x, 1, 0.0001))
        #expect(near(topRight.y, 1, 0.0001))
    }

    @Test("The scene's middle lands at the origin")
    func centre() {
        let p = phone.clipPosition(of: CGPoint(x: 400, y: 180))
        #expect(near(p.x, 0, 0.0001))
        #expect(near(p.y, 0, 0.0001))
    }

    @Test("y is up, as in SpriteKit and GL both — nothing is flipped")
    func yIsUp() {
        let v = phone
        let low = v.clipPosition(of: CGPoint(x: 400, y: 10))
        let high = v.clipPosition(of: CGPoint(x: 400, y: 350))
        #expect(low.y < high.y)
    }

    @Test("Pixels per point is the device scale")
    func scale() {
        // 2400 px over 800 pt is 3x, the density the art is exported at.
        #expect(near(Float(phone.scale.x), 3, 0.0001))
        #expect(near(Float(phone.scale.y), 3, 0.0001))
    }

    @Test("The matrix is column-major with translation in the last column")
    func layout() {
        let m = phone.projection
        #expect(m.count == 16)
        #expect(near(m[0], 2.0 / 800, 0.0001))
        #expect(near(m[5], 2.0 / 360, 0.0001))
        #expect(near(m[12], -1, 0.0001))
        #expect(near(m[13], -1, 0.0001))
        // No shear.
        #expect(m[1] == 0 && m[4] == 0)
    }
}

@Suite("Scale modes")
struct ScaleModeTests {
    /// A drawable wider than the scene's aspect.
    private let wide = CGSize(width: 2000, height: 1000)
    private let scene = CGSize(width: 800, height: 600)

    @Test("Aspect fill covers the drawable and spills the rest")
    func aspectFill() {
        let v = Viewport(drawableSize: wide, sceneSize: scene, scaleMode: .aspectFill)
        // max(2000/800, 1000/600) = 2.5
        #expect(near(Float(v.scale.x), 2.5, 0.0001))
        #expect(near(Float(v.scale.y), 2.5, 0.0001))
        // The visible scene is as wide as the scene but shorter: the top and
        // bottom spill off, which is what aspect fill does.
        #expect(near(Float(v.visibleSceneRect.width), 800, 0.0001))
        #expect(near(Float(v.visibleSceneRect.height), 400, 0.0001))
    }

    @Test("Aspect fit shows the whole scene and letterboxes")
    func aspectFit() {
        let v = Viewport(drawableSize: wide, sceneSize: scene, scaleMode: .aspectFit)
        // min(2000/800, 1000/600) = 1.666...
        #expect(near(Float(v.scale.x), 1000.0 / 600, 0.0001))
        // More scene is visible than the scene itself, so nothing is cropped.
        #expect(v.visibleSceneRect.width > scene.width)
        #expect(near(Float(v.visibleSceneRect.height), 600, 0.0001))
    }

    @Test("Fill stretches the axes independently")
    func fill() {
        let v = Viewport(drawableSize: wide, sceneSize: scene, scaleMode: .fill)
        #expect(near(Float(v.scale.x), 2.5, 0.0001))
        #expect(near(Float(v.scale.y), 1000.0 / 600, 0.0001))
    }

    @Test("Spill is shared evenly either side")
    func spillCentred() {
        let v = Viewport(drawableSize: wide, sceneSize: scene, scaleMode: .aspectFill)
        let rect = v.visibleSceneRect
        // 400pt tall window on a 600pt scene: 100pt lost top and bottom.
        #expect(near(Float(rect.minY), 100, 0.0001))
        #expect(near(Float(rect.maxY), 500, 0.0001))
    }
}

@Suite("Anchor point")
struct AnchorTests {
    @Test("A centred scene puts its origin in the middle of the drawable")
    func centred() {
        let v = Viewport(
            drawableSize: CGSize(width: 800, height: 600),
            sceneSize: CGSize(width: 800, height: 600),
            anchorPoint: CGPoint(x: 0.5, y: 0.5)
        )
        let origin = v.clipPosition(of: .zero)
        #expect(near(origin.x, 0, 0.0001))
        #expect(near(origin.y, 0, 0.0001))
    }

    @Test("The default anchor puts the origin bottom-left")
    func bottomLeft() {
        let v = Viewport(
            drawableSize: CGSize(width: 800, height: 600),
            sceneSize: CGSize(width: 800, height: 600)
        )
        let origin = v.clipPosition(of: .zero)
        #expect(near(origin.x, -1, 0.0001))
        #expect(near(origin.y, -1, 0.0001))
    }
}

@Suite("Degenerate input")
struct DegenerateTests {
    @Test("A zero drawable gives the identity rather than a divide by zero")
    func zeroDrawable() {
        let v = Viewport(drawableSize: .zero, sceneSize: CGSize(width: 800, height: 600))
        #expect(v.projection == Viewport.identity)
    }

    @Test("A zero scene does not crash the scale")
    func zeroScene() {
        let v = Viewport(drawableSize: CGSize(width: 800, height: 600), sceneSize: .zero)
        #expect(v.scale == CGPoint(x: 1, y: 1))
    }
}
