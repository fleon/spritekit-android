import CAndroidShell
import Foundation
import ShellCore
import SpriteKitShim

/// Logs the scene graph, for finding what draws where on a device:
///
///     adb shell setprop debug.switchlings.dump 1    # then 2, 3… for more
///
/// Read once a second; each new value dumps the scene on screen once, a
/// line a node, into `scene-dump.txt` in the app's cache (logcat drops
/// lines that come that fast):
///
///     adb shell run-as com.fleon.switchlings.scenes cat cache/scene-dump.txt
///
/// Debug plumbing only.
enum SceneDump {
    private static var last: String?
    private static var lastCheck: TimeInterval = 0

    static func check(_ view: SKView, at time: TimeInterval) {
        guard time - lastCheck >= 1 else { return }
        lastCheck = time
        let value = DebugProperty.string("debug.switchlings.dump")
        guard let value, value != last else { return }
        let first = last == nil
        last = value
        // Not on the first read: a value left over from another run.
        guard !first || value != "0", let scene = view.scene else { return }
        lines = ["dump \(value): \(type(of: scene)) \(scene.size)", GLESBackend.controller?.debugSummary ?? ""]
        walk(scene, depth: 0)
        let cache = SDL_GetAndroidCachePath().map { String(cString: $0) } ?? NSTemporaryDirectory()
        let path = cache + "/scene-dump.txt"
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        Log.info("dump \(value): \(lines.count) nodes in \(path)")
    }

    private static var lines: [String] = []

    private static func walk(_ node: SKNode, depth: Int) {
        guard depth < 40 else { return }
        var line = String(repeating: " ", count: depth) + "\(type(of: node))"
        if let name = node.name { line += " '\(name)'" }
        line += String(format: " p(%.0f,%.0f) z%.1f", node.position.x, node.position.y, node.zPosition)
        if node.alpha != 1 { line += String(format: " a%.2f", node.alpha) }
        if node.isHidden { line += " HIDDEN" }
        if node.xScale != 1 || node.yScale != 1 { line += String(format: " s(%.2f,%.2f)", node.xScale, node.yScale) }
        if let sprite = node as? SKSpriteNode {
            line += String(format: " size(%.0f,%.0f)", sprite.size.width, sprite.size.height)
            if case let .named(texture)? = sprite.texture?.source { line += " tex=\(texture)" } else if sprite.texture != nil { line += " tex=\(sprite.texture!.source)".prefix(60) }
            if sprite.shader != nil { line += " SHADER" }
            if sprite.texture == nil { line += String(format: " color(%.2f,%.2f,%.2f,%.2f)", sprite.color.red, sprite.color.green, sprite.color.blue, sprite.color.alpha) }
        }
        if let effect = node as? SKEffectNode { line += " EFFECT raster=\(effect.shouldRasterize) shader=\(effect.shader != nil)" }
        if let crop = node as? SKCropNode { line += " CROP mask=\(crop.maskNode.map { "\(type(of: $0))" } ?? "nil")" }
        if let label = node as? SKLabelNode { line += " '\(label.text ?? "")'" }
        lines.append(line)
        for child in node.children { walk(child, depth: depth + 1) }
    }
}
