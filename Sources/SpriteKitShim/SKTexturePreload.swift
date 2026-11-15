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
    /// Readies textures the asset index doesn't back (the game's drawn
    /// surfaces, rig pages, raw data) for their upload ahead of their first
    /// draw; the renderer installs it. Called on the preloading thread.
    public nonisolated(unsafe) static var imageWarmer: (([SKTexture]) -> Void)?

    public class func preload(_ textures: [SKTexture], withCompletionHandler completionHandler: @escaping () -> Void) {
        // What this thread built is finished once it preloads: its shaders'
        // programs can be built ahead of their first draw (`SKShader.programWarmer`).
        if !Thread.isMainThread, let warm = SKShader.programWarmer {
            let shaders = SKShader.takeMadeOnThisThread()
            if !shaders.isEmpty { warm(shaders) }
        }
        let pages = Set(textures.compactMap(\.page))
        var seen = Set<ObjectIdentifier>()
        var own: [SKTexture] = []
        for texture in textures {
            let root = texture.root
            guard root.page == nil, root.glName == 0, root.mutablePixels == nil else { continue }
            if seen.insert(ObjectIdentifier(root)).inserted { own.append(root) }
        }
        let decode = pageDecoder
        let warm = own.isEmpty ? nil : imageWarmer
        let decodes = !pages.isEmpty && decode != nil
        guard decodes || warm != nil else {
            completionHandler()
            return
        }
        func work() {
            warm?(own)
            if !pages.isEmpty { decode?(pages) }
            completionHandler()
        }
        guard Thread.isMainThread else {
            work()
            return
        }
        DispatchQueue.global(qos: .utility).async { work() }
    }

    public func preload(completionHandler: @escaping () -> Void) {
        SKTexture.preload([self], withCompletionHandler: completionHandler)
    }
}

#endif
