#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

// The CoreGraphics names, over the drawing that `BitmapContext.swift` does.
//
// Same split as `Typesetting.swift` and `CoreTextCompat.swift`: the work is
// in a type that compiles on the Mac too, so it can be developed and tested
// with a normal edit–test loop, and this file — Android only — puts the
// names the game actually writes on top of it. Those names cannot be
// declared on the Mac, where CoreGraphics already owns every one of them.
//
// `CGColor` is a plain alias for `UIColor` rather than a type of its own.
// Game code rarely builds a `CGColor` or reads its components; the usual
// use is a `.cgColor` handed straight to the context. One type means no
// overload pairs, and in particular it means
// `setShadow(offset:blur:color: nil)` still has exactly one meaning.

public typealias CGContext = BitmapContext
public typealias CGImage = RasterImage
public typealias CGGradient = Gradient
public typealias CGColor = SKColor
public typealias CGBlendMode = BitmapContext.BlendMode
public typealias CGPathFillRule = BitmapContext.PathFillRule
public typealias CGPathDrawingMode = BitmapContext.DrawMode
public typealias CGGradientDrawingOptions = BitmapContext.GradientOptions
public typealias CGInterpolationQuality = BitmapContext.InterpolationQuality

/// Any CoreFoundation array the games build or receive: gradients' colours
/// (`colors.map(\.cgColor) as CFArray`), font URLs and font descriptors
/// (`[url as CFURL] as CFArray`, `… as? [CTFontDescriptor]`), as on Apple,
/// where one `CFArray` holds any of them.
public typealias CFArray = [Any]

public extension SKColor {
    /// The game converts to `CGColor` at every context call. With the two
    /// collapsed into one type this is the identity, kept so those calls
    /// read as they do on Apple.
    var cgColor: CGColor { self }
}

// MARK: - Colour spaces

/// A placeholder: the shim does no colour management, so every space is the
/// device's own and this only exists to be passed and ignored.
public final class CGColorSpace: @unchecked Sendable {
    public enum Model: Sendable { case rgb, monochrome }
    public let model: Model

    public init(model: Model) { self.model = model }

    public static let sRGB = "kCGColorSpaceSRGB"
    public static let extendedSRGB = "kCGColorSpaceExtendedSRGB"
    public static let genericGrayGamma2_2 = "kCGColorSpaceGenericGrayGamma2_2"

    public convenience init?(name: String) {
        self.init(model: name == CGColorSpace.genericGrayGamma2_2 ? .monochrome : .rgb)
    }
}

public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace(model: .rgb) }
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { CGColorSpace(model: .monochrome) }

public struct CGBitmapInfo: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 1 << 12)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 1 << 13)
    public static let floatComponents = CGBitmapInfo(rawValue: 1 << 8)
}

public enum CGImageAlphaInfo: UInt32, Sendable {
    case none = 0
    case premultipliedLast = 1
    case premultipliedFirst = 2
    case last = 3
    case first = 4
    case noneSkipLast = 5
    case noneSkipFirst = 6
    case alphaOnly = 7
}

// MARK: - Gradients

public extension Gradient {
    /// `CGGradient(colorsSpace:colors:locations:)`, as the game writes it:
    /// the colours are `CGColor`s behind the `CFArray` name, and `locations`
    /// is a C array, which an `[CGFloat]` argument becomes. Nil if anything
    /// in the array isn't a colour.
    init?(colorsSpace: CGColorSpace?, colors: CFArray, locations: UnsafePointer<CGFloat>?) {
        let colours = colors.compactMap { $0 as? CGColor }
        guard colours.count == colors.count else { return nil }
        let stops: [CGFloat]? = locations.map { pointer in
            (0 ..< colours.count).map { pointer[$0] }
        }
        self.init(colours: colours, locations: stops)
    }
}

// MARK: - The context's CoreGraphics spellings

