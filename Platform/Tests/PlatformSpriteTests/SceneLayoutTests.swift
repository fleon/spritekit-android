import Foundation
import Testing
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif
@testable import PlatformSprite

/// The corner and rail maths, checked against the two layouts it was
/// drawn from: one with a camera strip and corners kept as far from the
/// top as from the side, one with a plain rail under the camera.
struct SceneLayoutTests {
    private static let metrics = SceneLayout.Metrics(
        edgeGap: 16, cameraGap: 8, cameraMaxShare: 0.25, railButtonSpacing: 62, railButtonSize: 50,
        screenEdgeInset: 16, headerSafeAreaGap: 8, screenGutter: 20, contentMaxWidth: 560, fallbackSize: sz(402, 874)
    )

    /// Layouts to try: phones upright and turned, square corners, the
    /// closed Duo's camera strip on either side, a camera at the top.
    private static var cases: [SceneLayout] {
        let phone = rect(402, 874).anchor(0.5)
        let wide = rect(874, 402).anchor(0.5)
        let duo = rect(466, 678).anchor(0.5)
        let camera = rect(duo.maxX - 30, duo.maxY - 46, 22, 22)
        let duoTurned = rect(678, 466).anchor(0.5)
        let cameraTurned = rect(duoTurned.minX + 10, duoTurned.maxY - 34, 22, 22)
        let radii = DisplayCorners.Radii(all: 62)
        let tight = DisplayCorners.Radii(topLeft: 8, topRight: 59, bottomLeft: 8, bottomRight: 59)
        return [
            SceneLayout(visibleRect: phone, safeRect: phone.inset(by: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)), cornerRect: phone, cornerRadii: radii, metrics: metrics),
            SceneLayout(visibleRect: wide, safeRect: wide.inset(by: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)), housingSide: 1, cornerRect: wide, cornerRadii: radii, metrics: metrics),
            SceneLayout(visibleRect: phone, safeRect: phone, metrics: metrics),
            SceneLayout(
                visibleRect: duo, safeRect: duo.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 52)), cornerRect: duo,
                cornerRadii: tight, stripSide: 1, occlusions: [camera], metrics: metrics
            ),
            SceneLayout(
                visibleRect: duoTurned, safeRect: duoTurned.inset(by: UIEdgeInsets(top: 0, left: 52, bottom: 20, right: 0)), housingSide: -1,
                cornerRect: duoTurned, cornerRadii: tight, stripSide: -1, occlusions: [cameraTurned], metrics: metrics
            ),
            SceneLayout(visibleRect: phone, safeRect: phone, cornerRect: phone, cornerRadii: radii, occlusions: [rect(-20, phone.maxY - 40, 40, 30)], metrics: metrics),
        ]
    }

    @Test func cornersAndRailMatchTheStripLayout() {
        for layout in Self.cases {
            let reference = StripLayout(layout, metrics: Self.metrics)
            for size: CGFloat in [44, 50, 60] {
                for side: CGFloat in [-1, 1] {
                    for end: CGFloat in [-1, 1] {
                        #expect(layout.cornerButtonCenter(side: side, end: end, size: size) == reference.cornerButtonCenter(side: side, end: end, size: size))
                        #expect(layout.cornerY(side: side, end: end, size: size) == reference.cornerY(side: side, end: end, size: size))
                    }
                    for clears in [false, true] {
                        #expect(layout.edgeButtonX(side: side, size: size, clearsHousing: clears) == reference.edgeButtonX(side: side, size: size, clearsHousing: clears))
                    }
                }
                for index in 0..<3 {
                    #expect(layout.railButtonCenter(fromTop: index, size: size) == reference.railButtonCenter(fromTop: index, size: size))
                    #expect(layout.railButtonCenter(fromBottom: index, size: size) == reference.railButtonCenter(fromBottom: index, size: size))
                }
                #expect(layout.headerMiddleY(height: 30, buttonSize: size) == reference.headerMiddleY(height: 30, buttonSize: size))
            }
            #expect(layout.contentRect == reference.contentRect)
            #expect(layout.hasRail == reference.hasRail)
            #expect(layout.contentTop == reference.contentTop)
            #expect(layout.contentBottom == reference.contentBottom)
        }
    }

    @Test func topCornersAndRailMatchThePlainRailLayout() {
        let pointScale: CGFloat = 0.8
        var metrics = Self.metrics
        metrics.edgeGap = 10
        metrics.scalesEdgeGap = true
        metrics.keepsSideDistance = false
        metrics.clearsCameraWithinGap = false
        for base in Self.cases {
            let layout = SceneLayout(
                visibleRect: base.visibleRect, safeRect: base.safeRect, cornerRect: base.cornerRect, cornerRadii: base.cornerRadii,
                stripSide: base.occlusions.isEmpty ? nil : 1, occlusions: base.occlusions, pointScale: pointScale, metrics: metrics
            )
            let reference = PlainRailLayout(
                cornerRect: base.cornerRect, left: base.cornerRadii.topLeft, right: base.cornerRadii.topRight,
                pointScale: pointScale, occlusions: base.occlusions, padding: 10, gap: 8, spacing: 62
            )
            for size: CGFloat in [44, 50] {
                if base.occlusions.isEmpty {
                    #expect(layout.cornerButtonCenter(side: -1, end: 1, size: size) == reference.cornerButtonCenter(left: true, size: size))
                    #expect(layout.cornerButtonCenter(side: 1, end: 1, size: size) == reference.cornerButtonCenter(left: false, size: size))
                } else {
                    for index in 0..<3 {
                        #expect(layout.railButtonCenter(fromTop: index, size: size) == reference.railButtonCenter(index: index, size: size))
                    }
                }
            }
        }
    }

    @Test func columnsSplitAtTheFold() {
        let screen = rect(800, 600).anchor(0.5)
        let plain = SceneLayout(visibleRect: screen, safeRect: screen)
        #expect(plain.columns.left == rect(-400, -300, 400, 600))
        let folded = SceneLayout(visibleRect: screen, safeRect: screen, division: rect(-10, -300, 20, 600))
        #expect(folded.columns.left.maxX == -10)
        #expect(folded.columns.right.minX == 10)
    }

    @Test func aSceneWithNoViewLaysOutForItsPlan() {
        let saved = SceneLayout.metrics
        defer { SceneLayout.metrics = saved }
        SceneLayout.metrics = Self.metrics
        let scene = PlannedScene(size: sz(402, 874))
        #expect(SceneLayout(scene: scene).visibleRect == rect(402, 874).anchor(0.5))
        let planned = SceneLayout(visibleRect: rect(100, 200), safeRect: rect(100, 200))
        scene.plannedLayout = planned
        #expect(SceneLayout(scene: scene) == planned)
    }
}

