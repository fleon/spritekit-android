import Foundation
import Testing
@testable import SpriteKitShim

// The UIKit view surface a game's SpriteKit code reads: frames, the view
// tree, reserved regions, windows and scenes, and SF Symbols by name.

@Suite("UIKit stand-ins")
@MainActor
struct UIKitStandInTests {
    @Test("A view's frame places its bounds; its size is the bounds' size")
    func frame() {
        let view = UIView(frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(view.frame == CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(view.bounds == CGRect(x: 0, y: 0, width: 100, height: 50))
        view.frame = CGRect(x: 1, y: 2, width: 30, height: 40)
        #expect(view.bounds.size == CGSize(width: 30, height: 40))
        #expect(view.isUserInteractionEnabled)
        #expect(view.contentMode == .scaleToFill)
    }

    @Test("Subviews keep their order and leave their old superview")
    func tree() {
        let a = UIView(frame: .zero), b = UIView(frame: .zero), child = UIView(frame: .zero)
        a.addSubview(child)
        #expect(child.superview === a)
        b.addSubview(child)
        #expect(a.subviews.isEmpty)
        #expect(b.subviews.first === child)
        child.removeFromSuperview()
        #expect(child.superview == nil && b.subviews.isEmpty)
    }

    @Test("SKView(frame:) is as big as the frame, its own space at the origin")
    func skView() {
        let view = SKView(frame: CGRect(x: 5, y: 6, width: 200, height: 100))
        #expect(view.bounds == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(view.frame.origin == CGPoint(x: 5, y: 6))
    }

    @Test("Reserved regions: none by default, inactive ones only when asked")
    func reservedRegions() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(view.reservedRegions(kind: .division).isEmpty)
        view.reservedRegionList = [
            .init(id: .init(1), kind: .division, frame: CGRect(x: 0, y: 390, width: 400, height: 20)),
            .init(id: .init(2), kind: .occlusion, frame: CGRect(x: 0, y: 0, width: 400, height: 30), isActive: false),
        ]
        #expect(view.reservedRegions(kind: .division).map(\.frame) == [CGRect(x: 0, y: 390, width: 400, height: 20)])
        #expect(view.reservedRegions(kind: .occlusion).isEmpty)
        #expect(view.reservedRegions(kind: .occlusion, options: .includeInactive).count == 1)
    }

    @Test("A window joins its scene; the scene's key window is it")
    func windows() {
        let screen = UIScreen(bounds: CGRect(x: 0, y: 0, width: 402, height: 874), nativeScale: 3)
        let scene = UIWindowScene(screen: screen)
        let window = UIWindow(bounds: screen.bounds)
        #expect(scene.keyWindow == nil)
        window.windowScene = scene
        #expect(scene.windows.count == 1)
        #expect(scene.keyWindow === window)
        #expect(window.isKeyWindow)
        window.windowScene = nil
        #expect(scene.windows.isEmpty)
    }

    @Test("An empty image has no size; a symbol nobody packed is nil")
    func images() {
        #expect(UIImage().size == .zero)
        #expect(UIImage(systemName: "nothing.like.this", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)) == nil)
    }
}
