#if targetEnvironment(macCatalyst)
import PlatformCore
import SpriteKit
import UIKit

/// On the Mac the control under the pointer shows focus as the Apple TV
/// remote's does (`Focusable`). It checks again as controls come and go
/// beneath a still pointer.
public final class HoverFocus: NSObject {
    /// The pointer moved (taking focus back from a gamepad).
    public var onMove: (() -> Void)?
    /// A gamepad drives focus: the pointer shows none till it's given back.
    public var isSuspended = false {
        didSet { refresh() }
    }
    private weak var view: SKView?
    private weak var hovered: SKNode?
    /// Where the pointer rests in the view, while it's over it.
    private var location: CGPoint?
    private var timer: Timer?

    /// `pointer`: where the pointer starts, in view points, before it
    /// moves (a test run may place it).
    public init(view: SKView, pointer: CGPoint? = nil) {
        self.view = view
        location = pointer
        super.init()
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
        timer = Timer.scheduledTimer(withTimeInterval: FocusNavigator.configuration.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            location = gesture.location(in: view)
        default:
            location = nil
        }
        onMove?()
        refresh()
    }

    private func refresh() {
        guard !isSuspended, let view, let scene = view.scene, let location else {
            setHovered(nil)
            return
        }
        // The smallest control under the pointer, should two overlap.
        let control = SceneControls.collect(in: scene, bounds: view.bounds)
            .filter { !$0.isScrolledOut && $0.frame.contains(location) && ($0.node as? any Focusable)?.canFocus == true }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        setHovered(control?.node)
    }

    private func setHovered(_ node: SKNode?) {
        guard node !== hovered else { return }
        (hovered as? any Focusable)?.setFocused(false)
        hovered = node
        (node as? any Focusable)?.setFocused(true)
    }
}
#endif
