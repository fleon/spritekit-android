#if SPRITEKIT_SHIM
import Foundation

/// A software drawing context: CoreGraphics' `CGContext`, as much of it as
/// the game draws through.
///
/// A game that draws its buttons, panels, meters and cards into textures
/// through a `CGContext` (as SpriteKit games commonly do, to keep them
/// crisp at any size) shows none of them on Android until one exists.
///
/// **Why it is here and not in the renderer.** A game file reaches this
/// through a plain `import UIKit`, which on Android resolves to a target that
/// re-exports this module and nothing else. `PathRasteriser` moved down here
/// for the same reason, and does the scan conversion: this is the state
/// machine, the compositor and the colour over it.
///
/// **Coordinates.** `UIGraphicsImageRenderer` hands the game a context whose
/// user space is points with y growing **down** from the top left, which is
/// also the order the bitmap stores its rows in. So the base transform is a
/// plain scale and there is no flip anywhere: a point (x, y) in user space is
/// pixel (x · scale, y · scale), and row 0 is the top.
///
/// **Pixels** are RGBA8 premultiplied, which is what the GL renderer uploads
/// and what the game's art already is.
public final class BitmapContext {

    // MARK: Types

    /// How a drawing operation combines with what is already there.
    ///
    /// Spelled as CoreGraphics spells it so `CGBlendMode` can be an alias.
    /// Every one CoreGraphics has: the separable blends, the four
    /// non-separable ones (hue, saturation, color, luminosity), the two plus
    /// modes and the Porter-Duff set (`BlendModeTests` checks each against
    /// CoreGraphics on the Mac).
    public enum BlendMode: Int, Sendable {
        case normal, multiply, screen, overlay, darken, lighten
        case colorDodge, colorBurn, softLight, hardLight, difference, exclusion
        case hue, saturation, color, luminosity
        case clear, copy
        case sourceIn, sourceOut, sourceAtop
        case destinationOver, destinationIn, destinationOut, destinationAtop
        case xor, plusDarker, plusLighter
    }

    /// CoreGraphics' `CGPathFillRule`.
    public enum PathFillRule: Int, Sendable {
        case winding, evenOdd

        var rasteriserRule: PathRasteriser.FillRule {
            self == .evenOdd ? .evenOdd : .nonZero
        }
    }

