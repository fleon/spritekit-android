import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// The rounded corners of iPhone displays, so round buttons in a screen's
/// corners can stand concentric with them.
public nonisolated enum DisplayCorners {
    /// A display's corner radii (0 for square corners).
    public struct Radii: Equatable, Sendable {
        public var topLeft: CGFloat = 0
        public var topRight: CGFloat = 0
        public var bottomLeft: CGFloat = 0
        public var bottomRight: CGFloat = 0

        public init(topLeft: CGFloat = 0, topRight: CGFloat = 0, bottomLeft: CGFloat = 0, bottomRight: CGFloat = 0) {
            self.topLeft = topLeft
            self.topRight = topRight
            self.bottomLeft = bottomLeft
            self.bottomRight = bottomRight
        }

        /// The same radius at every corner.
        public init(all radius: CGFloat) {
            self.init(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
        }

        /// The corner at `side` (-1 left, 1 right) and `end` (1 top, -1 bottom).
        public func at(side: CGFloat, end: CGFloat) -> CGFloat {
            switch (side < 0, end > 0) {
            case (true, true): topLeft
            case (false, true): topRight
            case (true, false): bottomLeft
            case (false, false): bottomRight
            }
        }

        public func scaled(by scale: CGFloat) -> Radii {
            Radii(topLeft: topLeft * scale, topRight: topRight * scale, bottomLeft: bottomLeft * scale, bottomRight: bottomRight * scale)
        }
    }

    /// Which way the display stands, as the interface turns it: its left
    /// and right corners (as it stands upright) go where turning takes them.
    public enum Turn: Sendable {
        case upright
        case upsideDown
        /// The home indicator on the right (`landscapeLeft`).
        case homeRight
        /// The home indicator on the left (`landscapeRight`).
        case homeLeft
    }

    /// Rounded displays' corner radii in pixels on their left and right, by
    /// native screen size in pixels (portrait), as the simulators' screen
    /// masks draw them (the circle through the middle of each continuous
    /// curve). iPads' corners, 18 to 30 points, are tighter than a corner
    /// button's margin, so they count as square.
    public static let table: [(screen: CGSize, left: CGFloat, right: CGFloat)] = [
        (sz(1125, 2436), 117, 117), // iPhone X, XS, 11 Pro: 39 pt
        (sz(1242, 2688), 117, 117), // iPhone XS Max, 11 Pro Max
        (sz(828, 1792), 83, 83), // iPhone XR, 11: 41.5 pt
        (sz(1080, 2340), 127, 127), // iPhone 12 mini, 13 mini: 44 pt
        (sz(1170, 2532), 142, 142), // iPhone 12, 13, 14, 16e: 47.33 pt
        (sz(1284, 2778), 160, 160), // iPhone 12 Pro Max, 13 Pro Max, 14 Plus: 53.33 pt
        (sz(1179, 2556), 165, 165), // iPhone 14 Pro, 15, 15 Pro, 16: 55 pt
        (sz(1290, 2796), 165, 165), // iPhone 14 Pro Max, 15 Plus, 15 Pro Max, 16 Plus
        (sz(1206, 2622), 186, 186), // iPhone 16 Pro, 17, 17 Pro: 62 pt
        (sz(1320, 2868), 186, 186), // iPhone 16 Pro Max, 17 Pro Max
        (sz(1260, 2736), 195, 195), // iPhone Air: 65 pt
        (sz(1398, 2034), 24, 177), // iPhone Duo, closed: 8 pt at the hinge, 59 pt outside
        (sz(2007, 2853), 165, 165), // iPhone Duo, open: 55 pt
    ]

    /// An unlisted iPhone with a home indicator (a newer model): the latest
    /// models' radius, in points.
    public static let fallbackRadius: CGFloat = 62

    /// The left and right radii, in pixels, of the display `pixels` across,
    /// if it's listed: as given (portrait, as `nativeBounds` is on Apple),
    /// or `eitherWay` round.
    public static func pixelRadii(forScreen pixels: CGSize, eitherWay: Bool = true) -> (left: CGFloat, right: CGFloat)? {
        let screen = eitherWay ? sz(min(pixels.width, pixels.height), max(pixels.width, pixels.height)) : pixels
        return table.first { $0.screen == screen }.map { ($0.left, $0.right) }
    }

    /// The corner radii in points of an iPhone display `pixels` across at
    /// `nativeScale`, turned as it stands; an unlisted one gets the fallback
    /// when it has a home indicator, else square corners.
    public static func radii(forScreen pixels: CGSize, eitherWay: Bool = true, nativeScale: CGFloat, turn: Turn, hasHomeIndicator: Bool) -> Radii {
        guard let entry = pixelRadii(forScreen: pixels, eitherWay: eitherWay) else {
            return Radii(all: hasHomeIndicator ? fallbackRadius : 0)
        }
        let left = entry.left / nativeScale
        let right = entry.right / nativeScale
        switch turn {
        case .homeLeft: return Radii(topLeft: right, topRight: right, bottomLeft: left, bottomRight: left)
        case .homeRight: return Radii(topLeft: left, topRight: left, bottomLeft: right, bottomRight: right)
        case .upsideDown: return Radii(topLeft: right, topRight: left, bottomLeft: right, bottomRight: left)
        case .upright: return Radii(topLeft: left, topRight: right, bottomLeft: left, bottomRight: right)
        }
    }

    /// The corner radii of the display under `view`, in view points (0 for
    /// square corners and iPads), or nil when the view doesn't fill the
    /// screen (or on a TV, which may crop its picture's edges, so
    /// everything stays in the safe area).
    @MainActor public static func radii(of view: UIView) -> Radii? {
        #if os(tvOS)
        return nil
        #else
        guard let window = view.window, let screen = window.windowScene?.screen,
              view.convert(view.bounds, to: nil) == window.bounds,
              window.bounds.size == screen.bounds.size else { return nil }
        guard window.traitCollection.userInterfaceIdiom == .phone else { return Radii() }
        var turn = Turn.upright
        #if os(iOS) || os(Android)
        switch SceneLayout.interfaceOrientation(of: window.windowScene) {
        case .landscapeRight: turn = .homeLeft
        case .landscapeLeft: turn = .homeRight
        case .portraitUpsideDown: turn = .upsideDown
        default: turn = .upright
        }
        #endif
        return radii(forScreen: screen.nativeBounds.size, eitherWay: false, nativeScale: screen.nativeScale, turn: turn, hasHomeIndicator: window.safeAreaInsets.bottom > 0)
        #endif
    }
}