public extension BitmapContext {
    /// `CGContext(data:width:height:bitsPerComponent:bytesPerRow:space:bitmapInfo:)`.
    ///
    /// Only 8-bit premultiplied RGBA is answered for, which is every bitmap
    /// the game makes this way; anything else returns nil rather than
    /// drawing into a layout it does not understand.
    convenience init?(
        data: UnsafeMutableRawPointer?,
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        bytesPerRow: Int,
        space: CGColorSpace?,
        bitmapInfo: UInt32
    ) {
        guard bitsPerComponent == 8, width > 0, height > 0 else { return nil }
        // Alpha only, a byte a pixel (to find what's opaque, say):
        // drawn as RGBA, its coverage handed back by `data`.
        if data == nil, bitmapInfo & 0x1F == CGImageAlphaInfo.alphaOnly.rawValue {
            self.init(width: width, height: height)
            exposesAlphaOnly = true
            translateBy(x: 0, y: CGFloat(height))
            scaleBy(x: 1, y: -1)
            return
        }
        let stride = bytesPerRow > 0 ? bytesPerRow : width * 4
        if let data {
            self.init(wrapping: data, width: width, height: height, bytesPerRow: stride)
        } else {
            self.init(width: width, height: height)
        }
        storesBGRA = BitmapContext.isBGRA(bitmapInfo: bitmapInfo)
        // CoreGraphics' own space: y up from the bottom row. Memory's first
        // row is still the image's top, as it is on Apple.
        translateBy(x: 0, y: CGFloat(height))
        scaleBy(x: 1, y: -1)
    }

    func setFillColor(_ color: CGColor) { setFill(color) }
    func setStrokeColor(_ color: CGColor) { setStroke(color) }

    func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        setFill(SKColor(red: red, green: green, blue: blue, alpha: alpha))
    }

    func setStrokeColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        setStroke(SKColor(red: red, green: green, blue: blue, alpha: alpha))
    }

    func setShadow(offset: CGSize, blur: CGFloat, color: CGColor?) {
        setShadow(offset: offset, blur: blur, colour: color)
    }

    /// CoreGraphics' no-colour form, which means a black shadow.
    func setShadow(offset: CGSize, blur: CGFloat) {
        setShadow(offset: offset, blur: blur, colour: SKColor(white: 0, alpha: 1.0 / 3))
    }

    /// `setAllowsAntialiasing` and friends are accepted and ignored: the
    /// rasteriser is always antialiased, which is what the game wants
    /// everywhere it draws.
    func setAllowsAntialiasing(_ allows: Bool) {}
    func setShouldAntialias(_ should: Bool) {}
}

// MARK: - Paths

public extension CGPath {
    convenience init(rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        self.init()
        addRect(rect, transform: transform?.pointee ?? .identity)
    }

    convenience init(ellipseIn rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        self.init()
        addEllipse(in: rect, transform: transform?.pointee ?? .identity)
    }

    convenience init(
        roundedRect rect: CGRect,
        cornerWidth: CGFloat,
        cornerHeight: CGFloat,
        transform: UnsafePointer<CGAffineTransform>?
    ) {
        self.init()
        addRoundedRect(
            in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight,
            transform: transform?.pointee ?? .identity
        )
    }

    /// The flattened bounds, which is what `CGPath.boundingBoxOfPath` is —
    /// `boundingBox` above is the looser control-point one.
    var boundingBoxOfPath: CGRect {
        let points = PathRasteriser.flatten(self, scale: 1).flatMap(\.points)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // `CGMutablePath`, `move(to:)`, `addLine(to:)`, `addLines(between:)` and
    // `closeSubpath()` are in CGMutablePath.swift. These are the transformed forms, with `transform` required
    // rather than defaulted so a plain `move(to: p)` has one meaning.

    func move(to point: CGPoint, transform: CGAffineTransform) {
        append(.move(point.applying(transform)))
    }

    func addLine(to point: CGPoint, transform: CGAffineTransform) {
        append(.line(point.applying(transform)))
    }

    func addQuadCurve(to end: CGPoint, control: CGPoint, transform: CGAffineTransform = .identity) {
        append(.quadCurve(to: end.applying(transform), control: control.applying(transform)))
    }

    func addCurve(
        to end: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        transform: CGAffineTransform = .identity
    ) {
        append(.curve(
            to: end.applying(transform),
            control1: control1.applying(transform),
            control2: control2.applying(transform)
        ))
    }

    func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
        append(portable: BitmapContext.rectangle(rect).map { $0.applying(transform) })
    }

