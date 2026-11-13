import SpriteKit
import UIKit

// The protocols and helpers `Source/GameViewController.swift` declares beside
// the Apple view controller, copied verbatim: that file is the Apple app's own
// controller (gesture recognisers, presses, `loadView`) and cannot compile
// here, but the scenes conform to these and call these, so they must be the
// game's own shapes. `AndroidGameController` beside this file is what stands
// where `GameViewController` does. Keep the two in step.

/// Scenes that respond to a hardware keyboard (iPad, Mac, simulator). The
/// Apple TV remote's Back button reaches them as Escape.
protocol KeyboardControllable: AnyObject {
    func handleKey(_ keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool
}

/// Scenes that take `-TouchScript`'s taps as touches (at a point in the scene).
protocol ScriptedTouchable: SKScene {
    func scriptedTap(at point: CGPoint)
}

extension SKScene {
    /// The button a scripted tap at `point` lands on: the nearest one there,
    /// in the popup on top while one's open.
    func scriptedButton(at point: CGPoint) -> PressableNode? {
        let root: SKNode = SceneControls.topOverlay(in: self) ?? self
        func depth(_ node: SKNode) -> CGFloat {
            var z: CGFloat = 0
            var current: SKNode? = node
            while let next = current, next !== self {
                z += next.zPosition
                current = next.parent
            }
            return z
        }
        return nodes(at: point)
            .compactMap { $0 as? PressableNode }
            .filter { $0.isEnabled && $0.inParentHierarchy(root) && $0.isInside(convert(point, to: $0)) }
            .max { depth($0) < depth($1) }
    }

    /// `-Markers`' line for `-TouchScript` step `number`: its name and the
    /// points it touched, in view points from the top left
    /// (`[marker] step 3 cell=2x4 412.0,230.5`).
    func noteScriptStep(_ number: Int, _ name: String, at points: [CGPoint]) {
        guard LaunchArguments.printsMarkers else { return }
        let places = points.map { point -> String in
            let shown = convertPoint(toView: point)
            return String(format: "%.1f,%.1f", shown.x, shown.y)
        }
        Markers.note((["step \(number) \(name)"] + places).joined(separator: " "))
    }

    /// `-TouchScript`'s `form=share`: presses the open share form's Share.
    func pressShareForm(step number: Int, name: String) {
        guard let form = firstDescendant(ShareFormNode.self), let scene = form.scene else { return }
        noteScriptStep(number, name, at: [form.shareButton.convert(CGPoint.zero, to: scene)])
        form.shareButton.flashPress()
        form.shareButton.onTap?()
    }
}

extension SKNode {
    /// The first node of type `T` under this one, depth first.
    func firstDescendant<T: SKNode>(_ type: T.Type) -> T? {
        for child in children {
            if let match = child as? T ?? child.firstDescendant(type) { return match }
        }
        return nil
    }
}

/// Scenes that act out `-TouchScript`'s named steps (`pick=…`, `cell=…`),
/// each noting where it touched (`noteScriptStep`).
protocol ScriptedStepping: SKScene {
    func scriptedStep(_ name: String, number: Int)
}

/// Scenes whose settings (or pause menu) a gamepad's Menu button opens, and
/// closes again.
protocol MenuToggling: AnyObject {
    func toggleMenu()
}

/// Scenes with a "back" destination, reached by swiping in from the left
/// edge (or pressing Escape).
protocol BackNavigable: AnyObject {
    var canNavigateBack: Bool { get }
    func navigateBack()
}

/// Scenes that show saved data, told when another device changed it
/// (through iCloud) with the keys that changed.
protocol SavedDataObserving: AnyObject {
    func savedDataDidSync(_ keys: Set<String>)
}
