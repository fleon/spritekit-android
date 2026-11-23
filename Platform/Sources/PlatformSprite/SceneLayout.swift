import Foundation
import SpriteKitShim

/// Where content can go in a scene. Scenes have a fixed design height and a
/// wide canvas shown with aspect fill, so the visible width depends on the
/// device; all layout reads from here instead of the scene size.
///
/// It knows the safe area, the display's rounded corners (`DisplayCorners`),
/// a camera housing's side in landscape and a camera occluding the screen
/// (the closed iPhone Duo's, iOS 27.1's `reservedRegions`), and stands round
/// buttons in the corners concentric with them, or in a rail down a camera
/// strip. The sizes it keeps are the game's (`Metrics`).
public struct SceneLayout: Equatable {
    /// A game's sizes for its layout, in scene points.
    public struct Metrics: Equatable {
        /// How far what stands along the screen's edges keeps clear of them
        /// where corners are square (0 on a TV, whose safe area is the edge).
        public var edgeGap: CGFloat
        /// `edgeGap` is in screen points, scaled into the scene
        /// (`pointScale`), rather than in scene points.
        public var scalesEdgeGap = false
        /// How far round buttons keep from a camera.
        public var cameraGap: CGFloat
        /// A camera within `cameraGap` below a button's top pushes it too,
        /// not only one reaching past its middle.
        public var clearsCameraWithinGap = true
        /// What counts as a camera: an occluded region narrower and shorter
        /// than this share of the view, not a band along an edge.
        public var cameraMaxShare: CGFloat
        /// A corner button keeps as far from the top or bottom as from the
        /// side (the closed Duo's tight hinge corners), not only as far as
        /// its corner's curve asks.
        public var keepsSideDistance = true
        /// How far apart the rail's round buttons step.
        public var railButtonSpacing: CGFloat
        /// The round buttons the rail is placed by and leaves room for.
        public var railButtonSize: CGFloat
        /// How far content keeps from the screen's top and bottom edges.
        public var screenEdgeInset: CGFloat
        /// How far below the safe area's top what stands across the middle
        /// of the top keeps, when standing level with the corner buttons
        /// would bring it nearer.
        public var headerSafeAreaGap: CGFloat
        /// The gutter each side of the central content column, and its widest.
        public var screenGutter: CGFloat
        public var contentMaxWidth: CGFloat
        /// The rect a scene lays out in before it has a view or a planned layout.
        public var fallbackSize: CGSize

        public init(
            edgeGap: CGFloat,
            scalesEdgeGap: Bool = false,
            cameraGap: CGFloat,
            clearsCameraWithinGap: Bool = true,
            cameraMaxShare: CGFloat,
            keepsSideDistance: Bool = true,
            railButtonSpacing: CGFloat,
            railButtonSize: CGFloat,
            screenEdgeInset: CGFloat,
            headerSafeAreaGap: CGFloat,
            screenGutter: CGFloat,
            contentMaxWidth: CGFloat,
            fallbackSize: CGSize
        ) {
            self.edgeGap = edgeGap
            self.scalesEdgeGap = scalesEdgeGap
            self.cameraGap = cameraGap
            self.clearsCameraWithinGap = clearsCameraWithinGap
            self.cameraMaxShare = cameraMaxShare
            self.keepsSideDistance = keepsSideDistance
            self.railButtonSpacing = railButtonSpacing
            self.railButtonSize = railButtonSize
            self.screenEdgeInset = screenEdgeInset
            self.headerSafeAreaGap = headerSafeAreaGap
            self.screenGutter = screenGutter
            self.contentMaxWidth = contentMaxWidth
            self.fallbackSize = fallbackSize
        }
    }

    /// The game's metrics, which every layout made from here on takes. Set
    /// it once, before the first scene lays out.
    public nonisolated(unsafe) static var metrics = Metrics(
        edgeGap: 16, cameraGap: 8, cameraMaxShare: 0.25, railButtonSpacing: 60, railButtonSize: 44,
        screenEdgeInset: 16, headerSafeAreaGap: 8, screenGutter: 20, contentMaxWidth: .infinity, fallbackSize: sz(390, 844)
    )

    /// A display's corner radii, in scene points (0 for square corners).
    public typealias CornerRadii = DisplayCorners.Radii

