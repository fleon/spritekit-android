import Foundation
import PlatformCore
import SpriteKitShim

extension SKNode {
    private static let hidesFocusKey = "scene_controls.hides_focus"

    /// Keeps focus and the Mac's pointer focus out of this subtree (a page
    /// off screen, a screen held under a sheet, a control that's disabled).
    public var hidesFocus: Bool {
        get { userData?[Self.hidesFocusKey] as? Bool ?? false }
        set {
            if userData == nil { userData = NSMutableDictionary() }
            userData?[Self.hidesFocusKey] = newValue
        }
    }
}

/// The controls a scene offers, as the Apple TV remote, gamepads and the
/// Mac's pointer move between them: only a popup's while one is open
/// (`FocusOverlay`), else the scene's. They come top to bottom, then left
/// to right.
public enum SceneControls {
    /// A control and where it sits in the view. `scrollArea` is the list it
    /// scrolls in, if any, and `isScrolledOut` says it's out of that list's
    /// view (the pointer leaves those out; the remote scrolls to them).
    public struct Control {
        public let node: SKNode
        public let frame: CGRect
        public let scrollArea: (any FocusScrollArea)?
        public let isScrolledOut: Bool

        public init(node: SKNode, frame: CGRect, scrollArea: (any FocusScrollArea)? = nil, isScrolledOut: Bool = false) {
            self.node = node
            self.frame = frame
            self.scrollArea = scrollArea
            self.isScrolledOut = isScrolledOut
        }
    }

    /// Every control on screen in a view of `bounds` showing `scene`.
    public static func collect(in scene: SKScene, bounds: CGRect) -> [Control] {
        let root = topOverlay(in: scene) ?? scene
        var found: [Control] = []
        collect(root, in: scene, screen: bounds, area: nil, into: &found)
        return ordered(found, by: \.frame)
    }

    /// `items` in reading order, by their view frames (y down): a control
    /// joins the row above while its centre is within the row tolerance of
    /// the row's first; rows run left to right.
    public static func ordered<Item>(_ items: [Item], by frame: (Item) -> CGRect) -> [Item] {
        let tolerance = FocusNavigator.configuration.rowTolerance
        var rows: [[Item]] = []
        for item in items.sorted(by: { frame($0).midY < frame($1).midY }) {
            if let first = rows.last?.first, frame(item).midY - frame(first).midY <= tolerance {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.flatMap { $0.sorted { frame($0).midX < frame($1).midX } }
    }

    /// The popup on top, if one is open and not on its way out.
    public static func topOverlay(in scene: SKScene) -> (any FocusOverlay)? {
        scene.children
            .compactMap { $0 as? any FocusOverlay }
            .filter { !$0.isDismissing }
            .max { $0.zPosition < $1.zPosition }
    }

    /// Controls under `node` whose centres are on `screen`, or in a list
    /// (`area`, its node and the part of it on screen) that is.
    private static func collect(
        _ node: SKNode,
        in scene: SKScene,
        screen: CGRect,
        area: (node: any FocusScrollArea, frame: CGRect)?,
        into found: inout [Control]
    ) {
        let minAlpha = FocusNavigator.configuration.minAlpha
        for child in node.children {
            guard !child.isHidden, child.alpha > minAlpha, !child.hidesFocus else { continue }
            if let control = child as? any Focusable {
                guard let frame = viewFrame(of: control.focusFrame, in: child, scene: scene) else { continue }
                let center = pt(frame.midX, frame.midY)
                if let area {
                    guard !area.frame.isEmpty else { continue }
                    found.append(Control(node: child, frame: frame, scrollArea: area.node, isScrolledOut: !area.frame.contains(center)))
                } else if screen.contains(center) {
                    found.append(Control(node: child, frame: frame))
                }
                continue
            }
            var inner = area
            if let scroll = child as? any FocusScrollArea, let frame = viewFrame(of: scroll.focusViewport, in: scroll, scene: scene) {
                inner = (scroll, intersection(area?.frame ?? screen, frame))
            }
            collect(child, in: scene, screen: screen, area: inner, into: &found)
        }
    }

    /// As CoreGraphics intersects rects (the shim's rules on Android, where
    /// Foundation's own `intersection` answers differently at the edges).
    private static func intersection(_ a: CGRect, _ b: CGRect) -> CGRect {
        #if SPRITEKIT_SHIM
        RectSemantics.intersection(a, b)
        #else
        a.intersection(b)
        #endif
    }

    /// `frame` (in `node`'s own space) in the view's coordinates.
    public static func viewFrame(of frame: CGRect, in node: SKNode, scene: SKScene) -> CGRect? {
        guard node.scene === scene else { return nil }
        let a = scene.convertPoint(toView: scene.convert(pt(frame.minX, frame.minY), from: node))
        let b = scene.convertPoint(toView: scene.convert(pt(frame.maxX, frame.maxY), from: node))
        return rect(min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y))
    }
}
