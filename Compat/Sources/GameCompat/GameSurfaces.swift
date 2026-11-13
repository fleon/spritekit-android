import Foundation
import SpriteKitShim

/// A door into this target, so the shell can show the game's own surfaces.
///
/// Everything in `GameCompat` is the game's unmodified source, and the game
/// declares nothing `public` — it is one module on Apple. So the shell cannot
/// call `SurfaceTexture` directly however much it would like to, and this is
/// the smallest thing that lets it: a handful of `public` wrappers that call
/// the real `ChunkyStyle` and the real `SurfaceTexture`, with no drawing of
/// their own. The pixels on screen are the game's.
///
/// It exists to prove the `CGContext` ring, and it is the kind of seam that
/// goes away: once the shell builds the game's own scenes, those scenes make
/// their own buttons and nothing has to reach in from outside.
public enum GameSurfaces {

    /// Sets the skin the surfaces take, by the world's name as
    /// `WorldTheme`'s raw values spell it ("garden", "mainframe"…). Left
    /// alone it is Sunny Garden's, which is `UISkin`'s own default.
    public static func useSkin(world: String) {
        guard let theme = WorldTheme(rawValue: world) else { return }
        UISkin.current = theme.skin
    }

    /// The call to action — Play, Next — in the world's primary colour:
    /// gradient face, lit rim, hairline, darker edge, soft drop shadow.
    public static func primaryButton(size: CGSize, cornerRadius: CGFloat) -> SKSpriteNode {
        SurfaceTexture.chunkyResting(size: size, style: .primary(cornerRadius: cornerRadius))
    }

    /// Cream buttons, icon buttons and level tiles.
    public static func creamButton(size: CGSize, cornerRadius: CGFloat) -> SKSpriteNode {
        SurfaceTexture.chunkyResting(size: size, style: .cream(cornerRadius: cornerRadius))
    }

    /// An overlay panel or card.
    public static func panel(size: CGSize, cornerRadius: CGFloat) -> SKSpriteNode {
        SurfaceTexture.chunkySurface(size: size, style: .panel(cornerRadius: cornerRadius))
    }

    /// A locked level's socket: sunk into its card, shaded from its top edge
    /// and lit along its lower rim. The one surface whose look is an inner
    /// shadow, so it is the one that says whether shadows work.
    public static func socket(size: CGSize, cornerRadius: CGFloat) -> SKSpriteNode {
        SurfaceTexture.chunkySurface(size: size, style: .socket(cornerRadius: cornerRadius))
    }

    /// A flat, sunken card on a panel, grouping rows.
    public static func insetCard(size: CGSize) -> SKSpriteNode {
        SurfaceTexture.chunkySurface(size: size, style: .insetCard)
    }

    /// The ring round what the remote has in focus: two stroked bands, the
    /// outer one fainter, clear of the shape they follow.
    public static func focusRing(around bounds: CGRect, cornerRadius: CGFloat) -> SKSpriteNode {
        let ring = SurfaceTexture.focusRing(around: bounds, cornerRadius: cornerRadius)
        ring.alpha = 1
        return ring
    }

    /// A soft round glow fading to clear — a radial gradient with five stops.
    public static func glow(red: CGFloat, green: CGFloat, blue: CGFloat) -> SKSpriteNode {
        let texture = SurfaceTexture.glow(UIColor(red: red, green: green, blue: blue, alpha: 1))
        return SKSpriteNode(texture: texture, size: texture.size())
    }

    /// The white four-pointed sparkle, built from four quadratic curves.
    public static func sparkle(size: CGFloat) -> SKSpriteNode {
        SKSpriteNode(texture: SurfaceTexture.sparkle(), size: CGSize(width: size, height: size))
    }
}
