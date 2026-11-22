import Foundation
import PlatformServices
import SpriteKitShim

/// Shaders a build handed over (`SKShader.programWarmer`) from its own
/// thread, for the frame thread to build their programs a few a frame.
nonisolated final class ShaderWarmQueue: @unchecked Sendable {
    private struct State {
        var waiting: [SKShader] = []
        var seen = Set<ObjectIdentifier>()
    }

    private let state = Locked(State())

    func add(_ shaders: [SKShader]) {
        state.withLock { state in
            for shader in shaders where state.seen.insert(ObjectIdentifier(shader)).inserted {
                state.waiting.append(shader)
            }
        }
    }

    func next() -> SKShader? {
        state.withLock { state in
            guard !state.waiting.isEmpty else { return nil }
            let shader = state.waiting.removeFirst()
            state.seen.remove(ObjectIdentifier(shader))
            return shader
        }
    }

    func removeAll() -> [SKShader] {
        state.withLock { state in
            defer { state = State() }
            return state.waiting
        }
    }
}
