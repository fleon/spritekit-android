#if SPRITEKIT_SHIM
import Foundation

extension SKTexture {
    /// SpriteKit decodes and uploads the textures ahead of their first draw.
    /// Here a texture goes up to the GPU on the frame thread the first time
    /// it is drawn — the only thread with the GL context — so there is
    /// nothing to do ahead of it, and the handler runs at once, on the
    /// calling thread, as SpriteKit's runs on one of its own.
    public class func preload(_ textures: [SKTexture], withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    public func preload(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

#endif