private final class PlannedScene: SKScene, LoadableScene {
    var plannedLayout: SceneLayout?
    func load() {}
}

/// The layout with a camera strip, as it stood before it moved here.
private struct StripLayout {
    let visibleRect: CGRect, safeRect: CGRect, housingSide: CGFloat?, cornerRect: CGRect
    let cornerRadii: DisplayCorners.Radii, stripSide: CGFloat?, occlusions: [CGRect]
    let edgeGap: CGFloat, cameraGap: CGFloat, railButtonSpacing: CGFloat, headerButtonSize: CGFloat
    let screenEdgeInset: CGFloat, headerSafeAreaGap: CGFloat

    init(_ layout: SceneLayout, metrics: SceneLayout.Metrics) {
        visibleRect = layout.visibleRect
        safeRect = layout.safeRect
        housingSide = layout.housingSide
        cornerRect = layout.cornerRect
        cornerRadii = layout.cornerRadii
        stripSide = layout.stripSide
        occlusions = layout.occlusions
        edgeGap = metrics.edgeGap
        cameraGap = metrics.cameraGap
        railButtonSpacing = metrics.railButtonSpacing
        headerButtonSize = metrics.railButtonSize
        screenEdgeInset = metrics.screenEdgeInset
        headerSafeAreaGap = metrics.headerSafeAreaGap
    }