    /// The part of the scene the view shows.
    public let visibleRect: CGRect
    /// The visible rect minus the safe-area insets.
    public let safeRect: CGRect
    /// In landscape, the side holding the camera housing (-1 left, 1 right);
    /// nil upright or without one.
    public let housingSide: CGFloat?
    /// What the corner buttons stand in: the whole visible rect when the
    /// view fills the screen (the status bar hidden, so only a notch or
    /// Dynamic Island, along the middle of an edge, shares the corners'
    /// margins), else the safe rect (a window beside others, whose corners
    /// may hold the window's controls).
    public let cornerRect: CGRect
    /// The display's corner radii (the closed Duo's are tight at its hinge).
    public let cornerRadii: CornerRadii
    /// The closed iPhone Duo's camera strip: the side (-1 left, 1 right)
    /// whose safe-area inset holds the camera in one of its corners, the
    /// right upright and the camera's side turned sideways. The round buttons
    /// on that side stand in the strip, centred on the camera, and those on
    /// the other side as far from their edge.
    public let stripSide: CGFloat?
    /// The screen's occluded regions the size of a camera, in the scene.
    public let occlusions: [CGRect]
    /// Where a folding screen divides in two, in the scene, if it does.
    public let division: CGRect?
    /// Scene points per view point.
    public let pointScale: CGFloat
    public let metrics: Metrics

    public init(
        visibleRect: CGRect,
        safeRect: CGRect,
        housingSide: CGFloat? = nil,
        cornerRect: CGRect? = nil,
        cornerRadii: CornerRadii = CornerRadii(),
        stripSide: CGFloat? = nil,
        occlusions: [CGRect] = [],
        division: CGRect? = nil,
        pointScale: CGFloat = 1,
        metrics: Metrics = SceneLayout.metrics
    ) {
        self.visibleRect = visibleRect
        self.safeRect = safeRect
        self.housingSide = housingSide
        self.cornerRect = cornerRect ?? safeRect
        self.cornerRadii = cornerRadii
        self.stripSide = stripSide
        self.occlusions = occlusions
        self.division = division
        self.pointScale = pointScale
        self.metrics = metrics
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// The screen's occluded regions (a camera) and divisions (a fold) in
    /// the scenes' view, read at each of its layout passes rather than every
    /// frame. UIKit settles them a pass after a fold; scenes lay out again then.
    private static var occludedRegions: [CGRect] = []
    private static var divisions: [CGRect] = []
    #endif

    /// Call from each layout pass of the view the scenes show in.
    public static func viewDidLayout(_ view: UIView) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard #available(iOS 27.1, *) else { return }
        occludedRegions = view.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
        divisions = view.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
        #endif
    }

    /// What a scene's layout is worked out from, cheap to read every frame:
    /// a scene lays out again only once one of them changes.
    public struct Inputs: Equatable {
        private let bounds: CGRect
        private let insets: UIEdgeInsets
        private let sceneSize: CGSize
        #if os(iOS) || os(Android)
        private let orientation: UIInterfaceOrientation?
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst)
        private let occluded: [CGRect]
        private let divisions: [CGRect]
        #endif