    /// CoreGraphics' `CGGradientDrawingOptions`.
    public struct GradientOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let drawsBeforeStartLocation = GradientOptions(rawValue: 1 << 0)
        public static let drawsAfterEndLocation = GradientOptions(rawValue: 1 << 1)
    }

    /// CoreGraphics' `CGInterpolationQuality`. Only "none or not none" is
    /// acted on: nearest or bilinear.
    public enum InterpolationQuality: Int, Sendable {
        case `default`, none, low, medium, high
    }

    /// A premultiplied colour in 0...1.
    struct Premultiplied {
        var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

        static let clear = Premultiplied(r: 0, g: 0, b: 0, a: 0)

        init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(_ colour: SKColor, alpha: CGFloat = 1) {
            let a = max(0, min(1, colour.alpha * alpha))
            r = max(0, min(1, colour.red)) * a
            g = max(0, min(1, colour.green)) * a
            b = max(0, min(1, colour.blue)) * a
            self.a = a
        }
    }

    /// A clip: coverage over the pixels it reaches, and nothing outside.
    ///
    /// Clipping is another coverage mask multiplied in, which is the whole
    /// trick — a rounded face clips its gradient and its gloss by the same
    /// antialiased edge the fill would have had, so nothing steps.
    struct Clip {
        var box: PathRasteriser.PixelBox
        var alpha: [UInt8]

        func coverage(x: Int, y: Int) -> UInt8 {
            guard x >= box.x, y >= box.y, x < box.maxX, y < box.maxY else { return 0 }
            return alpha[(y - box.y) * box.width + (x - box.x)]
        }

        func intersecting(_ other: Clip) -> Clip {
            let box = box.intersection(other.box)
            guard !box.isEmpty else { return Clip(box: box, alpha: []) }
            var alpha = [UInt8](repeating: 0, count: box.count)
            for y in 0 ..< box.height {
                for x in 0 ..< box.width {
                    let mine = Int(coverage(x: box.x + x, y: box.y + y))
                    let theirs = Int(other.coverage(x: box.x + x, y: box.y + y))
                    alpha[y * box.width + x] = UInt8((mine * theirs + 127) / 255)
                }
            }
            return Clip(box: box, alpha: alpha)
        }
    }

    struct Shadow {
        /// In device pixels, y down.
        var offset: CGSize
        /// The Gaussian's standard deviation, in device pixels.
        var sigma: CGFloat
        var colour: SKColor
    }

    /// Everything `saveGState` saves.
    struct State {
        var ctm: CGAffineTransform
        var fill = SKColor.black
        var stroke = SKColor.black
        var alpha: CGFloat = 1
        var blend = BlendMode.normal
        var lineWidth: CGFloat = 1
        var lineCap = CGLineCap.butt
        var lineJoin = CGLineJoin.miter
        var miterLimit: CGFloat = 10
        /// `setLineDash`: the pattern in user space, nil for a solid line.
        var dash: (phase: CGFloat, lengths: [CGFloat])?
        var clip: Clip?
        var shadow: Shadow?
        var interpolation = InterpolationQuality.default
    }

    // MARK: Storage

    /// Pixels across and down. The bitmap is `scale` pixels per point.
    public let width: Int
    public let height: Int
    /// The stride of the bitmap being drawn into, which a transparency
    /// layer's own (tightly packed) bitmap may not share with the context's.
    public private(set) var bytesPerRow: Int
    /// Pixels per point: the context's own, before any CTM.
    public let scale: CGFloat

    private var storage: UnsafeMutablePointer<UInt8>
    private var ownsStorage: Bool

    /// What `CGContext.data` hands back — the live pixels, premultiplied
    /// RGBA8. A game reading back what it drew reads a context's bytes this
    /// way.
    public var data: UnsafeMutableRawPointer? {
        guard exposesAlphaOnly else { return UnsafeMutableRawPointer(storage) }
        // An alpha-only bitmap's bytes: one a pixel, its coverage, read off
        // the RGBA it is drawn into as it stands now.
        let plane = alphaPlane ?? UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        alphaPlane = plane
        for row in 0 ..< height {
            for column in 0 ..< width { plane[row * width + column] = storage[row * bytesPerRow + column * 4 + 3] }
        }
        return UnsafeMutableRawPointer(plane)
    }

    /// Set for a context made alpha-only (`CGImageAlphaInfo.alphaOnly`):
    /// it draws as RGBA, and `data` hands back the coverage alone.
    public var exposesAlphaOnly = false
    private var alphaPlane: UnsafeMutablePointer<UInt8>?

    private var state: State
    private var stack: [State] = []

    /// Layers pushed by `beginTransparencyLayer`: the bitmap they interrupted
    /// and the state to composite them back with.
    private struct Layer {
        var storage: UnsafeMutablePointer<UInt8>
        var ownsStorage: Bool
        var bytesPerRow: Int
        var state: State
        var depth: Int
    }
    private var layers: [Layer] = []

    // MARK: Path

    /// The current path, flattened, in **device pixels**.
    ///
    /// CoreGraphics transforms a point into device space as it is added, not
    /// when the path is drawn, and `Icon.swift` moves the CTM between two
    /// `addPath` calls — so this has to hold device space, not user space.
    /// Flattening happens in user space at the CTM's scale and the points are
    /// mapped afterwards, which is exact: an affine map commutes with
    /// subdivision, so a transformed flattened curve is the flattening of the
    /// transformed curve.
    private var subpaths: [PathRasteriser.Subpath] = []
    /// Segments added since the last CTM change, still in user space.
    private var pending: [PathElement] = []

    // MARK: Life

    /// A context that owns its pixels, cleared to transparent.
    public init(width: Int, height: Int, scale: CGFloat = 1, opaque: Bool = false) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.scale = scale > 0 ? scale : 1
        bytesPerRow = self.width * 4
        let count = max(1, self.width * self.height * 4)
        storage = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        storage.initialize(repeating: 0, count: count)
        // Opaque means opaque black, so only the alpha byte is set.
        if opaque {
            for i in stride(from: 3, to: count, by: 4) { storage[i] = 255 }
        }
        ownsStorage = true
        state = State(ctm: CGAffineTransform(scaleX: self.scale, y: self.scale))
    }

    /// A context over pixels somebody else owns, as
    /// `CGContext(data:width:height:...)` makes one. Nothing is cleared and
    /// nothing is freed.
    public init?(
        wrapping data: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        scale: CGFloat = 1
    ) {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.scale = scale > 0 ? scale : 1
        storage = data.assumingMemoryBound(to: UInt8.self)
        ownsStorage = false
        state = State(ctm: CGAffineTransform(scaleX: self.scale, y: self.scale))
    }

    deinit {
        for layer in layers where layer.ownsStorage { layer.storage.deallocate() }
        if ownsStorage { storage.deallocate() }
        alphaPlane?.deallocate()
    }

    // MARK: Graphics state

    public func saveGState() {
        flushPending()
        stack.append(state)
    }

    public func restoreGState() {
        flushPending()
        guard let restored = stack.popLast() else { return }
        state = restored
    }

    public var ctm: CGAffineTransform { state.ctm }

    public func translateBy(x: CGFloat, y: CGFloat) {
        flushPending()
        state.ctm = CGAffineTransform(translationX: x, y: y).concatenating(state.ctm)
    }

    public func scaleBy(x: CGFloat, y: CGFloat) {
        flushPending()
        state.ctm = CGAffineTransform(scaleX: x, y: y).concatenating(state.ctm)
    }

    public func rotate(by angle: CGFloat) {
        flushPending()
        state.ctm = CGAffineTransform(rotationAngle: angle).concatenating(state.ctm)
    }

    public func concatenate(_ transform: CGAffineTransform) {
        flushPending()
        state.ctm = transform.concatenating(state.ctm)
    }

    public func setAlpha(_ alpha: CGFloat) { state.alpha = max(0, min(1, alpha)) }
    public func setBlendMode(_ mode: BlendMode) { state.blend = mode }
    public func setLineWidth(_ width: CGFloat) { state.lineWidth = width }
    public func setLineCap(_ cap: CGLineCap) { state.lineCap = cap }

    /// Strokes from here on run in dashes, `phase` into the pattern; an
    /// empty pattern strokes solid again, as CoreGraphics has it.
    public func setLineDash(phase: CGFloat, lengths: [CGFloat]) {
        state.dash = lengths.contains(where: { $0 > 0 }) ? (phase, lengths) : nil
    }
    public func setLineJoin(_ join: CGLineJoin) { state.lineJoin = join }
    public func setMiterLimit(_ limit: CGFloat) { state.miterLimit = limit }
    public func setFill(_ colour: SKColor) { state.fill = colour }
    public func setStroke(_ colour: SKColor) { state.stroke = colour }

    public var interpolationQuality: InterpolationQuality {
        get { state.interpolation }
        set { state.interpolation = newValue }
    }

    /// A shadow in user space: `offset` points the way the shadow falls (down
    /// the screen for a positive y, since user space has y down) and `blur`
    /// is CoreGraphics' blur parameter, taken as a Gaussian of half its width.
    public func setShadow(offset: CGSize, blur: CGFloat, colour: SKColor?) {
        guard let colour, colour.alpha > 0, blur >= 0 else {
            state.shadow = nil
            return
        }
        let t = state.ctm
        state.shadow = Shadow(
            offset: CGSize(
                width: offset.width * t.a + offset.height * t.c,
                height: offset.width * t.b + offset.height * t.d
            ),
            sigma: blur * transformScale / 2,
            colour: colour
        )
    }

    /// How much the CTM scales, as the square root of the area it multiplies
    /// by — the plain scale when there is no rotation, and the right average
    /// when there is.
    var transformScale: CGFloat {
        let t = state.ctm
        let determinant = abs(t.a * t.d - t.b * t.c)
        return determinant > 0 ? sqrt(determinant) : 0
    }

    // MARK: Building a path

    public func beginPath() {
        pending = []
        subpaths = []
    }

    public func move(to point: CGPoint) { pending.append(.move(point)) }
    public func addLine(to point: CGPoint) { pending.append(.line(point)) }

    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {
        pending.append(.curve(to: end, control1: control1, control2: control2))
    }

    public func addQuadCurve(to end: CGPoint, control: CGPoint) {
        pending.append(.quadCurve(to: end, control: control))
    }

    public func closePath() { pending.append(.close) }

    public func addRect(_ rect: CGRect) {
        pending.append(contentsOf: BitmapContext.rectangle(rect))
    }

    public func addRects(_ rects: [CGRect]) { for rect in rects { addRect(rect) } }

    public func addEllipse(in rect: CGRect) {
        pending.append(contentsOf: BitmapContext.ellipse(in: rect))
    }

    /// A rectangle's segments. Built here rather than through a `CGPath` so
    /// this file never has to construct one — on the Mac that type is
    /// CoreGraphics' own, and the point of the context compiling there is
    /// that it can be tested there.
    static func rectangle(_ rect: CGRect) -> [PathElement] {
        [
            .move(CGPoint(x: rect.minX, y: rect.minY)),
            .line(CGPoint(x: rect.maxX, y: rect.minY)),
            .line(CGPoint(x: rect.maxX, y: rect.maxY)),
            .line(CGPoint(x: rect.minX, y: rect.maxY)),
            .close,
        ]
    }

    /// An ellipse as four cubic arcs, the usual kappa — the same construction
    /// `UIBezierPath(ovalIn:)` uses, so a circle drawn either way matches.
    static func ellipse(in rect: CGRect) -> [PathElement] {
        let k: CGFloat = 0.5522847498
        let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
        let (rx, ry) = (w / 2, h / 2)
        let cx = x + rx, cy = y + ry
        return [
            .move(CGPoint(x: cx, y: y + h)),
            .curve(to: CGPoint(x: x + w, y: cy),
                   control1: CGPoint(x: cx + rx * k, y: y + h),
                   control2: CGPoint(x: x + w, y: cy + ry * k)),
            .curve(to: CGPoint(x: cx, y: y),
                   control1: CGPoint(x: x + w, y: cy - ry * k),
                   control2: CGPoint(x: cx + rx * k, y: y)),
            .curve(to: CGPoint(x: x, y: cy),
                   control1: CGPoint(x: cx - rx * k, y: y),
                   control2: CGPoint(x: x, y: cy - ry * k)),
            .curve(to: CGPoint(x: cx, y: y + h),
                   control1: CGPoint(x: x, y: cy + ry * k),
                   control2: CGPoint(x: cx - rx * k, y: y + h)),
            .close,
        ]
    }

    public func addPath(_ path: CGPath) {
        flushPending()
        append(path.pathElements)
    }

    /// Replaces the current path with the outline of stroking it, which is
    /// how a rim is drawn as a gradient: stroke the shape, clip to that, fill
    /// the gradient through it.
    public func replacePathWithStrokedPath() {
        flushPending()
        let outlines = PathRasteriser.strokeOutlines(
            subpaths,
            width: state.lineWidth * transformScale,
            cap: state.lineCap,
            join: state.lineJoin,
            miterLimit: state.miterLimit
        )
        subpaths = outlines.map { PathRasteriser.Subpath(points: $0, isClosed: true) }
    }

    public var isPathEmpty: Bool { subpaths.isEmpty && pending.isEmpty }

    /// The current path's bounds, in device pixels.
    var pathBounds: CGRect? {
        flushPending()
        return bounds(of: subpaths.map(\.points))
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        let elements = pending
        pending = []
        append(elements)
    }

    private func append(_ elements: [PathElement]) {
        let transform = state.ctm
        let flattened = PathRasteriser.flatten(elements, scale: max(transformScale, 0.0001))
        for subpath in flattened {
            subpaths.append(PathRasteriser.Subpath(
                points: subpath.points.map { $0.applying(transform) },
                isClosed: subpath.isClosed
            ))
        }
    }

    // MARK: Filling and stroking

    public func fillPath(using rule: PathFillRule = .winding) {
        flushPending()
        defer { beginPath() }
        guard let coverage = fillCoverage(rule: rule) else { return }
        paint(coverage, with: .solid(Premultiplied(state.fill, alpha: state.alpha)))
    }

    public func strokePath() {
        flushPending()
        defer { beginPath() }
        guard let coverage = strokeCoverage() else { return }
        paint(coverage, with: .solid(Premultiplied(state.stroke, alpha: state.alpha)))
    }

    public func drawPath(using mode: DrawMode) {
        flushPending()
        defer { beginPath() }
        if mode != .stroke, let coverage = fillCoverage(rule: mode == .eoFill || mode == .eoFillStroke ? .evenOdd : .winding) {
            paint(coverage, with: .solid(Premultiplied(state.fill, alpha: state.alpha)))
        }
        if mode == .stroke || mode == .fillStroke || mode == .eoFillStroke,
           let coverage = strokeCoverage() {
            paint(coverage, with: .solid(Premultiplied(state.stroke, alpha: state.alpha)))
        }
    }

    public enum DrawMode: Int, Sendable {
        case fill, eoFill, stroke, fillStroke, eoFillStroke
    }

    public func fill(_ rect: CGRect) {
        beginPath()
        addRect(rect)
        fillPath()
    }

    public func fill(_ rects: [CGRect]) {
        beginPath()
        addRects(rects)
        fillPath()
    }

    public func fillEllipse(in rect: CGRect) {
        beginPath()
        addEllipse(in: rect)
        fillPath()
    }

    public func stroke(_ rect: CGRect) {
        beginPath()
        addRect(rect)
        strokePath()
    }

    public func stroke(_ rect: CGRect, width: CGFloat) {
        setLineWidth(width)
        stroke(rect)
    }

    public func strokeEllipse(in rect: CGRect) {
        beginPath()
        addEllipse(in: rect)
        strokePath()
    }

    public func strokeLineSegments(between points: [CGPoint]) {
        beginPath()
        var index = 0
        while index + 1 < points.count {
            move(to: points[index])
            addLine(to: points[index + 1])
            index += 2
        }
        strokePath()
    }

    /// Empties the pixels under `rect`, through the clip, whatever the blend
    /// mode is — CoreGraphics' `clear(_:)` ignores it.
    public func clear(_ rect: CGRect) {
        beginPath()
        addRect(rect)
        flushPending()
        defer { beginPath() }
        guard let coverage = fillCoverage(rule: .winding) else { return }
        let blend = state.blend
        let shadow = state.shadow
        state.blend = .clear
        state.shadow = nil
        paint(coverage, with: .solid(.clear))
        state.blend = blend
        state.shadow = shadow
    }

    // MARK: Clipping

    public func clip(using rule: PathFillRule = .winding) {
        flushPending()
        defer { beginPath() }
        guard let coverage = fillCoverage(rule: rule) else {
            // An empty path clips everything away, as CoreGraphics does.
            state.clip = Clip(box: PathRasteriser.PixelBox(x: 0, y: 0, width: 0, height: 0), alpha: [])
            return
        }
        narrowClip(to: Clip(box: coverage.box, alpha: coverage.alpha))
    }

    public func clip(to rect: CGRect) {
        clip(to: [rect])
    }

    public func clip(to rects: [CGRect]) {
        flushPending()
        let t = state.ctm
        // The usual case by far: no rotation, so a rectangle stays one and
        // its coverage can be worked out per pixel instead of rasterised.
        if abs(t.b) < 1e-9, abs(t.c) < 1e-9, rects.count == 1, let rect = rects.first {
            narrowClip(to: rectangleClip(rect.applying(t)))
            return
        }
        beginPath()
        for rect in rects { addRect(rect) }
        clip(using: .winding)
    }

    /// Coverage for an axis-aligned rectangle in device pixels, exactly: a
    /// pixel the edge crosses takes the fraction of it the rectangle covers.
    private func rectangleClip(_ rect: CGRect) -> Clip {
        let box = PathRasteriser.PixelBox.covering(rect).intersection(canvasBox)
        guard !box.isEmpty else { return Clip(box: box, alpha: []) }
        var alpha = [UInt8](repeating: 0, count: box.count)
        for y in 0 ..< box.height {
            let top = CGFloat(box.y + y)
            let down = max(0, min(rect.maxY, top + 1) - max(rect.minY, top))
            guard down > 0 else { continue }
            for x in 0 ..< box.width {
                let left = CGFloat(box.x + x)
                let across = max(0, min(rect.maxX, left + 1) - max(rect.minX, left))
                guard across > 0 else { continue }
                alpha[y * box.width + x] = UInt8(max(0, min(255, (across * down * 255).rounded())))
            }
        }
        return Clip(box: box, alpha: alpha)
    }

    private func narrowClip(to clip: Clip) {
        state.clip = state.clip.map { $0.intersecting(clip) } ?? clip
    }

    // MARK: Gradients

    /// A gradient along the line from `start` to `end`, in user space.
    public func drawLinearGradient(
        _ gradient: Gradient,
        start: CGPoint,
        end: CGPoint,
        options: GradientOptions
    ) {
        let a = start.applying(state.ctm)
        let b = end.applying(state.ctm)
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-12 else { return }

        // A gradient straight down (or across) is the same along each row
        // (or column): sampled once a row, or once a column, not a pixel.
        if dx == 0, state.blend == .normal {
            // A row at a time, through the solid-colour path.
            let box = (state.clip?.box ?? canvasBox).intersection(canvasBox)
            guard !box.isEmpty else { return }
            let alpha = state.alpha
            for y in box.y ..< box.maxY {
                let py = CGFloat(y) + 0.5 - a.y
                guard var colour = gradient.sample(at: (0 + py * dy) / lengthSquared, options: options) else { continue }
                if alpha < 1 { colour.r *= alpha; colour.g *= alpha; colour.b *= alpha; colour.a *= alpha }
                let row = PathRasteriser.PixelBox(x: box.x, y: y, width: box.width, height: 1)
                compositeSolid(box: row, coverage: nil, coverageBox: row, colour: colour)
            }
            return
        }
        if dx == 0 {
            var row = Int.min
            var colour: Premultiplied?
            paintEverywhere { _, y in
                if y != row {
                    row = y
                    let py = CGFloat(y) + 0.5 - a.y
                    colour = gradient.sample(at: (0 + py * dy) / lengthSquared, options: options)
                }
                return colour
            }
            return
        }
        if dy == 0 {
            var columns = [Premultiplied?](repeating: nil, count: width)
            var known = [Bool](repeating: false, count: width)
            paintEverywhere { x, _ in
                if known[x] { return columns[x] }
                let px = CGFloat(x) + 0.5 - a.x
                let colour = gradient.sample(at: (px * dx + 0) / lengthSquared, options: options)
                columns[x] = colour
                known[x] = true
                return colour
            }
            return
        }
        paintEverywhere { x, y in
            let px = CGFloat(x) + 0.5 - a.x
            let py = CGFloat(y) + 0.5 - a.y
            let t = (px * dx + py * dy) / lengthSquared
            return gradient.sample(at: t, options: options)
        }
    }

    /// A gradient between two circles, as CoreGraphics draws one. Most radial
    /// gradients are concentric with a zero start radius (glows, spots of
    /// light), which is the easy case of the same solve.
    public func drawRadialGradient(
        _ gradient: Gradient,
        startCenter: CGPoint,
        startRadius: CGFloat,
        endCenter: CGPoint,
        endRadius: CGFloat,
        options: GradientOptions
    ) {
        let scale = transformScale
        let c0 = startCenter.applying(state.ctm)
        let c1 = endCenter.applying(state.ctm)
        let r0 = startRadius * scale
        let r1 = endRadius * scale
        let cdx = c1.x - c0.x, cdy = c1.y - c0.y
        let dr = r1 - r0
        let a = cdx * cdx + cdy * cdy - dr * dr

        paintEverywhere { x, y in
            let px = CGFloat(x) + 0.5 - c0.x
            let py = CGFloat(y) + 0.5 - c0.y
            let b = px * cdx + py * cdy + r0 * dr
            let c = px * px + py * py - r0 * r0
            let t: CGFloat
            if abs(a) < 1e-9 {
                guard abs(b) > 1e-12 else { return nil }
                t = c / (2 * b)
            } else {
                let discriminant = b * b - a * c
                guard discriminant >= 0 else { return nil }
                let root = sqrt(discriminant)
                // The larger root first: the outermost circle through the
                // point is the one whose colour shows.
                let high = (b + root) / a
                let low = (b - root) / a
                if r0 + high * dr >= 0 {
                    t = high
                } else if r0 + low * dr >= 0 {
                    t = low
                } else {
                    return nil
                }
            }
            return gradient.sample(at: t, options: options)
        }
    }

    /// Paints every pixel the clip reaches, which is what a gradient does:
    /// it has no shape of its own.
    private func paintEverywhere(_ colour: (Int, Int) -> Premultiplied?) {
        let box = (state.clip?.box ?? canvasBox).intersection(canvasBox)
        guard !box.isEmpty else { return }
        let alpha = state.alpha
        guard alpha < 1 else {
            composite(box: box, coverage: nil, source: colour)
            return
        }
        composite(box: box, coverage: nil) { x, y in
            guard var c = colour(x, y) else { return nil }
            c.r *= alpha; c.g *= alpha; c.b *= alpha; c.a *= alpha
            return c
        }
    }

    // MARK: Images

    /// Draws `image` into `rect` in user space, sampled bilinearly unless the
    /// interpolation quality says otherwise.
    ///
    /// As CoreGraphics does, the image's top row lands on the rect's
    /// **maxY** edge in user space. A raw bitmap context is y-up (see
    /// `CGContext(data:...)`), so an image drawn over the whole of one fills
    /// it the right way up; a renderer's context is y-down, as UIKit's is,
    /// so an image drawn straight into one comes out upside down — the
    /// CoreGraphics gotcha game code already flips for.
    public func draw(_ image: RasterImage, in rect: CGRect) {
        draw(image, in: rect, byTiling: false)
    }

    /// With `byTiling`, the image repeats from `rect` across everything the
    /// clip leaves, as CoreGraphics' `draw(_:in:byTiling:)` does.
    public func draw(_ image: RasterImage, in rect: CGRect, byTiling: Bool) {
        guard image.width > 0, image.height > 0, rect.width != 0, rect.height != 0 else { return }
        let device = rect.applying(state.ctm)
        let box = (byTiling ? canvasBox : PathRasteriser.PixelBox.covering(device))
            .intersection(canvasBox)
            .intersection(state.clip?.box ?? canvasBox)
        guard !box.isEmpty else { return }

        // Device pixel back into the rect's unit square, then into the
        // image's own pixels. The inverse of the CTM does the rotation; the
        // rect does the rest.
        let inverse = state.ctm.inverted()
        let smooth = state.interpolation != .none
        let alpha = state.alpha
        let coverage = byTiling ? rectangleClip(CGRect(x: 0, y: 0, width: width, height: height)) : rectangleClip(device)

        composite(box: box, coverage: coverage.alpha, coverageBox: coverage.box) { x, y in
            let user = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
            var u = (user.x - rect.minX) / rect.width
            // The image's row 0 is its top, which lands on the rect's maxY.
            var v = (rect.maxY - user.y) / rect.height
            if byTiling {
                u -= u.rounded(.down)
                v -= v.rounded(.down)
            }
            guard u >= 0, u <= 1, v >= 0, v <= 1,
                  var sample = image.sample(u: u, v: v, smooth: smooth) else { return nil }
            sample.r *= alpha; sample.g *= alpha; sample.b *= alpha; sample.a *= alpha
            return sample
        }
    }

    /// The pixels as they stand, copied.
    public func makeImage() -> RasterImage? {
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0 ..< height {
                let source = storage + y * bytesPerRow
                let destination = out.baseAddress! + y * width * 4
                destination.update(from: source, count: width * 4)
                guard storesBGRA else { continue }
                for x in stride(from: 0, to: width * 4, by: 4) {
                    let blue = destination[x]
                    destination[x] = destination[x + 2]
                    destination[x + 2] = blue
                }
            }
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    /// Whether the pixels it wraps are BGRA (CoreGraphics' premultiplied
    /// first, 32-bit little-endian: a video frame's pixel buffer), which
    /// `makeImage` hands back as RGBA. Only reading such a buffer is
    /// answered for: drawing into one would draw RGBA.
    public var storesBGRA = false

    /// Whether CoreGraphics' `bitmapInfo` lays 32-bit pixels out as BGRA:
    /// alpha first (premultiplied, or skipped) in little-endian words.
    public static func isBGRA(bitmapInfo: UInt32) -> Bool {
        let alpha = bitmapInfo & 0x1F
        let little = bitmapInfo & (1 << 13) != 0
        return little && (alpha == 2 || alpha == 6)
    }

    // MARK: Transparency layers

    /// Starts drawing into a fresh transparent bitmap. What is drawn there
    /// composites back as one piece when the layer ends, with the alpha,
    /// blend mode and shadow that were in force when it began — which is what
    /// makes `.sourceIn` usable: it tints what the layer drew rather than
    /// everything underneath.
    public func beginTransparencyLayer(auxiliaryInfo: [String: Any]? = nil) {
        flushPending()
        let count = max(1, width * height * 4)
        let fresh = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        fresh.initialize(repeating: 0, count: count)
        layers.append(Layer(
            storage: storage,
            ownsStorage: ownsStorage,
            bytesPerRow: bytesPerRow,
            state: state,
            depth: stack.count
        ))
        storage = fresh
        ownsStorage = true
        bytesPerRow = width * 4
        // Inside the layer everything draws plainly; the state applies to the
        // composite, not to each piece.
        state.alpha = 1
        state.blend = .normal
        state.shadow = nil
    }

    public func endTransparencyLayer() {
        flushPending()
        guard let layer = layers.popLast() else { return }
        let drawn = storage
        let drawnRow = bytesPerRow
        storage = layer.storage
        ownsStorage = layer.ownsStorage
        bytesPerRow = layer.bytesPerRow
        if stack.count > layer.depth { stack.removeLast(stack.count - layer.depth) }
        state = layer.state

        let box = (state.clip?.box ?? canvasBox).intersection(canvasBox)
        if !box.isEmpty {
            // The layer as one shape: its own alpha is its coverage, so a
            // shadow set when the layer began falls from the whole of what
            // it drew rather than from each piece separately.
            if let shadow = state.shadow {
                var alpha = [UInt8](repeating: 0, count: box.count)
                for y in 0 ..< box.height {
                    for x in 0 ..< box.width {
                        alpha[y * box.width + x] = drawn[(box.y + y) * drawnRow + (box.x + x) * 4 + 3]
                    }
                }
                castShadow(Coverage(box: box, alpha: alpha), shadow: shadow)
            }
            // `composite` never applies the state's alpha — every other
            // caller folds it into the colour it hands over — so it is
            // folded in here too.
            let alpha = state.alpha
            composite(box: box, coverage: nil) { x, y in
                let p = drawn + y * drawnRow + x * 4
                return Premultiplied(
                    r: CGFloat(p[0]) / 255 * alpha, g: CGFloat(p[1]) / 255 * alpha,
                    b: CGFloat(p[2]) / 255 * alpha, a: CGFloat(p[3]) / 255 * alpha
                )
            }
        }
        drawn.deallocate()
    }

    // MARK: Coverage

    struct Coverage {
        var box: PathRasteriser.PixelBox
        var alpha: [UInt8]
    }

    private var canvasBox: PathRasteriser.PixelBox {
        PathRasteriser.PixelBox(x: 0, y: 0, width: width, height: height)
    }

    private func fillCoverage(rule: PathFillRule) -> Coverage? {
        let polygons = subpaths.map(\.points).filter { $0.count > 2 }
        return coverage(of: polygons, rule: rule.rasteriserRule)
    }

    private func strokeCoverage() -> Coverage? {
        let width = state.lineWidth * transformScale
        guard width > 0 else { return nil }
        // Dashed in device pixels, so the pattern scales with the CTM.
        let stroked = state.dash.map { dash in
            PathGeometry.dash(subpaths, phase: dash.phase * transformScale,
                              lengths: dash.lengths.map { $0 * transformScale })
                .map { PathRasteriser.Subpath(points: $0, isClosed: false) }
        } ?? subpaths
        let outlines = PathRasteriser.strokeOutlines(
            stroked,
            width: width,
            cap: state.lineCap,
            join: state.lineJoin,
            miterLimit: state.miterLimit
        )
        return coverage(of: outlines, rule: .nonZero)
    }

    /// Scan converts polygons that are already in device pixels, over the
    /// pixels the shape, the clip and the canvas all reach. Shadows need the
    /// coverage to spread, so the box grows by the blur's reach first.
    private func coverage(
        of polygons: [[CGPoint]],
        rule: PathRasteriser.FillRule
    ) -> Coverage? {
        guard !polygons.isEmpty, let shapeBounds = bounds(of: polygons) else { return nil }
        var reachable = canvasBox
        if let clip = state.clip { reachable = reachable.intersection(clip.box) }
        if let shadow = state.shadow {
            // The shape may sit off the clip entirely and still cast into it.
            let spread = Int(ceil(shadow.sigma * 3)) + 1
            reachable = PathRasteriser.PixelBox(
                x: reachable.x - spread - Int(abs(shadow.offset.width).rounded(.up)),
                y: reachable.y - spread - Int(abs(shadow.offset.height).rounded(.up)),
                width: reachable.width + (spread + Int(abs(shadow.offset.width).rounded(.up))) * 2,
                height: reachable.height + (spread + Int(abs(shadow.offset.height).rounded(.up))) * 2
            )
        }
        let box = PathRasteriser.PixelBox.covering(shapeBounds).intersection(reachable)
        guard !box.isEmpty else { return nil }
        let alpha = PathRasteriser.coverage(polygons, rule: rule, in: box)
        guard !alpha.isEmpty else { return nil }
        return Coverage(box: box, alpha: alpha)
    }

    private func bounds(of polygons: [[CGPoint]]) -> CGRect? {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var any = false
        for polygon in polygons {
            for p in polygon where p.x.isFinite && p.y.isFinite {
                any = true
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard any, minX <= maxX, minY <= maxY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Painting

    private enum Paint {
        case solid(Premultiplied)
    }

    /// Draws a shape: its shadow first, then the shape itself.
    private func paint(_ coverage: Coverage, with paint: Paint) {
        if let shadow = state.shadow {
            castShadow(coverage, shadow: shadow)
        }
        switch paint {
        case let .solid(colour):
            guard colour.a > 0 || affectsTransparentSource else { return }
            if state.blend == .normal {
                compositeSolid(box: coverage.box, coverage: coverage.alpha, coverageBox: coverage.box, colour: colour)
                return
            }
            composite(box: coverage.box, coverage: coverage.alpha, coverageBox: coverage.box) { _, _ in colour }
        }
    }

    /// Blend modes whose result where the source is empty is not "leave the
    /// destination alone" — `clear` has to run even for a transparent fill.
    private var affectsTransparentSource: Bool {
        switch state.blend {
        case .clear, .copy, .sourceIn, .sourceOut, .destinationIn, .destinationAtop: return true
        default: return false
        }
    }

    private func composite(
        box: PathRasteriser.PixelBox,
        coverage: [UInt8]?,
        coverageBox: PathRasteriser.PixelBox? = nil,
        source: (Int, Int) -> Premultiplied?
    ) {
        let box = box.intersection(canvasBox)
        guard !box.isEmpty else { return }
        let coverageBox = coverageBox ?? box
        let clip = state.clip
        let blend = state.blend
        let isNormal = blend == .normal
        let unit = Self.unit

        for y in box.y ..< box.maxY {
            let row = storage + y * bytesPerRow
            for x in box.x ..< box.maxX {
                var mask = 255
                if let coverage {
                    guard x >= coverageBox.x, y >= coverageBox.y,
                          x < coverageBox.maxX, y < coverageBox.maxY else { continue }
                    mask = Int(coverage[(y - coverageBox.y) * coverageBox.width + (x - coverageBox.x)])
                }
                if let clip { mask = (mask * Int(clip.coverage(x: x, y: y)) + 127) / 255 }
                guard mask > 0 else { continue }
                guard let src = source(x, y) else { continue }

                let p = row + x * 4
                let dst = Premultiplied(
                    r: unit[Int(p[0])], g: unit[Int(p[1])],
                    b: unit[Int(p[2])], a: unit[Int(p[3])]
                )
                // Source-over inline, as `blend` works it out.
                let blended = isNormal
                    ? Premultiplied(
                        r: src.r * 1 + dst.r * (1 - src.a), g: src.g * 1 + dst.g * (1 - src.a),
                        b: src.b * 1 + dst.b * (1 - src.a), a: src.a * 1 + dst.a * (1 - src.a)
                    )
                    : BitmapContext.blend(blend, src: src, dst: dst)
                let c = unit[mask]
                // Coverage as a mask over the *result*, not over the source's
                // alpha. That is what makes `.clear` erase the path and leave
                // everything round it, which is how the game punches holes.
                p[0] = byte(dst.r + (blended.r - dst.r) * c)
                p[1] = byte(dst.g + (blended.g - dst.g) * c)
                p[2] = byte(dst.b + (blended.b - dst.b) * c)
                p[3] = byte(dst.a + (blended.a - dst.a) * c)
            }
        }
    }

    /// `composite` for one colour laid down source-over (`.normal`), the
    /// case nearly every fill and every shadow is: the same arithmetic, so
    /// the same bytes, without a closure, a blend switch and two colours
    /// built for every pixel, which made a panel's surfaces take most of a
    /// second on a phone.
    private func compositeSolid(
        box: PathRasteriser.PixelBox,
        coverage: [UInt8]?,
        coverageBox: PathRasteriser.PixelBox,
        colour src: Premultiplied
    ) {
        let box = box.intersection(canvasBox).intersection(coverageBox)
        guard !box.isEmpty else { return }
        let clip = state.clip
        let keep = 1 - src.a
        let unit = Self.unit
        // Over an empty pixel the result depends on the coverage alone (most
        // of a shadow), so each coverage's is worked out once; and a pixel
        // like the one before, under the same coverage (a panel's even
        // middle), takes the same result. Both by the arithmetic below.
        var overEmpty = [UInt32](repeating: 0, count: 256)
        var knownOverEmpty = [Bool](repeating: false, count: 256)
        var lastIn: UInt32 = 0, lastMask = -1, lastOut: UInt32 = 0
        (coverage ?? []).withUnsafeBufferPointer { cover in
            for y in box.y ..< box.maxY {
                let row = storage + y * bytesPerRow
                let coverRow = (y - coverageBox.y) * coverageBox.width - coverageBox.x
                for x in box.x ..< box.maxX {
                    var mask = coverage == nil ? 255 : Int(cover[coverRow + x])
                    if let clip { mask = (mask * Int(clip.coverage(x: x, y: y)) + 127) / 255 }
                    guard mask > 0 else { continue }
                    let p = row + x * 4
                    let pixel = UnsafeMutableRawPointer(p).loadUnaligned(as: UInt32.self)
                    if pixel == 0, knownOverEmpty[mask] {
                        UnsafeMutableRawPointer(p).storeBytes(of: overEmpty[mask], as: UInt32.self)
                        continue
                    }
                    if pixel == lastIn, mask == lastMask {
                        UnsafeMutableRawPointer(p).storeBytes(of: lastOut, as: UInt32.self)
                        continue
                    }
                    let dr = unit[Int(p[0])], dg = unit[Int(p[1])]
                    let db = unit[Int(p[2])], da = unit[Int(p[3])]
                    let c = unit[mask]
                    p[0] = byte(dr + ((src.r * 1 + dr * keep) - dr) * c)
                    p[1] = byte(dg + ((src.g * 1 + dg * keep) - dg) * c)
                    p[2] = byte(db + ((src.b * 1 + db * keep) - db) * c)
                    p[3] = byte(da + ((src.a * 1 + da * keep) - da) * c)
                    let result = UnsafeMutableRawPointer(p).loadUnaligned(as: UInt32.self)
                    if pixel == 0 {
                        overEmpty[mask] = result
                        knownOverEmpty[mask] = true
                    }
                    lastIn = pixel
                    lastMask = mask
                    lastOut = result
                }
            }
        }
    }

    /// Each byte's value over 255, worked out once: the same values a
    /// division a channel gave, without the divisions.
    private static let unit: [CGFloat] = (0 ... 255).map { CGFloat($0) / 255 }

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    // MARK: Shadows

    /// Blurs a shape's coverage, moves it and paints it in the shadow's
    /// colour — which is all a CoreGraphics shadow is.
    private func castShadow(_ coverage: Coverage, shadow: Shadow) {
        let blurred = BitmapContext.blur(
            coverage.alpha, width: coverage.box.width, height: coverage.box.height,
            sigma: shadow.sigma
        )
        let dx = Int(shadow.offset.width.rounded())
        let dy = Int(shadow.offset.height.rounded())
        let box = PathRasteriser.PixelBox(
            x: coverage.box.x - blurred.margin + dx,
            y: coverage.box.y - blurred.margin + dy,
            width: blurred.width,
            height: blurred.height
        )
        let colour = Premultiplied(shadow.colour, alpha: state.alpha)
        // The shadow itself casts no shadow, and never blends oddly: it is
        // laid down normally under whatever the shape then does.
        let blend = state.blend
        let saved = state.shadow
        state.shadow = nil
        state.blend = .normal
        compositeSolid(box: box.intersection(canvasBox), coverage: blurred.alpha, coverageBox: box, colour: colour)
        state.shadow = saved
        state.blend = blend
    }

    struct Blurred {
        var alpha: [UInt8]
        var width: Int
        var height: Int
        /// How far the buffer grew on every side to hold the spread.
        var margin: Int
    }

    /// Three box blurs, which is the usual stand-in for a Gaussian: the error
    /// after three passes is under a percent, and it costs two adds a pixel
    /// a pass instead of a kernel's worth of multiplies.
    static func blur(_ alpha: [UInt8], width: Int, height: Int, sigma: CGFloat) -> Blurred {
        let radii = boxRadii(sigma: sigma)
        let margin = radii.reduce(0, +)
        guard margin > 0, width > 0, height > 0 else {
            return Blurred(alpha: alpha, width: width, height: height, margin: 0)
        }
        let grownWidth = width + margin * 2
        let grownHeight = height + margin * 2
        var buffer = [UInt16](repeating: 0, count: grownWidth * grownHeight)
        buffer.withUnsafeMutableBufferPointer { out in
            alpha.withUnsafeBufferPointer { from in
                for y in 0 ..< height {
                    let to = (y + margin) * grownWidth + margin, start = y * width
                    for x in 0 ..< width { out[to + x] = UInt16(from[start + x]) }
                }
            }
        }
        var scratch = [UInt16](repeating: 0, count: grownWidth * grownHeight)
        for radius in radii where radius > 0 {
            box(&buffer, into: &scratch, width: grownWidth, height: grownHeight, radius: radius, horizontal: true)
            box(&scratch, into: &buffer, width: grownWidth, height: grownHeight, radius: radius, horizontal: false)
        }
        let result = [UInt8](unsafeUninitializedCapacity: buffer.count) { out, count in
            buffer.withUnsafeBufferPointer { from in
                for i in 0 ..< from.count { out[i] = UInt8(min(255, Int(from[i]))) }
            }
            count = buffer.count
        }
        return Blurred(alpha: result, width: grownWidth, height: grownHeight, margin: margin)
    }

    /// Box widths for three passes that together approximate a Gaussian of
    /// `sigma`, by the standard construction.
    private static func boxRadii(sigma: CGFloat) -> [Int] {
        guard sigma > 0.3 else { return [0, 0, 0] }
        let n = 3.0
        let variance = Double(sigma) * Double(sigma)
        var low = Int((sqrt(12 * variance / n + 1)).rounded(.down))
        if low % 2 == 0 { low -= 1 }
        low = max(1, low)
        let high = low + 2
        let ideal = (12 * variance - n * Double(low * low) - 4 * n * Double(low) - 3 * n)
            / (-4 * Double(low) - 4)
        let m = max(0, min(3, Int(ideal.rounded())))
        return (0 ..< 3).map { ($0 < m ? low : high) / 2 }
    }

    private static func box(
        _ source: inout [UInt16], into destination: inout [UInt16],
        width: Int, height: Int, radius: Int, horizontal: Bool
    ) {
        let span = radius * 2 + 1
        guard horizontal else {
            // Down the columns a row at a time, a running total for each:
            // the same sums as walking each column, in the order memory lies.
            source.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destination in
                var totals = [Int](repeating: 0, count: width)
                totals.withUnsafeMutableBufferPointer { totals in
                    for i in -radius ... radius {
                        let row = min(max(i, 0), height - 1) * width
                        for x in 0 ..< width { totals[x] += Int(source[row + x]) }
                    }
                    for y in 0 ..< height {
                        let row = y * width
                        let leaving = min(max(y - radius, 0), height - 1) * width
                        let arriving = min(max(y + radius + 1, 0), height - 1) * width
                        for x in 0 ..< width {
                            destination[row + x] = UInt16(totals[x] / span)
                            totals[x] += Int(source[arriving + x]) - Int(source[leaving + x])
                        }
                    }
                }
            }
            }
            return
        }
        let outer = horizontal ? height : width
        let inner = horizontal ? width : height
        let step = horizontal ? 1 : width
        source.withUnsafeBufferPointer { source in
        destination.withUnsafeMutableBufferPointer { destination in
        for line in 0 ..< outer {
            let base = horizontal ? line * width : line
            var total = 0
            // Edges clamp, which is right for a shape that has already been
            // given a margin of empty pixels: the clamp only ever repeats 0.
            for i in -radius ... radius {
                total += Int(source[base + min(max(i, 0), inner - 1) * step])
            }
            // Clamped only near the ends; straight through between them.
            let first = min(radius, inner), last = max(first, inner - radius - 1)
            func advance(_ i: Int) {
                destination[base + i * step] = UInt16(total / span)
                let leaving = min(max(i - radius, 0), inner - 1)
                let arriving = min(max(i + radius + 1, 0), inner - 1)
                total += Int(source[base + arriving * step]) - Int(source[base + leaving * step])
            }
            for i in 0 ..< first { advance(i) }
            for i in first ..< last {
                destination[base + i * step] = UInt16(total / span)
                total += Int(source[base + (i + radius + 1) * step]) - Int(source[base + (i - radius) * step])
            }
            for i in last ..< inner { advance(i) }
        }
        }
        }
    }

    // MARK: Blending

    static func blend(_ mode: BlendMode, src: Premultiplied, dst: Premultiplied) -> Premultiplied {
        func mix(_ sf: CGFloat, _ df: CGFloat) -> Premultiplied {
            Premultiplied(
                r: src.r * sf + dst.r * df,
                g: src.g * sf + dst.g * df,
                b: src.b * sf + dst.b * df,
                a: src.a * sf + dst.a * df
            )
        }

        switch mode {
        case .clear: return .clear
        case .copy: return src
        case .sourceIn: return mix(dst.a, 0)
        case .sourceOut: return mix(1 - dst.a, 0)
        case .sourceAtop: return mix(dst.a, 1 - src.a)
        case .destinationOver: return mix(1 - dst.a, 1)
        case .destinationIn: return mix(0, src.a)
        case .destinationOut: return mix(0, 1 - src.a)
        case .destinationAtop: return mix(1 - dst.a, src.a)
        case .xor: return mix(1 - dst.a, 1 - src.a)
        case .multiply, .screen, .overlay, .darken, .lighten,
             .colorDodge, .colorBurn, .hardLight, .softLight,
             .difference, .exclusion:
            return separable(mode, src: src, dst: dst)
        case .hue, .saturation, .color, .luminosity:
            return nonSeparable(mode, src: src, dst: dst)
        case .plusLighter:
            return Premultiplied(r: min(1, src.r + dst.r), g: min(1, src.g + dst.g), b: min(1, src.b + dst.b), a: min(1, src.a + dst.a))
        case .plusDarker:
            // CoreGraphics': R = max(0, 1 − ((1 − D) + (1 − S))), on premultiplied values.
            let a = min(1, src.a + dst.a)
            func channel(_ s: CGFloat, _ d: CGFloat) -> CGFloat { max(0, a - ((src.a - s) + (dst.a - d))) }
            return Premultiplied(r: channel(src.r, dst.r), g: channel(src.g, dst.g), b: channel(src.b, dst.b), a: a)
        default:
            return mix(1, 1 - src.a)
        }
    }

    /// The four non-separable blends, in the PDF/CSS formulation: the
    /// source's hue, saturation or luminosity set into the backdrop's, then
    /// composited source-over.
    private static func nonSeparable(_ mode: BlendMode, src: Premultiplied, dst: Premultiplied) -> Premultiplied {
        typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
        func lum(_ c: RGB) -> CGFloat { 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }
        func clip(_ c: RGB) -> RGB {
            let l = lum(c)
            let n = min(c.r, c.g, c.b), x = max(c.r, c.g, c.b)
            var c = c
            if n < 0 {
                c = (l + (c.r - l) * l / (l - n), l + (c.g - l) * l / (l - n), l + (c.b - l) * l / (l - n))
            }
            if x > 1 {
                c = (l + (c.r - l) * (1 - l) / (x - l), l + (c.g - l) * (1 - l) / (x - l), l + (c.b - l) * (1 - l) / (x - l))
            }
            return c
        }
        func setLum(_ c: RGB, _ l: CGFloat) -> RGB {
            let d = l - lum(c)
            return clip((c.r + d, c.g + d, c.b + d))
        }
        func sat(_ c: RGB) -> CGFloat { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        func setSat(_ c: RGB, _ s: CGFloat) -> RGB {
            let values = [c.r, c.g, c.b]
            let maximum = values.max() ?? 0, minimum = values.min() ?? 0
            guard maximum > minimum else { return (0, 0, 0) }
            func scaled(_ v: CGFloat) -> CGFloat { (v - minimum) * s / (maximum - minimum) }
            return (scaled(c.r), scaled(c.g), scaled(c.b))
        }
        let cs: RGB = src.a > 0 ? (src.r / src.a, src.g / src.a, src.b / src.a) : (0, 0, 0)
        let cb: RGB = dst.a > 0 ? (dst.r / dst.a, dst.g / dst.a, dst.b / dst.a) : (0, 0, 0)
        let blended: RGB
        switch mode {
        case .hue: blended = setLum(setSat(cs, sat(cb)), lum(cb))
        case .saturation: blended = setLum(setSat(cb, sat(cs)), lum(cb))
        case .color: blended = setLum(cs, lum(cb))
        default: blended = setLum(cb, lum(cs))
        }
        func channel(_ sp: CGFloat, _ dp: CGFloat, _ b: CGFloat) -> CGFloat {
            (1 - dst.a) * sp + (1 - src.a) * dp + src.a * dst.a * b
        }
        return Premultiplied(
            r: channel(src.r, dst.r, blended.r),
            g: channel(src.g, dst.g, blended.g),
            b: channel(src.b, dst.b, blended.b),
            a: src.a + dst.a * (1 - src.a)
        )
    }

    /// The separable blends, in the PDF/CSS formulation: blend the colours
    /// unpremultiplied, then composite the result source-over.
    private static func separable(_ mode: BlendMode, src: Premultiplied, dst: Premultiplied) -> Premultiplied {
        func channel(_ sp: CGFloat, _ dp: CGFloat) -> CGFloat {
            let cs = src.a > 0 ? sp / src.a : 0
            let cb = dst.a > 0 ? dp / dst.a : 0
            let blended: CGFloat
            switch mode {
            case .multiply: blended = cs * cb
            case .screen: blended = cs + cb - cs * cb
            case .overlay: blended = cb <= 0.5 ? 2 * cs * cb : 1 - 2 * (1 - cs) * (1 - cb)
            case .darken: blended = min(cs, cb)
            case .lighten: blended = max(cs, cb)
            case .colorDodge: blended = cs >= 1 ? 1 : min(1, cb / (1 - cs))
            case .colorBurn: blended = cs <= 0 ? 0 : 1 - min(1, (1 - cb) / cs)
            case .hardLight: blended = cs <= 0.5 ? 2 * cs * cb : 1 - 2 * (1 - cs) * (1 - cb)
            case .softLight:
                // CoreGraphics' soft light is Pegtop's, not the PDF's
                // (`BlendModeTests` reads it back).
                blended = (1 - 2 * cs) * cb * cb + 2 * cs * cb
            case .difference: blended = abs(cs - cb)
            case .exclusion: blended = cs + cb - 2 * cs * cb
            default: blended = cs
            }
            return (1 - dst.a) * sp + (1 - src.a) * dp + src.a * dst.a * blended
        }
        return Premultiplied(
            r: channel(src.r, dst.r),
            g: channel(src.g, dst.g),
            b: channel(src.b, dst.b),
            a: src.a + dst.a * (1 - src.a)
        )
    }
}

// MARK: - Images

/// A bitmap: CoreGraphics' `CGImage`, as much of it as the game needs.
///
/// Premultiplied RGBA8, row 0 the top. It is a value so a texture can hold
/// one without anybody worrying about who frees it.
public struct RasterImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var bytesPerRow: Int { width * 4 }

    /// Samples at unit coordinates, clamping at the edges.
    func sample(u: CGFloat, v: CGFloat, smooth: Bool) -> BitmapContext.Premultiplied? {
        guard width > 0, height > 0 else { return nil }
        let x = u * CGFloat(width) - 0.5
        let y = v * CGFloat(height) - 0.5
        guard smooth else {
            return at(Int(x.rounded()), Int(y.rounded()))
        }
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - CGFloat(x0), fy = y - CGFloat(y0)
        guard let a = at(x0, y0), let b = at(x0 + 1, y0),
              let c = at(x0, y0 + 1), let d = at(x0 + 1, y0 + 1) else { return nil }
        func lerp(_ p: CGFloat, _ q: CGFloat, _ r: CGFloat, _ s: CGFloat) -> CGFloat {
            let top = p + (q - p) * fx
            let bottom = r + (s - r) * fx
            return top + (bottom - top) * fy
        }
        return BitmapContext.Premultiplied(
            r: lerp(a.r, b.r, c.r, d.r),
            g: lerp(a.g, b.g, c.g, d.g),
            b: lerp(a.b, b.b, c.b, d.b),
            a: lerp(a.a, b.a, c.a, d.a)
        )
    }

    private func at(_ x: Int, _ y: Int) -> BitmapContext.Premultiplied? {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        let i = (cy * width + cx) * 4
        guard i + 3 < pixels.count else { return nil }
        return BitmapContext.Premultiplied(
            r: CGFloat(pixels[i]) / 255,
            g: CGFloat(pixels[i + 1]) / 255,
            b: CGFloat(pixels[i + 2]) / 255,
            a: CGFloat(pixels[i + 3]) / 255
        )
    }
}

// MARK: - Gradients

/// CoreGraphics' `CGGradient`: colours and where they sit along 0...1.
public struct Gradient: Sendable {
    public struct Stop: Sendable {
        public var location: CGFloat
        public var colour: SKColor

        public init(location: CGFloat, colour: SKColor) {
            self.location = location
            self.colour = colour
        }
    }

    public let stops: [Stop]

    /// Evenly spaced when `locations` is nil, as CoreGraphics spaces them.
    public init?(colours: [SKColor], locations: [CGFloat]?) {
        guard !colours.isEmpty else { return nil }
        if let locations, locations.count == colours.count {
            stops = zip(locations, colours).map { Stop(location: $0, colour: $1) }
        } else if colours.count == 1 {
            stops = [Stop(location: 0, colour: colours[0])]
        } else {
            let last = CGFloat(colours.count - 1)
            stops = colours.enumerated().map { Stop(location: CGFloat($0.offset) / last, colour: $0.element) }
        }
    }

    /// The colour at `t`, or nil where the options say not to paint.
    ///
    /// Interpolation is in plain unpremultiplied components, which is what
    /// CoreGraphics does in a device RGB space — a gradient that fades to
    /// clear keeps its hue rather than darkening toward black on the way.
    func sample(at t: CGFloat, options: BitmapContext.GradientOptions) -> BitmapContext.Premultiplied? {
        if t < 0, !options.contains(.drawsBeforeStartLocation) { return nil }
        if t > 1, !options.contains(.drawsAfterEndLocation) { return nil }
        guard let first = stops.first, let last = stops.last else { return nil }
        if t <= first.location { return BitmapContext.Premultiplied(first.colour) }
        if t >= last.location { return BitmapContext.Premultiplied(last.colour) }

        var index = 0
        while index + 1 < stops.count, stops[index + 1].location < t { index += 1 }
        let a = stops[index], b = stops[min(index + 1, stops.count - 1)]
        let span = b.location - a.location
        let f = span > 1e-9 ? (t - a.location) / span : 0
        // As `Premultiplied(SKColor(...))` would, without a colour object a pixel.
        let alpha = max(0, min(1, (a.colour.alpha + (b.colour.alpha - a.colour.alpha) * f) * 1))
        return BitmapContext.Premultiplied(
            r: max(0, min(1, a.colour.red + (b.colour.red - a.colour.red) * f)) * alpha,
            g: max(0, min(1, a.colour.green + (b.colour.green - a.colour.green) * f)) * alpha,
            b: max(0, min(1, a.colour.blue + (b.colour.blue - a.colour.blue) * f)) * alpha,
            a: alpha
        )
    }
}

#endif
