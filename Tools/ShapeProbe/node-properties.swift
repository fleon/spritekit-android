// Measures SKShapeNode's glowWidth, isAntialiased, blendMode and miterLimit
// in an SKView at the device's scale, read back through texture(from:).
import UIKit
import SpriteKit

nonisolated(unsafe) var probeOut = ""
func report(_ line: String) { probeOut += line + "\n" }

final class Probe {
    static func run(in view: SKView) {
        let s = view.contentScaleFactor
        report("PROBE scale \(s)")
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        scene.backgroundColor = .black
        scene.anchorPoint = .zero
        scene.scaleMode = .resizeFill
        view.presentScene(scene)

        /// RGBA rows (premultiplied as read), row 0 at the top.
        func rows(_ node: SKNode, backdrop: UIColor = .black) -> [[(Double, Double, Double)]] {
            scene.removeAllChildren()
            let holder = SKNode()
            let back = SKSpriteNode(color: backdrop, size: CGSize(width: 100, height: 100))
            back.anchorPoint = .zero; back.zPosition = -1
            holder.addChild(back)
            holder.addChild(node)
            scene.addChild(holder)
            guard let texture = view.texture(from: holder, crop: CGRect(x: 0, y: 0, width: 100, height: 100)) else { return [] }
            let image = texture.cgImage()
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return (0 ..< h).map { y in (0 ..< w).map { x in
                let i = (y * w + x) * 4
                return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
            } }
        }
        func line(width: CGFloat, nodeScale: CGFloat = 1, at x: CGFloat = 30, configure: (SKShapeNode) -> Void) -> SKShapeNode {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: -25 / nodeScale)); path.addLine(to: CGPoint(x: 0, y: 25 / nodeScale))
            let node = SKShapeNode(path: path)
            node.strokeColor = .white; node.lineWidth = width; node.setScale(nodeScale)
            node.position = CGPoint(x: x + 0.5 / s, y: 30)
            configure(node)
            return node
        }

        // Glow: a white line, then an orange one, profile outward from its centre pixel.
        for (glow, nodeScale) in [(0.0, 1.0), (1.0, 1.0), (2.0, 1.0), (5.0, 1.0), (10.0, 1.0), (5.0, 2.0)] as [(CGFloat, CGFloat)] {
            let r = rows(line(width: 2, nodeScale: nodeScale) { $0.glowWidth = glow })
            let row = r[r.count / 2], c = Int(30 * s)
            report(String(format: "PROBE glow w=2 glow=%.0f nodeScale=%.0f r: ", glow, nodeScale)
                + row[c ... min(row.count - 1, c + 50)].map { String(format: "%.2f", $0.0) }.joined(separator: " "))
        }
        let orange = UIColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        let ro = rows(line(width: 2) { $0.glowWidth = 5; $0.strokeColor = orange })
        let rowo = ro[ro.count / 2], co = Int(30 * s)
        report("PROBE glow orange w=2 glow=5 rgb every 2px: " + stride(from: co, to: min(rowo.count, co + 30), by: 2).map { String(format: "(%.2f %.2f %.2f)", rowo[$0].0, rowo[$0].1, rowo[$0].2) }.joined(separator: " "))
        // Glow on a closed fill-only shape, and on a stroked circle.
        let filled = SKShapeNode(rectOf: CGSize(width: 20, height: 20)); filled.position = CGPoint(x: 30, y: 30)
        filled.fillColor = .white; filled.strokeColor = .clear; filled.lineWidth = 0; filled.glowWidth = 5
        let rf = rows(filled); let rowf = rf[rf.count / 2]
        report("PROBE glow fill-only rect, right edge out: " + rowf[Int(40 * s) - 2 ... Int(40 * s) + 20].map { String(format: "%.2f", $0.0) }.joined(separator: " "))

        // Aliased strokes.
        for width in [0.5, 1, 1.5, 2, 2.5] as [CGFloat] {
            for off in [0.0, 0.5] as [CGFloat] {
                let node = line(width: width) { $0.isAntialiased = false }
                node.position.x = 30 + off / s
                let r = rows(node); let row = r[r.count / 2], c = Int(30 * s)
                report(String(format: "PROBE aliased w=%.1f off=%.1f: ", width, off) + row[c - 6 ... c + 6].map { String(format: "%.2f", $0.0) }.joined(separator: " "))
            }
        }
        let circle = SKShapeNode(circleOfRadius: 15); circle.position = CGPoint(x: 30, y: 30)
        circle.strokeColor = .white; circle.lineWidth = 2; circle.isAntialiased = false
        let rc = rows(circle).flatMap { $0 }.map { $0.0 }
        report(String(format: "PROBE aliased circle stroke w=2: sum %.1f px (exact %.1f), partial %d", rc.reduce(0, +), 2 * Double.pi * 15 * 2 * Double(s * s), rc.filter { $0 > 0.02 && $0 < 0.98 }.count))
        let aaFill = SKShapeNode(circleOfRadius: 15); aaFill.position = CGPoint(x: 30, y: 30)
        aaFill.fillColor = .white; aaFill.strokeColor = .clear; aaFill.lineWidth = 0; aaFill.isAntialiased = false
        let rcf = rows(aaFill).flatMap { $0 }.map { $0.0 }
        report(String(format: "PROBE aliased circle fill: sum %.1f, partial %d", rcf.reduce(0, +), rcf.filter { $0 > 0.02 && $0 < 0.98 }.count))

        // Blend modes: fill and stroke over a coloured backdrop, against a sprite.
        let backdrop = UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let paint = UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 0.6)
        let modes: [(String, SKBlendMode)] = [("alpha", .alpha), ("add", .add), ("subtract", .subtract), ("multiply", .multiply), ("multiplyX2", .multiplyX2), ("screen", .screen), ("replace", .replace), ("multiplyAlpha", .multiplyAlpha)]
        for (name, mode) in modes {
            let fill = SKShapeNode(rectOf: CGSize(width: 30, height: 30)); fill.position = CGPoint(x: 30, y: 30)
            fill.fillColor = paint; fill.strokeColor = .clear; fill.lineWidth = 0; fill.blendMode = mode
            let rf = rows(fill, backdrop: backdrop); let pf = rf[rf.count / 2][rf[0].count / 2]
            let sprite = SKSpriteNode(color: UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1), size: CGSize(width: 30, height: 30))
            sprite.position = CGPoint(x: 30, y: 30); sprite.alpha = 0.6; sprite.blendMode = mode
            let rs = rows(sprite, backdrop: backdrop); let ps = rs[rs.count / 2][rs[0].count / 2]
            let stroke = line(width: 6) { $0.strokeColor = paint; $0.blendMode = mode }
            let rk = rows(stroke, backdrop: backdrop); let pk = rk[rk.count / 2][Int(30 * s)]
            report(String(format: "PROBE blend %@: fill (%.3f %.3f %.3f) sprite (%.3f %.3f %.3f) stroke (%.3f %.3f %.3f)", name, pf.0, pf.1, pf.2, ps.0, ps.1, ps.2, pk.0, pk.1, pk.2))
        }

        // Miter joins: see miter-joins.swift.

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
