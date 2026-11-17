import Foundation
import SpriteKitShim

/// Textures the asset index doesn't back, their pixels readied on the
/// preloading thread (`SKTexture.imageWarmer`), for the frame thread to
/// upload ahead of their first draw (`ResourceCache.adopt`): a scene's drawn
/// surfaces and image pages were otherwise decoded, turned over and uploaded
/// in its warm-up draw.
public final class TextureWarmQueue: @unchecked Sendable {
    public typealias Item = (texture: SKTexture, width: Int, height: Int, pixels: Data)

    private let lock = NSLock()
    private var waiting: [Item] = []

    public init() {}

    public func add(_ item: Item) {
        lock.lock()
        waiting.append(item)
        lock.unlock()
    }

    public func next() -> Item? {
        lock.lock()
        defer { lock.unlock() }
        return waiting.isEmpty ? nil : waiting.removeFirst()
    }

    @discardableResult
    public func removeAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = waiting.count
        waiting.removeAll()
        return count
    }
}
