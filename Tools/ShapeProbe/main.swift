// Renders shape nodes in an SKView on a device-scale screen and prints the
// coverage profiles across strokes, fill edges and crop masks, read back
// through texture(from:) at the view's own scale.
import UIKit
import SpriteKit

nonisolated(unsafe) var probeOut = ""
func report(_ line: String) { probeOut += line + "\n" }

final class Probe {
    static func run(in view: SKView) {
        let s = view.contentScaleFactor
        report("PROBE scale \(s)")
        let scene = SKScene(size: CGSize(width: 40, height: 40))
        scene.backgroundColor = .black
        scene.anchorPoint = .zero
        scene.scaleMode = .resizeFill
        view.presentScene(scene)

        func rows(_ node: SKNode) -> [[Double]] {
            scene.removeAllChildren()
            let holder = SKNode()
            holder.addChild(node)
            scene.addChild(holder)
            let backdrop = SKSpriteNode(color: .black, size: CGSize(width: 40, height: 40))
            backdrop.anchorPoint = .zero; backdrop.zPosition = -1
            holder.addChild(backdrop)
            guard let texture = view.texture(from: holder, crop: CGRect(x: 0, y: 0, width: 40, height: 40)) else { return [] }
            let image = texture.cgImage()
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Row 0 at the top as stored.
            return (0 ..< h).map { y in (0 ..< w).map { x in Double(bytes[(y * w + x) * 4]) / 255 } }
        }
        func fmt(_ v: ArraySlice<Double>) -> String { v.map { String(format: "%.2f", $0) }.joined(separator: " ") }

        for nodeScale in [1.0, 2.0] as [CGFloat] {
            for width in [0.25, 0.5, 1, 2, 6] as [CGFloat] {
                for offset in [0.0, 0.5] as [CGFloat] {
                    // The line's centre `offset` pixels past a pixel boundary.
                    let x = 20 + offset / s
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: 0, y: -15 / nodeScale)); path.addLine(to: CGPoint(x: 0, y: 15 / nodeScale))
                    let node = SKShapeNode(path: path)
                    node.strokeColor = .white; node.lineWidth = width; node.setScale(nodeScale)
                    node.position = CGPoint(x: x, y: 20)
                    let r = rows(node)
                    guard !r.isEmpty else { continue }
                    let row = r[r.count / 2]
                    let c = Int(20 * s)
                    report(String(format: "PROBE stroke w=%.2f nodeScale=%.0f off=%.1f ", width, nodeScale, offset) + fmt(row[(c - 8) ... (c + 8)]))
                }
            }
        }
        // A fill's edge and a circle.
        let circle = SKShapeNode(circleOfRadius: 12)
        circle.position = CGPoint(x: 20, y: 20); circle.fillColor = .white; circle.strokeColor = .clear; circle.lineWidth = 0
        let flat = rows(circle).flatMap { $0 }
        report(String(format: "PROBE fill circle r=12: area %.1f px (exact %.1f), partial %d", flat.reduce(0, +), Double.pi * 144 * Double(s * s), flat.filter { $0 > 0.02 && $0 < 0.98 }.count))

        // Crop masks: a white sprite cropped.
        func cropped(_ mask: SKNode) -> [[Double]] {
            let crop = SKCropNode()
            crop.maskNode = mask
            let sprite = SKSpriteNode(color: .white, size: CGSize(width: 40, height: 40))
            sprite.position = CGPoint(x: 20, y: 20)
            crop.addChild(sprite)
            return rows(crop)
        }
        let maskCircle = SKShapeNode(circleOfRadius: 12)
        maskCircle.position = CGPoint(x: 20, y: 20); maskCircle.fillColor = .white; maskCircle.strokeColor = .clear; maskCircle.lineWidth = 0
        let cc = cropped(maskCircle).flatMap { $0 }
        report(String(format: "PROBE crop circle: area %.1f, partial %d", cc.reduce(0, +), cc.filter { $0 > 0.02 && $0 < 0.98 }.count))
        let rounded = SKShapeNode(rect: CGRect(x: 6, y: 10, width: 28, height: 20), cornerRadius: 6)
        rounded.fillColor = .white; rounded.strokeColor = .clear; rounded.lineWidth = 0
        let rr = cropped(rounded).flatMap { $0 }
        report(String(format: "PROBE crop rounded rect: partial %d", rr.filter { $0 > 0.02 && $0 < 0.98 }.count))
        let stroked = SKShapeNode(circleOfRadius: 12)
        stroked.position = CGPoint(x: 20, y: 20); stroked.fillColor = .white
        let sr = cropped(stroked)
        let srow = sr[sr.count / 2]
        let e = Int(32 * s)
        report("PROBE crop stroked circle right edge: " + fmt(srow[(e - 6) ... (e + 6)]))
        // A soft sprite as the mask: a gradient across x.
        let gradient = SKSpriteNode(texture: SKTexture(image: UIGraphicsImageRenderer(size: CGSize(width: 40, height: 4)).image { ctx in
            for i in 0 ..< 40 { UIColor(white: 1, alpha: CGFloat(i) / 39).setFill(); ctx.fill(CGRect(x: CGFloat(i), y: 0, width: 1, height: 4)) }
        }), size: CGSize(width: 40, height: 40))
        gradient.position = CGPoint(x: 20, y: 20)
        let gr = cropped(gradient)
        let grow = gr[gr.count / 2]
        report("PROBE crop gradient sprite, every 10th px: " + stride(from: 0, to: grow.count, by: 10).map { String(format: "%.2f", grow[$0]) }.joined(separator: " "))
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.txt")
        try? probeOut.write(to: url, atomically: true, encoding: .utf8)
        exit(0)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Probe.run(in: view) }
    }
}