    var hasRail: Bool { stripSide != nil && !isLandscape }
    var contentRect: CGRect {
        guard hasRail else { return safeRect }
        let maxX = min(safeRect.maxX, railX - headerButtonSize / 2)
        return rect(safeRect.minX, safeRect.minY, maxX - safeRect.minX, safeRect.height)
    }
    var contentTop: CGFloat { min(safeRect.maxY, visibleRect.maxY - screenEdgeInset) }
    var contentBottom: CGFloat { max(safeRect.minY, visibleRect.minY + screenEdgeInset) }
    var isLandscape: Bool { visibleRect.width > visibleRect.height }
    func edgeX(side: CGFloat, clearsHousing: Bool) -> CGFloat {
        if clearsHousing && housingSide == side { return side < 0 ? safeRect.minX : safeRect.maxX }
        return side < 0 ? cornerRect.minX + edgeGap : cornerRect.maxX - edgeGap
    }
    func edgeButtonX(side: CGFloat, size: CGFloat, clearsHousing: Bool) -> CGFloat {
        stripColumnX(side: side) ?? edgeX(side: side, clearsHousing: clearsHousing) - side * size / 2
    }
    private func cornerInset(side: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
        max(cornerRadii.at(side: side, end: end), size / 2 + edgeGap)
    }
    private func cornerX(side: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
        let inset = cornerInset(side: side, end: end, size: size)
        return stripColumnX(side: side) ?? (side < 0 ? cornerRect.minX + inset : cornerRect.maxX - inset)
    }
    func cornerY(side: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
        let x = cornerX(side: side, end: end, size: size)
        let inset = max(cornerInset(side: side, end: end, size: size), side < 0 ? x - cornerRect.minX : cornerRect.maxX - x)
        return end > 0 ? cornerRect.maxY - inset : cornerRect.minY + inset
    }
    func cornerButtonCenter(side: CGFloat, end: CGFloat, size: CGFloat) -> CGPoint {
        let x = cornerX(side: side, end: end, size: size)
        return pt(x, clearOfCamera(cornerY(side: side, end: end, size: size), x: x, end: end, size: size))
    }
    private var camera: CGRect? { occlusions.min { $0.width * $0.height < $1.width * $1.height } }
    private func stripColumnX(side: CGFloat) -> CGFloat? {
        guard let stripSide, let camera else { return nil }
        let inset = stripSide < 0 ? camera.midX - cornerRect.minX : cornerRect.maxX - camera.midX
        return side < 0 ? cornerRect.minX + inset : cornerRect.maxX - inset
    }
    private func clearOfCamera(_ y: CGFloat, x: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
        let reach = size / 2 + cameraGap
        var cleared = y
        for camera in occlusions where camera.minX < x + size / 2 && camera.maxX > x - size / 2 {
            if end > 0, camera.maxY > y - reach {
                cleared = min(cleared, camera.minY - reach)
            } else if end < 0, camera.minY < y + reach {
                cleared = max(cleared, camera.maxY + reach)
            }
        }
        return cleared
    }
    func headerMiddleY(height: CGFloat, buttonSize: CGFloat) -> CGFloat {
        let top = safeRect.maxY < visibleRect.maxY ? min(contentTop, safeRect.maxY - headerSafeAreaGap) : contentTop
        return min(cornerY(side: -1, end: 1, size: buttonSize), top - height / 2)
    }
    private var railX: CGFloat {
        stripColumnX(side: 1) ?? cornerButtonCenter(side: 1, end: 1, size: headerButtonSize).x
    }
    func railButtonCenter(fromTop index: Int, size: CGFloat) -> CGPoint {
        cornerButtonCenter(side: 1, end: 1, size: size).offset(0, -CGFloat(index) * railButtonSpacing)
    }
    func railButtonCenter(fromBottom index: Int, size: CGFloat) -> CGPoint {
        cornerButtonCenter(side: 1, end: -1, size: size).offset(0, CGFloat(index) * railButtonSpacing)
    }
}

/// The layout with top corners and a plain rail under the camera, as it
/// stands in the game it comes from.
private struct PlainRailLayout {
    let cornerRect: CGRect, left: CGFloat, right: CGFloat, pointScale: CGFloat, occlusions: [CGRect]
    let padding: CGFloat, gap: CGFloat, spacing: CGFloat

    func cornerButtonCenter(left isLeft: Bool, size: CGFloat) -> CGPoint {
        let radius = isLeft ? left : right
        let inset = max(radius, size / 2 + padding * pointScale)
        let x = isLeft ? cornerRect.minX + inset : cornerRect.maxX - inset
        return pt(x, clearedY(cornerRect.maxY - inset, x: x, size: size))
    }

    func railButtonCenter(index: Int, size: CGFloat) -> CGPoint {
        let corner = cornerButtonCenter(left: false, size: size)
        let camera = occlusions.min { $0.width * $0.height < $1.width * $1.height }
        let x = camera?.midX ?? corner.x
        let top = clearedY(corner.y, x: x, size: size)
        return pt(x, top - CGFloat(index) * spacing)
    }

    private func clearedY(_ y: CGFloat, x: CGFloat, size: CGFloat) -> CGFloat {
        let halfSize = size / 2
        let lowestEdge = occlusions
            .filter { $0.minX < x + halfSize && $0.maxX > x - halfSize && $0.maxY > y - halfSize }
            .map(\.minY)
            .min()
        guard let lowestEdge else { return y }
        return min(y, lowestEdge - gap - halfSize)
    }
}
