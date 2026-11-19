// Measures how SpriteKit tints: sprites' `color` and `colorBlendFactor` over
// coloured, grey, white and partly clear texels, tints with alpha, node
// alpha, blend modes over a grey backdrop, shaders (`v_color_mix`,
// `SKDefaultShading()`) and a label's `fontColor` blended toward its
// `color`. Read back through `texture(from:)`, premultiplied, one line a
// case. Built as an iOS app (run.sh, a device-scale SKView) or a Mac tool.
#if os(iOS)
import UIKit
typealias Colour = UIColor
#else
import AppKit
typealias Colour = NSColor
#endif
import SpriteKit

nonisolated(unsafe) var probeOut = ""
func report(_ line: String) { probeOut += line + "\n" }

/// The texels across the probe texture, premultiplied RGBA: red, green,
/// blue, white, grey, black, half-clear red, half-clear white.
let texels: [[UInt8]] = [
    [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255],
    [128, 128, 128, 255], [0, 0, 0, 255], [128, 0, 0, 128], [128, 128, 128, 128],
]

final class Probe {
    static func run(in view: SKView) {
        #if os(iOS)
        let scale = view.contentScaleFactor
        #else
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        #endif
        report("PROBE scale \(scale)")
        let width = CGFloat(texels.count) * 10
        let scene = SKScene(size: CGSize(width: width, height: 10))
        scene.backgroundColor = .clear
        scene.anchorPoint = .zero
        view.presentScene(scene)
        let texture = SKTexture(data: Data(texels.flatMap { $0 }), size: CGSize(width: texels.count, height: 1))
        texture.filteringMode = .nearest

        /// Each texel's cell, its centre pixel as read back (premultiplied).
        func read(_ node: SKNode, backdrop: Colour?) -> [[Int]] {
            scene.removeAllChildren()
            let holder = SKNode()
            if let backdrop {
                let back = SKSpriteNode(color: backdrop, size: CGSize(width: width, height: 10))
                back.anchorPoint = .zero; back.zPosition = -1
                holder.addChild(back)
            }
            holder.addChild(node)
            scene.addChild(holder)
            guard let image = view.texture(from: holder, crop: CGRect(x: 0, y: 0, width: width, height: 10))?.cgImage() else { return [] }
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return (0 ..< texels.count).map { i in
                let x = Int((CGFloat(i) + 0.5) * CGFloat(w) / CGFloat(texels.count)), y = h / 2
                return (0 ..< 4).map { Int(bytes[(y * w + x) * 4 + $0]) }
            }
        }
        func sprite(_ colour: Colour, _ factor: CGFloat) -> SKSpriteNode {
            let node = SKSpriteNode(texture: texture, size: CGSize(width: width, height: 10))
            node.anchorPoint = .zero
            node.color = colour
            node.colorBlendFactor = factor
            return node
        }
        func line(_ name: String, _ cells: [[Int]]) {
            report("PROBE \(name): " + cells.map { "(\($0.map(String.init).joined(separator: " ")))" }.joined(separator: " "))
        }

        let tints: [(String, Colour)] = [
            ("gold", Colour(red: 1, green: 0.85, blue: 0.4, alpha: 1)),
            ("slate", Colour(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)),
            ("blue@0.5", Colour(red: 0, green: 0, blue: 1, alpha: 0.5)),
            ("white", Colour(red: 1, green: 1, blue: 1, alpha: 1)),
            ("black", Colour(red: 0, green: 0, blue: 0, alpha: 1)),
        ]
        line("texture", read(sprite(.white, 0), backdrop: nil))
        for (name, tint) in tints {
            for factor in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
                line("tint \(name) f=\(factor)", read(sprite(tint, factor), backdrop: nil))
            }
        }
        // Node alpha with a tint.
        let faded = sprite(tints[0].1, 0.5); faded.alpha = 0.5
        line("tint gold f=0.5 alpha=0.5", read(faded, backdrop: nil))
        // Blend modes over a grey backdrop.
        for (name, mode) in [("alpha", SKBlendMode.alpha), ("add", .add), ("multiply", .multiply), ("screen", .screen)] {
            for factor in [0, 0.5, 1] as [CGFloat] {
                let node = sprite(tints[0].1, factor); node.blendMode = mode
                line("blend \(name) gold f=\(factor) over grey", read(node, backdrop: Colour(white: 0.5, alpha: 1)))
            }
        }
        // Untextured sprites.
        for factor in [0, 0.5, 1] as [CGFloat] {
            let node = SKSpriteNode(color: tints[1].1, size: CGSize(width: width, height: 10))
            node.anchorPoint = .zero; node.colorBlendFactor = factor
            line("untextured slate f=\(factor)", read(node, backdrop: nil))
        }
        // Shaders: what v_color_mix carries, and SKDefaultShading.
        for (name, source) in [("v_color_mix", "void main() { gl_FragColor = v_color_mix; }"),
                               ("SKDefaultShading", "void main() { gl_FragColor = SKDefaultShading(); }")] {
            for (tintName, tint) in [tints[0], tints[2]] {
                for factor in [0, 0.5, 1] as [CGFloat] {
                    let node = sprite(tint, factor); node.shader = SKShader(source: source)
                    line("shader \(name) \(tintName) f=\(factor)", read(node, backdrop: nil))
                    node.alpha = 0.5
                    line("shader \(name) \(tintName) f=\(factor) alpha=0.5", read(node, backdrop: nil))
                }
            }
        }
        // A label's fontColor blended toward its color: a block glyph's middle.
        for (fontName, fontColour) in [("red", Colour(red: 1, green: 0, blue: 0, alpha: 1)), ("white", Colour.white), ("gold@0.5", Colour(red: 1, green: 0.85, blue: 0.4, alpha: 0.5))] {
            for factor in [0, 0.5, 1] as [CGFloat] {
                let label = SKLabelNode(text: "█████████")
                label.fontName = "Courier"; label.fontSize = 40
                label.fontColor = fontColour; label.color = tints[1].1; label.colorBlendFactor = factor
                label.verticalAlignmentMode = .center; label.horizontalAlignmentMode = .center
                label.position = CGPoint(x: width / 2, y: 5)
                line("label font \(fontName) colour slate f=\(factor)", read(label, backdrop: nil))
            }
        }
        #if os(iOS)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.txt")
        try? probeOut.write(to: url, atomically: true, encoding: .utf8)
        exit(0)
        #else
        print(probeOut, terminator: "")
        #endif
    }
}

#if os(iOS)
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
#else
@main
enum MacProbe {
    @MainActor static func main() {
        Probe.run(in: SKView(frame: CGRect(x: 0, y: 0, width: 80, height: 10)))
    }
}
#endif