    func addRects(_ rects: [CGRect], transform: CGAffineTransform = .identity) {
        for rect in rects { addRect(rect, transform: transform) }
    }

    func addEllipse(in rect: CGRect, transform: CGAffineTransform = .identity) {
        append(portable: BitmapContext.ellipse(in: rect).map { $0.applying(transform) })
    }

    func addRoundedRect(
        in rect: CGRect,
        cornerWidth: CGFloat,
        cornerHeight: CGFloat,
        transform: CGAffineTransform = .identity
    ) {
        let radius = min(min(cornerWidth, cornerHeight), min(rect.width, rect.height) / 2)
        guard radius > 0 else {
            addRect(rect, transform: transform)
            return
        }
        let rounded = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        append(contentsOf: rounded.cgPath.elements.map { $0.applying(transform) })
    }

    /// CoreGraphics measures `clockwise` in its own y-up space, where a
    /// clockwise sweep is a **falling** angle. The shim records the sense
    /// `UIBezierPath` uses — y-down clockwise, a rising angle — which is also
    /// what the rasteriser reads, so the flag flips on the way in.
    func addArc(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        clockwise: Bool,
        transform: CGAffineTransform = .identity
    ) {
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        append(.arc(
            center: center.applying(transform),
            radius: radius * (scale > 0 ? scale : 1),
            start: startAngle,
            end: endAngle,
            clockwise: !clockwise
        ))
    }

    /// Where the pen is, or `.zero` on an empty path, as CoreGraphics says.
    var currentPoint: CGPoint { PathGeometry.currentPoint(after: pathElements) ?? .zero }

    /// A line toward `tangent1End`, then the arc of `radius` that turns from
    /// it onto the line to `tangent2End` (`PathGeometry.tangentArc`).
    func addArc(
        tangent1End: CGPoint,
        tangent2End: CGPoint,
        radius: CGFloat,
        transform: CGAffineTransform = .identity
    ) {
        guard let pen = PathGeometry.currentPoint(after: pathElements) else {
            move(to: tangent1End, transform: transform)
            return
        }
        // The pen is already where the transform put it; work in the
        // untransformed space, as CoreGraphics does, then move the result.
        let inverse = transform.inverted()
        let elements = PathGeometry.tangentArc(
            from: pen.applying(inverse), corner: tangent1End, end: tangent2End, radius: radius
        )
        if transform.isIdentity {
            append(portable: elements)
        } else {
            let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            append(portable: elements.map { element in
                guard case let .arc(centre, r, start, end, clockwise) = element else {
                    return element.applying(transform)
                }
                return .arc(center: centre.applying(transform), radius: r * (scale > 0 ? scale : 1),
                            start: start, end: end, clockwise: clockwise)
            })
        }
    }

    /// The path cut into dashes, each an open subpath of its own.
    /// The path through `transform` (identity for nil), as CoreGraphics'
    /// `copy(using:)`: arcs become the curves CoreGraphics records for them,
    /// so any transform holds (`PathGeometry.transformed`).
    func copy(using transform: UnsafePointer<CGAffineTransform>?) -> CGPath? {
        let copy = CGPath()
        copy.replace(with: PathGeometry.transformed(pathElements, by: transform?.pointee ?? .identity))
        return copy
    }

    func copy(dashingWithPhase phase: CGFloat, lengths: [CGFloat], transform: CGAffineTransform = .identity) -> CGPath {
        let path = CGPath()
        for dash in PathGeometry.dash(PathRasteriser.flatten(self, scale: 4), phase: phase, lengths: lengths) {
            guard let first = dash.first else { continue }
            path.move(to: first, transform: transform)
            for point in dash.dropFirst() { path.addLine(to: point, transform: transform) }
        }
        return path
    }

