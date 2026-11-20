// Crop masks as an SKView draws them on screen, not through
// texture(from:), which crops differently: one row a case, a white
// sprite cropped by a mask whose alpha runs 0 → 1 across x. Read back
// with `Tools/ShapeProbe/crop-masks.sh`, which screenshots the simulator.
import SpriteKit
import UIKit

enum Probe {
    static let width: CGFloat = 200
    static let height: CGFloat = 30
    static let step: CGFloat = 50
    static let left: CGFloat = 20
    static let top: CGFloat = 120

    static let gradient = SKTexture(image: UIGraphicsImageRenderer(size: CGSize(width: 200, height: 4)).image { ctx in
        for i in 0 ..< 200 { UIColor(white: 1, alpha: CGFloat(i) / 199).setFill(); ctx.fill(CGRect(x: CGFloat(i), y: 0, width: 1, height: 4)) }
    })

    static func gradientSprite() -> SKSpriteNode {
        SKSpriteNode(texture: gradient, size: CGSize(width: width, height: height))
    }

    static func gradientShape() -> SKShapeNode {
        let shape = SKShapeNode(rect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        shape.fillColor = .white
        shape.fillTexture = gradient
        shape.strokeColor = .clear
        shape.lineWidth = 0
        return shape
    }

    /// A small shape in a corner, out of the measured line.
    static func cornerShape(hidden: Bool = false) -> SKShapeNode {
        let shape = SKShapeNode(rect: CGRect(x: width / 2 - 6, y: height / 2 - 6, width: 4, height: 4))
        shape.fillColor = .white
        shape.strokeColor = .clear
        shape.isHidden = hidden
        return shape
    }

    static func contents(_ extra: SKNode? = nil) -> [SKNode] {
        [SKSpriteNode(color: .white, size: CGSize(width: width, height: height))] + (extra.map { [$0] } ?? [])
    }

    static func node(_ children: [SKNode]) -> SKNode {
        let node = SKNode()
        children.forEach(node.addChild)
        return node
    }

    /// The cases, top row first.
    static var cases: [(name: String, mask: SKNode, contents: [SKNode])] {
        let label = SKLabelNode(text: ".")
        label.fontSize = 6
        label.position = CGPoint(x: width / 2 - 6, y: height / 2 - 8)
        let solid = SKShapeNode(rect: CGRect(x: -width / 2, y: height / 2 + 2, width: 4, height: 4))
        solid.fillColor = .white
        return [
            ("sprite mask, sprite contents", gradientSprite(), contents()),
            ("sprite mask, contents with a shape", gradientSprite(), contents(cornerShape())),
            ("sprite mask, contents with a label", gradientSprite(), contents(label)),
            ("sprite mask beside a hidden shape", node([gradientSprite(), cornerShape(hidden: true)]), contents()),
            ("sprite mask beside a solid sprite, contents with a shape", node([gradientSprite(), SKSpriteNode(color: .white, size: CGSize(width: 4, height: 4))]), contents(cornerShape())),
            ("textured shape mask", gradientShape(), contents()),
            ("textured shape mask beside a solid shape, contents with a shape", node([gradientShape(), solid]), contents(cornerShape())),
        ]
    }

    static func show(in view: SKView) {
        let scene = SKScene(size: view.bounds.size)
        scene.backgroundColor = .black
        scene.anchorPoint = .zero
        for (index, probe) in cases.enumerated() {
            let crop = SKCropNode()
            crop.maskNode = probe.mask
            probe.contents.forEach(crop.addChild)
            crop.position = CGPoint(x: left + width / 2, y: view.bounds.height - top - CGFloat(index) * step)
            scene.addChild(crop)
        }
        view.presentScene(scene)
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { true }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let controller = UIViewController()
        let view = SKView(frame: window.bounds)
        controller.view = view
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        Probe.show(in: view)
    }
}
