#if SPRITEKIT_SHIM
import Foundation

extension SKTexture {
    /// Decodes packed pages ahead of their first draw; the renderer installs
    /// it (`PageDecodes`). Called on the preloading thread, never the frame
    /// thread, and returns once they're decoded.
    public nonisolated(unsafe) static var pageDecoder: ((Set<Int>) -> Void)?

    /// SpriteKit decodes the textures ahead of their first draw on a queue
    /// of its own, then calls the handler there. Here the packed pages they
    /// sit on are decoded the same way (the upload itself waits for the
    /// frame thread, the only one with the GL context): on the calling
    /// thread when that's a background one, as the game's are, else on a
    /// queue of its own, the handler following once they're done.
    public class func preload(_ textures: [SKTexture], withCompletionHandler completionHandler: @escaping () -> Void) {
        let pages = Set(textures.compactMap(\.page))
        guard !pages.isEmpty, let decode = pageDecoder else {
            completionHandler()
            return
        }
        guard Thread.isMainThread else {
            decode(pages)
            completionHandler()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            decode(pages)
            completionHandler()
        }
    }

    public func preload(completionHandler: @escaping () -> Void) {
        SKTexture.preload([self], withCompletionHandler: completionHandler)
    }
}

#endif