        /// Nil before the scene shows, while it lays out for the view it's headed to.
        public init?(scene: SKScene) {
            guard let view = scene.view, view.bounds.width > 0 else { return nil }
            bounds = view.bounds
            insets = view.safeAreaInsets
            sceneSize = scene.size
            #if os(iOS) || os(Android)
            orientation = SceneLayout.interfaceOrientation(of: view.window?.windowScene)
            #endif
            #if os(iOS) && !targetEnvironment(macCatalyst)
            occluded = SceneLayout.occludedRegions
            divisions = SceneLayout.divisions
            #endif
        }
    }

    /// `scene`'s layout if it differs from `applied`, checked only once what
    /// it's worked out from has changed since `inputs` (kept here), or when
    /// nothing is applied; nil otherwise.
    public static func changed(in scene: SKScene, since inputs: inout Inputs?, applied: SceneLayout?) -> SceneLayout? {
        let current = Inputs(scene: scene)
        guard applied == nil || current == nil || current != inputs else { return nil }
        inputs = current
        let layout = SceneLayout(scene: scene)
        return layout == applied ? nil : layout
    }

    public init(scene: SKScene) {
        let metrics = Self.metrics
        guard let view = scene.view, view.bounds.width > 0 else {
            // A scene built before it shows lays out for the view it's headed to.
            if let planned = (scene as? LoadableScene)?.plannedLayout {
                self = planned
                return
            }
            let fallback = rect(metrics.fallbackSize).anchor(0.5)
            self.init(visibleRect: fallback, safeRect: fallback)
            return
        }
        let insets = view.safeAreaInsets
        let bounds = view.bounds
        func sceneRect(for viewRect: CGRect) -> CGRect {
            let corners = [
                pt(viewRect.minX, viewRect.minY),
                pt(viewRect.maxX, viewRect.maxY),
            ].map(scene.convertPoint(fromView:))
            let minX = min(corners[0].x, corners[1].x)
            let maxX = max(corners[0].x, corners[1].x)
            let minY = min(corners[0].y, corners[1].y)
            let maxY = max(corners[0].y, corners[1].y)
            return rect(minX, minY, maxX - minX, maxY - minY)
        }
        // The housing is at the device's top, opposite where a home button was.
        var housingSide: CGFloat?
        #if os(iOS) || os(Android)
        if insets.left > 0 || insets.right > 0 {
            switch Self.interfaceOrientation(of: view.window?.windowScene) {
            case .landscapeLeft: housingSide = 1
            case .landscapeRight: housingSide = -1
            default: housingSide = nil
            }
        }
        #endif
        var stripSide: CGFloat?
        var occlusions: [CGRect] = []
        var division: CGRect?
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // A camera, not a band along an edge.
        let cameras = Self.occludedRegions
            .filter { $0.width < bounds.width * metrics.cameraMaxShare && $0.height < bounds.height * metrics.cameraMaxShare }
        occlusions = cameras.map(sceneRect(for:))
        division = Self.divisions.first.map(sceneRect(for:))
        if view.traitCollection.userInterfaceIdiom == .phone {
            if bounds.height > bounds.width {
                if insets.right > 0 { stripSide = 1 }
            } else if let side = housingSide, let camera = cameras.min(by: { $0.width * $0.height < $1.width * $1.height }) {
                // Turned, the camera keeps to a corner of its side's inset,
                // where a Dynamic Island takes the middle.
                let band = side < 0 ? insets.left : insets.right
                let inBand = side < 0 ? camera.midX < band : camera.midX > bounds.width - band
                if inBand && min(camera.midY, bounds.height - camera.midY) < band { stripSide = side }
            }
        }
        #endif
        let visibleRect = sceneRect(for: bounds)
        let safeRect = sceneRect(for: bounds.inset(by: insets))
        let radii = DisplayCorners.radii(of: view)
        let pointScale = visibleRect.height / bounds.height
        self.init(
            visibleRect: visibleRect,
            safeRect: safeRect,
            housingSide: housingSide,
            cornerRect: radii == nil ? safeRect : visibleRect,
            cornerRadii: (radii ?? CornerRadii()).scaled(by: pointScale),
            stripSide: stripSide,
            occlusions: occlusions,
            division: division,
            pointScale: pointScale,
            metrics: metrics
        )
    }

    #if os(iOS) || os(Android)
    static func interfaceOrientation(of scene: UIWindowScene?) -> UIInterfaceOrientation? {
        guard #available(iOS 16.0, *) else { return nil }
        return scene?.effectiveGeometry.interfaceOrientation
    }
    #endif

    /// Whether `scene` has been sized for its view yet. As the screen turns,
    /// the view's bounds change a moment before the scene follows, and a
    /// layout read in between describes neither shape.
    public static func isSettled(_ scene: SKScene) -> Bool {
        guard let view = scene.view, view.bounds.width > 0 else { return true }
        return scene.size == TransitionManager.sceneSize(view.bounds.size)
    }

    /// The closed Duo upright: every round button stands in a rail down its
    /// camera strip, and content centres in the space the rail leaves.
    public var hasRail: Bool {
        stripSide != nil && !isLandscape
    }

    /// Where content centres: the safe rect, short of the rail's buttons on
    /// the closed Duo.
    public var contentRect: CGRect {
        guard hasRail else { return safeRect }
        let maxX = min(safeRect.maxX, railX - metrics.railButtonSize / 2)
        return rect(safeRect.minX, safeRect.minY, maxX - safeRect.minX, safeRect.height)
    }

    /// The width of the central content column.
    public func contentWidth(maximum: CGFloat? = nil) -> CGFloat {
        min(contentRect.width - metrics.screenGutter * 2, maximum ?? metrics.contentMaxWidth)
    }

    /// Top edge for content, keeping clear of the notch and the screen edge.
    public var contentTop: CGFloat {
        min(safeRect.maxY, visibleRect.maxY - metrics.screenEdgeInset)
    }

    /// Bottom edge for content, keeping clear of the home indicator.
    public var contentBottom: CGFloat {
        max(safeRect.minY, visibleRect.minY + metrics.screenEdgeInset)
    }

    /// Wider than tall: screens lay out side by side.
    public var isLandscape: Bool {
        visibleRect.width > visibleRect.height
    }

    /// The two halves of a landscape screen, either side of its fold (or
    /// of its middle).
    public var columns: (left: CGRect, right: CGRect) {
        let leftMaxX = division?.minX ?? visibleRect.midX
        let rightMinX = division?.maxX ?? visibleRect.midX
        return (
            rect(visibleRect.minX, visibleRect.minY, leftMaxX - visibleRect.minX, visibleRect.height),
            rect(rightMinX, visibleRect.minY, visibleRect.maxX - rightMinX, visibleRect.height)
        )
    }

    private var edgeGap: CGFloat {
        metrics.scalesEdgeGap ? metrics.edgeGap * pointScale : metrics.edgeGap
    }

    /// Landscape's edge columns reach past the safe area into the margins
    /// (where the corner buttons stand), to `edgeGap` from the screen's
    /// edge. `clearsHousing` keeps one inside the safe area on the camera
    /// housing's side, for anything along the middle of that edge. `side`
    /// is -1 for left, 1 for right.
    public func edgeX(side: CGFloat, clearsHousing: Bool) -> CGFloat {
        if clearsHousing && housingSide == side {
            return side < 0 ? safeRect.minX : safeRect.maxX
        }
        return side < 0 ? cornerRect.minX + edgeGap : cornerRect.maxX - edgeGap
    }

    /// The centre of a round button of `size` standing at that edge (on the
    /// closed Duo, in its button column there).
    public func edgeButtonX(side: CGFloat, size: CGFloat, clearsHousing: Bool) -> CGFloat {
        stripColumnX(side: side) ?? edgeX(side: side, clearsHousing: clearsHousing) - side * size / 2
    }

    /// How far the centre of a round button of `size` in a corner sits in
    /// from both edges: concentric with the display's rounded corner, so
    /// the gap to its curve is even, or `edgeGap` clear of the edges where
    /// the corner is tighter than that (or square).
    private func cornerInset(side: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
        max(cornerRadii.at(side: side, end: end), size / 2 + edgeGap)
    }

    /// Where a round button of `size` in a corner stands across: in the
    /// closed Duo's button column on that side, else concentric with the corner.
    private func cornerX(side: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
        let inset = cornerInset(side: side, end: end, size: size)
        return stripColumnX(side: side) ?? (side < 0 ? cornerRect.minX + inset : cornerRect.maxX - inset)
    }

    /// The height of a round button of `size` in a corner, before a camera
    /// there moves it: concentric with the corner, but (`keepsSideDistance`)
    /// never nearer the top or bottom than the side.
    public func cornerY(side: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
        let x = cornerX(side: side, end: end, size: size)
        var inset = cornerInset(side: side, end: end, size: size)
        if metrics.keepsSideDistance {
            inset = max(inset, side < 0 ? x - cornerRect.minX : cornerRect.maxX - x)
        }
        return end > 0 ? cornerRect.maxY - inset : cornerRect.minY + inset
    }

    /// The centre of a round button of `size` in a corner, out past the
    /// safe area (back, home, settings): `side` -1 left or 1 right, `end` 1
    /// top or -1 bottom. On the closed Duo it stands in the button column
    /// on that side, moving along it clear of the camera.
    public func cornerButtonCenter(side: CGFloat, end: CGFloat, size: CGFloat) -> CGPoint {
        let x = cornerX(side: side, end: end, size: size)
        return pt(x, clearOfCamera(cornerY(side: side, end: end, size: size), x: x, end: end, size: size))
    }

    /// The camera: the smallest occluded region.
    private var camera: CGRect? {
        occlusions.min { $0.width * $0.height < $1.width * $1.height }
    }

    /// Where the closed Duo's round buttons stand on `side`: centred on the
    /// camera on its strip's side, and as far from the edge on the other.
    private func stripColumnX(side: CGFloat) -> CGFloat? {
        guard let stripSide, let camera else { return nil }
        let inset = stripSide < 0 ? camera.midX - cornerRect.minX : cornerRect.maxX - camera.midX
        return side < 0 ? cornerRect.minX + inset : cornerRect.maxX - inset
    }

    /// `y`, or further from its `end` of the screen (1 top, -1 bottom) if a
    /// round button of `size` at `x` would reach within `cameraGap` of a
    /// camera there.
    private func clearOfCamera(_ y: CGFloat, x: CGFloat, end: CGFloat, size: CGFloat) -> CGFloat {
        let reach = size / 2 + metrics.cameraGap
        let near = metrics.clearsCameraWithinGap ? reach : size / 2
        var cleared = y
        for camera in occlusions where camera.minX < x + size / 2 && camera.maxX > x - size / 2 {
            if end > 0, camera.maxY > y - near {
                cleared = min(cleared, camera.minY - reach)
            } else if end < 0, camera.minY < y + near {
                cleared = max(cleared, camera.maxY + reach)
            }
        }
        return cleared
    }

    /// The centre of something `height` tall across the middle of the top,
    /// level with corner buttons of `buttonSize` unless that would bring it
    /// within `headerSafeAreaGap` of the safe area's top, under a notch,
    /// Dynamic Island or camera (a screen whose safe area reaches its top
    /// keeps `contentTop`).
    public func headerMiddleY(height: CGFloat, buttonSize: CGFloat) -> CGFloat {
        let top = safeRect.maxY < visibleRect.maxY ? min(contentTop, safeRect.maxY - metrics.headerSafeAreaGap) : contentTop
        return min(cornerY(side: -1, end: 1, size: buttonSize), top - height / 2)
    }

    /// The closed Duo's rail: the column its round buttons stand in, centred
    /// under the camera (or, without one, under a top-right corner button).
    private var railX: CGFloat {
        stripColumnX(side: 1) ?? cornerButtonCenter(side: 1, end: 1, size: metrics.railButtonSize).x
    }

    /// The centre of the round button of `size` `index` places down the
    /// rail from its top: level with the top-right corner, or below the
    /// camera if that's lower.
    public func railButtonCenter(fromTop index: Int, size: CGFloat) -> CGPoint {
        cornerButtonCenter(side: 1, end: 1, size: size).offset(0, -CGFloat(index) * metrics.railButtonSpacing)
    }

    /// The centre of the round button of `size` `index` places up the rail
    /// from its foot: level with the bottom-right corner.
    public func railButtonCenter(fromBottom index: Int, size: CGFloat) -> CGPoint {
        cornerButtonCenter(side: 1, end: -1, size: size).offset(0, CGFloat(index) * metrics.railButtonSpacing)
    }
}

extension SceneLayout {
    /// `edgeX(side:clearsHousing:)` by reading order: the leading edge is
    /// the left in a left-to-right language and the right in a
    /// right-to-left one.
    public func edgeX(_ edge: HorizontalEdge, clearsHousing: Bool, direction: LayoutDirection = .current) -> CGFloat {
        edgeX(side: direction.side(edge), clearsHousing: clearsHousing)
    }

    /// `edgeButtonX(side:size:clearsHousing:)` by reading order.
    public func edgeButtonX(_ edge: HorizontalEdge, size: CGFloat, clearsHousing: Bool, direction: LayoutDirection = .current) -> CGFloat {
        edgeButtonX(side: direction.side(edge), size: size, clearsHousing: clearsHousing)
    }

    /// `cornerButtonCenter(side:end:size:)` by reading order: a back button
    /// stands in the leading top corner.
    public func cornerButtonCenter(_ edge: HorizontalEdge, end: CGFloat, size: CGFloat, direction: LayoutDirection = .current) -> CGPoint {
        cornerButtonCenter(side: direction.side(edge), end: end, size: size)
    }
}
