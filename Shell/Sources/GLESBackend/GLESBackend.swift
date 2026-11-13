import Foundation
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

    /// Reads the packed art and the fonts out of the APK. Call before the
    /// first frame: with no asset index every texture resolves to the white
    /// placeholder, and with no fonts registered every label measures zero
    /// and draws nothing.
    public static func prepare() {
        AssetBundle.installIndex()
        AssetBundle.installFonts()
    }

    /// The renderer the shell draws with.
    public static func makeRenderer(_ context: RenderContext) -> FrameRenderer {
        // The scene is sized the way the game sizes its own — the view's
        // size on a wide canvas, so a design point is a point. That is
        // DesignSystem.sceneSize(for:), which cross-compiles unchanged;
        // this mirrors it rather than re-deriving it, and stage 2 will call
        // the real one once the game's own scenes are building.
        let scene = BoardPreviewScene(size: sceneSize(for: context.size))
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
    /// scale and a design point is a point at that scale.
    static func sceneSize(for drawable: CGSize) -> CGSize {
        let scale = AssetIndex.shared?.scale ?? 3
        let points = CGSize(width: drawable.width / scale, height: drawable.height / scale)

        let long = max(points.width, points.height)
        let short = min(points.width, points.height)
        let design = CGSize(width: 960, height: 540)
        let canvasWidth: CGFloat = 1024

        let fit = max(1, min(long / design.width, short / design.height))
        return CGSize(
            width: max(canvasWidth, points.width / fit),
            height: points.height / fit
        )
    }
}
