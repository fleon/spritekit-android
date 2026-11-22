import Foundation
import SpriteKitShim
#if canImport(UIKit) && !SPRITEKIT_SHIM
import UIKit
#endif

// Builders that make a path or a label from a list of commands, so a
// node's look reads as one expression.

/// Which way an arc turns, as UIKit names it (y down): `.clockwise` runs
/// from the start angle up to the end angle, which in SpriteKit's y-up
/// space turns anticlockwise on screen.
public nonisolated enum ArcDirection: Sendable {
    case clockwise, counterClockwise
}

/// One step of `path(_:)`. Shapes (`circle`, `ellipse`, `rect`,
/// `roundedRect`, `continuousRoundedRect`) are closed subpaths of their own; the rest continue the
/// current one.
public nonisolated enum PathCommand {
    case moveTo(_ x: CGFloat, _ y: CGFloat)
    case lineTo(_ x: CGFloat, _ y: CGFloat)
    case curveTo(
        _ point: (CGFloat, CGFloat),
        _ control1: (CGFloat, CGFloat),
        _ control2: (CGFloat, CGFloat)
    )
    /// From the current point a line to the arc's start, as CoreGraphics
    /// draws an arc.
    case arc(
        _ center: (CGFloat, CGFloat),
        _ radius: CGFloat,
        _ startAngle: CGFloat,
        _ endAngle: CGFloat,
        _ arcDirection: ArcDirection
    )
    case circle(_ center: (CGFloat, CGFloat), _ radius: CGFloat)
    case ellipse(_ rect: CGRect)
    case rect(_ rect: CGRect)
    /// The radius at most half the rect's shorter side. CoreGraphics'
    /// circular corners.
    case roundedRect(_ rect: CGRect, _ cornerRadius: CGFloat)
    /// UIKit's continuous corners, as `UIBezierPath(roundedRect:cornerRadius:)`
    /// draws them: UIKit's own on Apple, the shim's `ContinuousCorners`
    /// elsewhere, which its `UIBezierPath` draws with too.
    case continuousRoundedRect(_ rect: CGRect, _ cornerRadius: CGFloat)
    case close
}

/// The path `commands` draw, for `ShapeSprite.fill` or `stroke`, a crop
/// mask or an action's route. Safe on any thread.
public nonisolated func path(_ commands: [PathCommand]) -> CGPath {
    let path = CGMutablePath()
    for command in commands {
        switch command {
        case .moveTo(let x, let y):
            path.move(to: pt(x, y))
        case .lineTo(let x, let y):
            path.addLine(to: pt(x, y))
        case .curveTo(let point, let control1, let control2):
            path.addCurve(to: pt(point.0, point.1), control1: pt(control1.0, control1.1), control2: pt(control2.0, control2.1))
        case .arc(let center, let radius, let startAngle, let endAngle, let direction):
            // CoreGraphics' `clockwise` is y-up's: a falling angle.
            path.addArc(
                center: pt(center.0, center.1),
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: direction == .counterClockwise
            )
        case .circle(let center, let radius):
            path.addEllipse(in: rect(center.0 - radius, center.1 - radius, radius * 2, radius * 2))
        case .ellipse(let frame):
            path.addEllipse(in: frame)
        case .rect(let frame):
            path.addRect(frame)
        case .roundedRect(let frame, let cornerRadius):
            // CoreGraphics traps on a radius past half a side.
            let radius = min(cornerRadius, min(abs(frame.width), abs(frame.height)) / 2)
            if radius > 0 {
                path.addRoundedRect(in: frame, cornerWidth: radius, cornerHeight: radius)
            } else {
                path.addRect(frame)
            }
        case .continuousRoundedRect(let frame, let cornerRadius):
            #if canImport(UIKit) && !SPRITEKIT_SHIM
            path.addPath(UIBezierPath(roundedRect: frame, cornerRadius: max(0, cornerRadius)).cgPath)
            #else
            ContinuousCorners.addRoundedRect(to: path, in: frame, cornerRadius: max(0, cornerRadius))
            #endif
        case .close:
            path.closeSubpath()
        }
    }
    return path
}

public nonisolated func path(_ commands: PathCommand...) -> CGPath {
    path(commands)
}

/// One setting of `label(_:)`.
public enum LabelCommand {
    #if canImport(UIKit) || !canImport(Darwin)
    /// `Typography.font`'s face at `weight`, at `size`.
    case font(_ weight: UIFont.Weight, _ size: CGFloat)
    #endif
    /// The face by its name, at `size`.
    case fontNamed(_ name: String, _ size: CGFloat)
    case text(_ text: String)
    case color(_ color: UIColor)
    case hAlign(_ mode: SKLabelHorizontalAlignmentMode)
    /// `.center`, `.top` and `.bottom` align the font's text band
    /// (`band`, else `Typography.textBand`) at `position`, by its metrics,
    /// so every string in one font sits alike: the label is an
    /// `AlignedLabelNode`, whose `position` stays the alignment point
    /// however it's set later. `.baseline` puts the baseline there.
    case vAlign(_ mode: SKLabelVerticalAlignmentMode)
    /// The text band `vAlign` aligns.
    case band(_ band: TextBand)
    case position(_ x: CGFloat, _ y: CGFloat)
    case z(_ z: CGFloat)
    case alpha(_ alpha: CGFloat)
    case name(_ name: String)
    /// Adds the label to `node`.
    case parent(_ node: SKNode)
}

/// A label set up by `commands`, in order; what they leave is
/// `SKLabelNode`'s own default (a baseline, centred). Aligned `.center`,
/// `.top` or `.bottom` (`vAlign`), it is an `AlignedLabelNode`: its
/// `position`, given here or set at any time later, is where the font's
/// band is aligned.
@discardableResult
public func label(_ commands: LabelCommand...) -> SKLabelNode {
    var vertical = SKLabelVerticalAlignmentMode.baseline
    var band: TextBand?
    for command in commands {
        switch command {
        case .vAlign(let mode): vertical = mode
        case .band(let textBand): band = textBand
        default: break
        }
    }
    let label = vertical == .baseline ? SKLabelNode() : AlignedLabelNode(vertical, band: band)
    for command in commands {
        switch command {
        #if canImport(UIKit) || !canImport(Darwin)
        case .font(let weight, let size):
            label.fontName = Typography.font(weight, size).fontName
            label.fontSize = size
        #endif
        case .fontNamed(let name, let size):
            label.fontName = name
            label.fontSize = size
        case .text(let text):
            label.text = text
        case .color(let color):
            label.fontColor = color
        case .hAlign(let mode):
            label.horizontalAlignmentMode = mode
        case .vAlign, .band:
            break
        case .position(let x, let y):
            label.position = pt(x, y)
        case .z(let z):
            label.zPosition = z
        case .alpha(let alpha):
            label.alpha = alpha
        case .name(let name):
            label.name = name
        case .parent(let node):
            node.addChild(label)
        }
    }
    return label
}
