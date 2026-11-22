import Foundation
import SpriteKitShim

/// Builds a CGPath from SVG path data (every command, arcs included), in the
/// SVG's own coordinates (y down). Icons (`IconDrawing`) are drawn from it.
public nonisolated enum SVGPath {
    public static func path(_ data: String) -> CGPath {
        var parser = Parser(bytes: Array(data.utf8))
        return parser.parse()
    }

    /// Path data for a circle, as Lucide's `<circle>` elements.
    public static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> String {
        "M\(cx - r) \(cy)a\(r) \(r) 0 1 0 \(r * 2) 0a\(r) \(r) 0 1 0 \(-r * 2) 0z"
    }

    /// Path data for a rounded rect, as Lucide's `<rect>` elements.
    public static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rx: CGFloat = 0) -> String {
        guard rx > 0 else { return "M\(x) \(y)h\(w)v\(h)h\(-w)z" }
        return "M\(x + rx) \(y)h\(w - rx * 2)a\(rx) \(rx) 0 0 1 \(rx) \(rx)v\(h - rx * 2)a\(rx) \(rx) 0 0 1 \(-rx) \(rx)"
            + "h\(-(w - rx * 2))a\(rx) \(rx) 0 0 1 \(-rx) \(-rx)v\(-(h - rx * 2))a\(rx) \(rx) 0 0 1 \(rx) \(-rx)z"
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parse() -> CGPath {
            var command: UInt8 = 0
            while true {
                skipSeparators()
                guard index < bytes.count else { break }
                let byte = bytes[index]
                if isCommand(byte) {
                    command = byte
                    index += 1
                } else if command == 0 {
                    break
                }
                guard run(command) else { break }
                // After a move, further pairs are implicit line-tos.
                if command == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
                if command == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
                if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") { command = 0 }
            }
            return path
        }

        private func isCommand(_ byte: UInt8) -> Bool {
            "MmLlHhVvCcSsQqTtAaZz".utf8.contains(byte)
        }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",")
                || bytes[index] == UInt8(ascii: "\n") || bytes[index] == UInt8(ascii: "\t") {
                index += 1
            }
        }

        private mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var sawDot = false
            var sawDigit = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    sawDigit = true
                    index += 1
                } else if byte == UInt8(ascii: "."), !sawDot {
                    sawDot = true
                    index += 1
                } else if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E"), sawDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
                } else {
                    break
                }
            }
            guard sawDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }

        /// Arc flags are single digits and may run together ("011").
        private mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            guard byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else { return nil }
            index += 1
            return byte == UInt8(ascii: "1")
        }

        private mutating func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        private mutating func run(_ command: UInt8) -> Bool {
            let relative = command >= UInt8(ascii: "a")
            let upper = relative ? command - 32 : command
            defer { lastCommand = upper }
            switch upper {
            case UInt8(ascii: "M"):
                guard let p = point(relative: relative) else { return false }
                path.move(to: p)
                current = p
                start = p
                lastControl = nil
            case UInt8(ascii: "L"):
                guard let p = point(relative: relative) else { return false }
                path.addLine(to: p)
                current = p
                lastControl = nil
            case UInt8(ascii: "H"):
                guard let x = number() else { return false }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "V"):
                guard let y = number() else { return false }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "C"):
                guard let c1 = point(relative: relative), let c2 = point(relative: relative), let p = point(relative: relative) else { return false }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case UInt8(ascii: "S"):
                let c1 = reflected(after: [UInt8(ascii: "C"), UInt8(ascii: "S")])
                guard let c2 = point(relative: relative), let p = point(relative: relative) else { return false }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case UInt8(ascii: "Q"):
                guard let c = point(relative: relative), let p = point(relative: relative) else { return false }
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case UInt8(ascii: "T"):
                let c = reflected(after: [UInt8(ascii: "Q"), UInt8(ascii: "T")])
                guard let p = point(relative: relative) else { return false }
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case UInt8(ascii: "A"):
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let large = flag(), let sweep = flag(), let p = point(relative: relative) else { return false }
                addArc(to: p, rx: abs(rx), ry: abs(ry), rotation: rotation, large: large, sweep: sweep)
                current = p
                lastControl = nil
            case UInt8(ascii: "Z"):
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                return false
            }
            return true
        }

        private func reflected(after commands: [UInt8]) -> CGPoint {
            guard commands.contains(lastCommand), let lastControl else { return current }
            return CGPoint(x: current.x * 2 - lastControl.x, y: current.y * 2 - lastControl.y)
        }

        /// SVG's endpoint arc, converted to its centre form and drawn as cubic
        /// curves (one per quarter turn at most).
        private func addArc(to end: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
            guard rx > 0, ry > 0, end != current else {
                path.addLine(to: end)
                return
            }
            var rx = rx
            var ry = ry
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi)
            let sinPhi = sin(phi)
            let dx = (current.x - end.x) / 2
            let dy = (current.y - end.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                rx *= sqrt(lambda)
                ry *= sqrt(lambda)
            }
            let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let coefficient = (large != sweep ? 1 : -1) * sqrt(max(0, numerator / denominator))
            let cxPrime = coefficient * rx * y1 / ry
            let cyPrime = -coefficient * ry * x1 / rx
            let center = CGPoint(
                x: cosPhi * cxPrime - sinPhi * cyPrime + (current.x + end.x) / 2,
                y: sinPhi * cxPrime + cosPhi * cyPrime + (current.y + end.y) / 2
            )
            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            }
            let startAngle = angle(1, 0, (x1 - cxPrime) / rx, (y1 - cyPrime) / ry)
            var delta = angle((x1 - cxPrime) / rx, (y1 - cyPrime) / ry, (-x1 - cxPrime) / rx, (-y1 - cyPrime) / ry)
            if !sweep, delta > 0 { delta -= .pi * 2 }
            if sweep, delta < 0 { delta += .pi * 2 }

            let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
            let step = delta / CGFloat(segments)
            let k = 4 / 3 * tan(step / 4)
            func mapped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: center.x + cosPhi * rx * x - sinPhi * ry * y, y: center.y + sinPhi * rx * x + cosPhi * ry * y)
            }
            var theta = startAngle
            for _ in 0..<segments {
                let next = theta + step
                let c1 = mapped(cos(theta) - k * sin(theta), sin(theta) + k * cos(theta))
                let c2 = mapped(cos(next) + k * sin(next), sin(next) - k * cos(next))
                path.addCurve(to: mapped(cos(next), sin(next)), control1: c1, control2: c2)
                theta = next
            }
        }
    }
}
