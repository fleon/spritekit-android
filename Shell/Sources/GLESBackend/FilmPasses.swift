import Foundation
import SpriteKitShim

/// Command buffers an offscreen render has committed (`SKRenderer` through the
/// Metal stand-ins), waiting for the renderer's next frame to draw them.
///
/// The film renders on a thread of its own and waits for each frame
/// (`waitUntilCompleted`); the renderer draws them on its own thread, where
/// the context is current, before the view's frame. A game that films
/// through the view's delegate updates and encodes only between the view's
/// frames, so the renderer
/// gives it a moment at the top of each frame while a film is being made:
/// it waits for the film's next buffer, briefly, rather than ticking the
/// view straight away and leaving the film a frame behind every time.
final class FilmPasses: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [MTLCommandBuffer] = []
    private var lastCommit: TimeInterval = -.infinity

    /// How long after its last commit a film still counts as being made.
    private static let filming: TimeInterval = 0.5

    func push(_ buffer: MTLCommandBuffer) {
        condition.withLock {
            pending.append(buffer)
            lastCommit = MediaTime.source()
            condition.broadcast()
        }
    }

    /// What's been committed, waiting up to `wait` seconds for something
    /// while a film is being made.
    func take(waitingUpTo wait: TimeInterval) -> [MTLCommandBuffer] {
        condition.withLock {
            let filming = MediaTime.source() - lastCommit < Self.filming
            if pending.isEmpty, filming, wait > 0 {
                _ = condition.wait(until: Date(timeIntervalSinceNow: wait))
            }
            defer { pending = [] }
            return pending
        }
    }

    /// Fails whatever's waiting (the renderer is going away).
    func failAll() {
        for buffer in take(waitingUpTo: 0) {
            buffer.complete(error: MTLCommandBufferError("the renderer stopped"))
        }
    }
}
