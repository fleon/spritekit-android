// Measures where SpriteKit draws the baseline of a `.baseline` label put at
// `position`: capitals over the baseline ("HHH") and with descenders below
// it ("Hpqg"), at several font sizes, label scales, parent scales and
// fractional positions, read back through `texture(from:)` against two
// calibration bars. One line a case: the capitals' top less the font's cap
// height (where the baseline is drawn), and for "HHH" the ink's bottom,
// both above `position` in the label's own points. Built as an iOS app
// (run.sh, a device-scale SKView) or a Mac tool. On iOS both read +1.000 in
// every case: `SKLabelNode.baselinePadding`. A Mac's AppKit text smoothing
// spreads the ink's bottom edge by a few tenths, so read the top there.
#if os(iOS)
import UIKit
typealias Colour = UIColor
#else
import AppKit
typealias Colour = NSColor
#endif
import CoreText
import SpriteKit

nonisolated(unsafe) var probeOut = ""
func report(_ line: String) { probeOut += line + "\n" }

final class Probe {
    static func run(in view: SKView) {
        let side: CGFloat = 400
        let scene = SKScene(size: CGSize(width: side, height: side))
        scene.backgroundColor = .clear
        scene.anchorPoint = .zero
        scene.scaleMode = .fill
        view.presentScene(scene)

        /// The scene read back: alpha by row (row 0 the top), and pixels per point.
        func render() -> (alpha: [[UInt8]], width: Int, height: Int)? {
            guard let image = view.texture(from: scene)?.cgImage() else { return nil }
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let rows = (0 ..< h).map { r in (0 ..< w).map { bytes[(r * w + $0) * 4 + 3] } }
            return (rows, w, h)
        }

        /// The lowest and highest ink edges (pixels from the bottom) in
        /// columns `x0..<x1`: from the first fully covered row in, less the
        /// cover of the rows beyond it, which places a step edge exactly
        /// however the texture's filtering softens it.
        func edges(_ alpha: [[UInt8]], height: Int, x0: Int, x1: Int) -> (bottom: CGFloat, top: CGFloat)? {
            let cover = alpha.map { row in CGFloat(row[x0 ..< x1].max() ?? 0) / 255 }
            guard let full = cover.max(), full > 0.5,
                  let low = cover.lastIndex(where: { $0 >= full - 0.01 }),
                  let high = cover.firstIndex(where: { $0 >= full - 0.01 }) else { return nil }
            let below = cover[(low + 1)...].reduce(0, +) / full
            let above = cover[..<high].reduce(0, +) / full
            return (CGFloat(height - 1 - low) - below, CGFloat(height - high) + above)
        }

        // Two bars, 2 pt tall, at y 10 and 300, calibrate points to pixels.
        for y in [10, 300] as [CGFloat] {
            let bar = SKSpriteNode(color: .white, size: CGSize(width: 4, height: 2))
            bar.anchorPoint = .zero
            bar.position = CGPoint(x: 0, y: y)
            scene.addChild(bar)
        }
        guard let calibration = render(), let low = edges(calibration.alpha, height: calibration.height, x0: 0, x1: 2) else { return }
        // The low bar's bottom is y 10, the high bar's top y 302.
        let pxPerPt = (low.top - low.bottom) / 292
        let originPx = low.bottom - 10 * pxPerPt
        report("PROBE pixels/pt \(pxPerPt) origin \(originPx) bars bottom \(low.bottom) top \(low.top)")

        let font = "Helvetica-Bold"
        for text in ["HHH", "Hpqg"] {
        for size in [9, 12, 17, 20, 23.5, 32, 48] as [CGFloat] {
            for parentScale in [1, 1.5, 3] as [CGFloat] {
                for labelScale in [1, 2] as [CGFloat] {
                    for y in [0, 0.3] as [CGFloat] {
                        guard size * parentScale * labelScale <= 100 else { continue }
                        let holder = SKNode()
                        holder.position = CGPoint(x: 20, y: 60)
                        holder.setScale(parentScale)
                        let label = SKLabelNode(fontNamed: font)
                        label.fontSize = size
                        label.fontColor = .white
                        label.text = text
                        label.verticalAlignmentMode = .baseline
                        label.horizontalAlignmentMode = .left
                        label.position = CGPoint(x: 0, y: y)
                        label.setScale(labelScale)
                        holder.addChild(label)
                        scene.addChild(holder)
                        defer { holder.removeFromParent() }
                        guard let shot = render(),
                              let ink = edges(shot.alpha, height: shot.height, x0: Int(10 * pxPerPt), x1: shot.width) else {
                            report("PROBE size \(size): no ink"); continue
                        }
                        let toLabel = parentScale * labelScale
                        let positionPt = 60 + parentScale * y
                        let bottom = ((ink.bottom - originPx) / pxPerPt - positionPt) / toLabel
                        let top = ((ink.top - originPx) / pxPerPt - positionPt) / toLabel
                        let cap = CTFontGetCapHeight(CTFontCreateWithName(font as CFString, size, nil))
                        // The capitals' top less the cap height is where the
                        // baseline is drawn; for "HHH" the ink's bottom is too.
                        let bottomText = text == "HHH" ? String(format: "  ink bottom %+.3f", bottom) : ""
                        report(String(format: "PROBE %@ size %5.1f parent %.1f label %.0f y %.1f: cap top - cap height %+.3f",
                                      text, size, parentScale, labelScale, y, top - cap) + bottomText)
                    }
                }
            }
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
        Probe.run(in: SKView(frame: CGRect(x: 0, y: 0, width: 400, height: 400)))
    }
}
#endif
