import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif

extension SKNode {
    /// Adds `node` at `z`, and at `position` when one is given, and returns
    /// it: a node made, placed and added in one line.
    @discardableResult
    public func addChild<Child: SKNode>(_ node: Child, z: CGFloat, at position: CGPoint? = nil) -> Child {
        node.zPosition = z
        if let position { node.position = position }
        addChild(node)
        return node
    }
}

// Action keys as an owner's enum rather than loose strings:
//
//     private enum ActionKey: String {
//         case pulse = "logo.pulse"
//     }
//     node.run(pulse, withKey: ActionKey.pulse)
//
// The raw value is the key SpriteKit sees, so a prefix still keeps two
// owners' keys apart on a shared node. Reading a literal raw value builds
// nothing, so these cost what the `String` calls cost.

extension SKNode {
    /// `run(_:withKey:)` by `key`'s raw value.
    public func run<Key: RawRepresentable>(_ action: SKAction, withKey key: Key) where Key.RawValue == String {
        run(action, withKey: key.rawValue)
    }

    /// `action(forKey:)` by `key`'s raw value.
    public func action<Key: RawRepresentable>(forKey key: Key) -> SKAction? where Key.RawValue == String {
        action(forKey: key.rawValue)
    }

    /// `removeAction(forKey:)` by `key`'s raw value.
    public func removeAction<Key: RawRepresentable>(forKey key: Key) where Key.RawValue == String {
        removeAction(forKey: key.rawValue)
    }

    /// Whether an action runs under `key`.
    public func hasAction(forKey key: String) -> Bool {
        action(forKey: key) != nil
    }

    /// Whether an action runs under `key`'s raw value.
    public func hasAction<Key: RawRepresentable>(forKey key: Key) -> Bool where Key.RawValue == String {
        action(forKey: key.rawValue) != nil
    }
}
