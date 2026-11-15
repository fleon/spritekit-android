import Foundation
import SpriteKitShim

/// Shaders a build handed over (`SKShader.programWarmer`) from its own
/// thread, for the frame thread to build their programs a few a frame.
nonisolated final class ShaderWarmQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [SKShader] = []
    private var seen = Set<ObjectIdentifier>()

    func add(_ shaders: [SKShader]) {
        lock.lock()
        for shader in shaders where seen.insert(ObjectIdentifier(shader)).inserted {
            waiting.append(shader)
        }
        lock.unlock()
    }

    func next() -> SKShader? {
        lock.lock()
        defer { lock.unlock() }
        guard !waiting.isEmpty else { return nil }
        let shader = waiting.removeFirst()
        seen.remove(ObjectIdentifier(shader))
        return shader
    }

    func removeAll() -> [SKShader] {
        lock.lock()
        defer { lock.unlock() }
        let taken = waiting
        waiting.removeAll()
        seen.removeAll()
        return taken
    }
}
