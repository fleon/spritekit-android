import UIKit
import SpriteKit

nonisolated(unsafe) var probeOut = ""
func report(_ line: String) { probeOut += line + "\n" }

final class Probe {
    static func run(in view: SKView) {
        let s = view.contentScaleFactor
        let W: CGFloat = 400, H: CGFloat = 60
        let scene = SKScene(size: CGSize(width: W, height: H))
        scene.backgroundColor = .black; scene.anchorPoint = .zero; scene.scaleMode = .resizeFill
        view.presentScene(scene)
        func rows(_ node: SKNode) -> [[Double]] {
            scene.removeAllChildren()
            let holder = SKNode()
            let back = SKSpriteNode(color: .black, size: CGSize(width: W, height: H)); back.anchorPoint = .zero; back.zPosition = -1
            holder.addChild(back); holder.addChild(node); scene.addChild(holder)
            guard let t = view.texture(from: holder, crop: CGRect(x: 0, y: 0, width: W, height: H)) else { return [] }
            let image = t.cgImage(); let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return (0 ..< h).map { y in (0 ..< w).map { x in Double(bytes[(y * w + x) * 4]) / 255 } }
        }
        let v = CGPoint(x: 15, y: 30)
        report(String(format: "PROBE default miterLimit %.3f", SKShapeNode().miterLimit))
        for turnDeg in [120.0, 150.0, 170.0, 175.0, 178.0, 179.9, 180.0] {
            for limit in [-1.0, 1, 1.5, 2, 4, 10, 100] as [CGFloat] {
                let turn = turnDeg * .pi / 180
                let path = CGMutablePath()
                path.move(to: CGPoint(x: v.x - 10, y: v.y))
                path.addLine(to: v)
                path.addLine(to: CGPoint(x: v.x + 10 * cos(turn), y: v.y + 10 * sin(turn)))
                let node = SKShapeNode(path: path)
                node.strokeColor = .white; node.lineWidth = 6; node.lineJoin = .miter
                if limit > 0 { node.miterLimit = limit }
                let r = rows(node)
                guard !r.isEmpty else { continue }
                // Outer bisector: the miter's spike runs along d0 - d1.
                var bx = 1 - cos(turn), by = -sin(turn)
                let n = hypot(bx, by); bx /= n; by /= n
                var reach = 0.0
                var k = 0.0
                while k < 380 {
                    let p = CGPoint(x: v.x + bx * k, y: v.y + by * k)
                    let px = Int(p.x * s), py = Int((H - p.y) * s)
                    if px >= 0, px < r[0].count, py >= 0, py < r.count, r[py][px] > 0.2 { reach = k }
                    k += 0.25
                }
                let ratio = turnDeg >= 180 ? Double.infinity : 1 / sin((Double.pi - turn) / 2)
                report(String(format: "PROBE turn=%.1f limit=%@ ratio=%.2f tip=%.1fpt reach=%.2fpt", turnDeg, limit > 0 ? String(format: "%.1f", limit) : "default", ratio, 3 * ratio, reach))
            }
        }
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
        let controller = UIViewController(); let view = SKView(frame: window.bounds)
        controller.view = view; window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Probe.run(in: view) }
    }
}
