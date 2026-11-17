import CAndroidShell
import Foundation
import SpriteKitShim
import ShellCore

/// The whole visual bar of the app-shell track: prove the context is real by
/// clearing to a colour nothing else would pick.
///
/// Deliberately the only `FrameRenderer` in this module. Sprites, textures
/// and shaders belong to the renderer, which replaces this by setting
/// `Shell.makeRenderer`.
public final class ClearScreenRenderer: FrameRenderer {
    /// A deep magenta. Not black, not GL's
    /// transparent default, and not any framework's idea of a clear colour,
    /// so a screenshot of it means our code ran.
    public static let colour = (r: Float(0.85), g: Float(0.11), b: Float(0.55), a: Float(1))

    public init(context: RenderContext) {}

    public func rendererDidStart(_ context: RenderContext) {
        let c = Self.colour
        Log.info("clearing to rgba(\(c.r), \(c.g), \(c.b), \(c.a))")
        glClearColor(c.r, c.g, c.b, c.a)
    }

    public func drawableSizeDidChange(to size: CGSize) {
        glViewport(0, 0, GLsizei(size.width), GLsizei(size.height))
    }

    public func drawFrame(_ frame: Frame) {
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    }
}