    func addPath(_ path: CGPath, transform: CGAffineTransform = .identity) {
        append(contentsOf: transform.isIdentity
            ? path.elements
            : path.elements.map { $0.applying(transform) })
    }

    /// The outline of stroking this path, as its own path — what `Icon` asks
    /// for to measure a stroked glyph's real bounds.
    func copy(
        strokingWithWidth width: CGFloat,
        lineCap: CGLineCap,
        lineJoin: CGLineJoin,
        miterLimit: CGFloat,
        transform: CGAffineTransform = .identity
    ) -> CGPath {
        let outlines = PathRasteriser.strokeOutlines(
            PathRasteriser.flatten(self, scale: 1),
            width: width, cap: lineCap, join: lineJoin, miterLimit: miterLimit
        )
        let path = CGPath()
        for polygon in outlines {
            guard let first = polygon.first else { continue }
            path.move(to: first, transform: transform)
            for point in polygon.dropFirst() { path.addLine(to: point, transform: transform) }
            path.closeSubpath()
        }
        return path
    }
}

extension CGPath {
    /// Records segments stated in the portable terms the rasteriser reads.
    /// The two enums say the same things — one is what a path records, the
    /// other is what both platforms can state — so this is a rename.
    func append(portable elements: [PathElement]) {
        append(contentsOf: elements.map { element -> CGPath.Element in
            switch element {
            case let .move(p): return .move(p)
            case let .line(p): return .line(p)
            case let .quadCurve(p, c): return .quadCurve(to: p, control: c)
            case let .curve(p, c1, c2): return .curve(to: p, control1: c1, control2: c2)
            case let .arc(centre, radius, start, end, clockwise):
                return .arc(center: centre, radius: radius, start: start, end: end, clockwise: clockwise)
            case .close: return .close
            }
        })
    }
}

extension CGPath.Element {
    /// The same segment, moved.
    func applying(_ transform: CGAffineTransform) -> CGPath.Element {
        guard !transform.isIdentity else { return self }
        switch self {
        case let .move(p): return .move(p.applying(transform))
        case let .line(p): return .line(p.applying(transform))
        case let .quadCurve(p, c):
            return .quadCurve(to: p.applying(transform), control: c.applying(transform))
        case let .curve(p, c1, c2):
            return .curve(
                to: p.applying(transform),
                control1: c1.applying(transform),
                control2: c2.applying(transform)
            )
        case let .arc(centre, radius, start, end, clockwise):
            // An arc only stays an arc under a uniform scale; the game never
            // passes a transform to `addArc`, and a rotation would have to
            // turn the angles with it.
            let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            return .arc(
                center: centre.applying(transform),
                radius: radius * (scale > 0 ? scale : 1),
                start: start, end: end, clockwise: clockwise
            )
        case .close: return .close
        }
    }
}

extension PathElement {
    func applying(_ transform: CGAffineTransform) -> PathElement {
        guard !transform.isIdentity else { return self }
        switch self {
        case let .move(p): return .move(p.applying(transform))
        case let .line(p): return .line(p.applying(transform))
        case let .quadCurve(p, c):
            return .quadCurve(to: p.applying(transform), control: c.applying(transform))
        case let .curve(p, c1, c2):
            return .curve(
                to: p.applying(transform),
                control1: c1.applying(transform),
                control2: c2.applying(transform)
            )
        case let .arc(centre, radius, start, end, clockwise):
            let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            return .arc(
                center: centre.applying(transform),
                radius: radius * (scale > 0 ? scale : 1),
                start: start, end: end, clockwise: clockwise
            )
        case .close: return .close
        }
    }
}

#endif

#if SPRITEKIT_SHIM
/// CoreFoundation's name for a span of seconds, which corelibs Foundation
/// leaves out on Android.
public typealias CFTimeInterval = Double
#endif
