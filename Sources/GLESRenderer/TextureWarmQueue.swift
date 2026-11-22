import Foundation
import PlatformServices
import SpriteKitShim

/// Textures the asset index doesn't back, their pixels readied on the
/// preloading thread (`SKTexture.imageWarmer`), for the frame thread to
/// upload ahead of their first draw (`ResourceCache.adopt`): a scene's drawn
/// surfaces and image pages were otherwise decoded, turned over and uploaded
/// in its warm-up draw.
public final class TextureWarmQueue: @unchecked Sendable {
    public typealias Item = (texture: SKTexture, width: Int, height: Int, pixels: Data)

    private let waiting = Locked<[Item]>([])

    public init() {}

    public func add(_ item: Item) {
        waiting.withLock { $0.append(item) }
    }

    public func next() -> Item? {
        waiting.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    @discardableResult
    public func removeAll() -> Int {
        waiting.withLock { waiting in
            defer { waiting.removeAll() }
            return waiting.count
        }
    }
}
