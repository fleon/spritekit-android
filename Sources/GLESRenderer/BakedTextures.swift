import Foundation
import SpriteKitShim

/// The GL textures `SKView.texture(from:)` has handed the game, each freed
/// once the game lets go of its `SKTexture`, as SpriteKit's are.
///
/// They used to be kept by the node they were baked from, the previous one
/// dropped when that node baked again. But a bake's node is usually a
/// throwaway canvas, freed as soon as the bake returns, and the next canvas
/// often lands at the same address: a texture baked for a shader to sample
/// as a uniform was deleted by the next bake made right after it, and the
/// shader sampled that one in its place, a nearly transparent map that drew
/// it dark.
public struct BakedTextures {
    private struct Entry {
        weak var texture: SKTexture?
        let name: UInt32
        let width: Int
        let height: Int
    }

    private var entries: [Entry] = []

    public init() {}

    public var count: Int { entries.count }

    /// Keeps `name` for as long as the game holds `texture`.
    public mutating func add(_ texture: SKTexture, name: UInt32, width: Int, height: Int) {
        entries.append(Entry(texture: texture, name: name, width: width, height: height))
    }

    /// Forgets the textures the game has let go of, handing back their GL
    /// names to delete.
    public mutating func sweep() -> [UInt32] {
        let gone = entries.filter { $0.texture == nil }.map(\.name)
        entries.removeAll { $0.texture == nil }
        return gone
    }

    /// Every name, for a GL context that's going away.
    public mutating func removeAll() -> [UInt32] {
        defer { entries.removeAll() }
        return entries.map(\.name)
    }

    /// The pixel size of a texture still held, for reading it back.
    public func size(of name: UInt32) -> (width: Int, height: Int)? {
        entries.first { $0.name == name && $0.texture != nil }.map { ($0.width, $0.height) }
    }
}
