import Foundation
import GameCompat
import GLESRenderer
import ShellCore
import SpriteKitShim

/// How the shell gets a renderer.
///
/// The dependency runs one way: `AndroidShell` imports this, loads the art
/// and hands `makeRenderer` to `Shell.run`. This module knows nothing about
/// the shell beyond `ShellCore`'s four seam types, and the shell knows
/// nothing about sprites, textures or shaders.
public enum GLESBackend {

    /// Reads the packed art, the fonts and the levels out of the APK, and
    /// makes the rigs reachable. Call before the first frame: with no asset
    /// index every texture resolves to the white placeholder, with no fonts
    /// registered every label measures zero and draws nothing, with no rig
    /// bundle no Switchling moves, and with no levels the board falls back
    /// to the hand-laid preview.
    public static func prepare() {
        AssetBundle.installIndex()
        AssetBundle.installFonts()
        RigBundle.install()
        LevelBundle.install()
    }

    /// The renderer the shell draws with.
    public static func makeRenderer(_ context: RenderContext) -> FrameRenderer {
        let size = sceneSize(for: context.size)
        // How many pixels a point is worth, which is what the game reads to
        // decide the density of every texture it draws for itself
        // (`SurfaceTexture.renderScale`). It has to be right *before* the
        // scene builds, since that is when the surfaces are drawn.
        UITraitCollection.current.displayScale = Viewport(
            drawableSize: context.size, sceneSize: size, scaleMode: .aspectFill
        ).scale.x

        // A real level if the catalog loaded, else the hand-laid preview, so
        // a missing or broken level file shows the pipeline still works
        // rather than a blank screen.
        let scene = AndroidLevels.scene(size: size) ?? BoardPreviewScene(size: size)
        scene.scaleMode = .aspectFill
        return SceneRenderer(
            scene: scene,
            drawableSize: context.size,
            pageLoader: AssetBundle.page
        )
    }

    /// `DesignSystem.sceneSize(for:)`, in points, from a drawable in pixels.
    ///
    /// The drawable is physical pixels and the game thinks in points, so the
    /// density comes out of the asset index — the art is exported at one
    /// scale and a design point is a point at that scale. The sizing itself
    /// is the game's own, now that DesignSystem compiles here.
    static func sceneSize(for drawable: CGSize) -> CGSize {
        let scale = AssetIndex.shared?.scale ?? 3
        return AndroidLevels.sceneSize(
            forViewSize: CGSize(width: drawable.width / scale, height: drawable.height / scale)
        )
    }
}
