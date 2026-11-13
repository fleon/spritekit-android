import SpriteKitShim

/// A Switchling on the board — the stand-in for the game's own `ActorNode`.
///
/// `ActorNode` is not taken here, and it is the one board component on this
/// slice that is written rather than reused: its `rig` is a stored,
/// non-optional `RigNode`, so it cannot be built at all until the Spine
/// runtime is ported, which is a ring of its own. What it would do that this
/// does not is play: hopping, sliding, bumping, sleeping, celebrating,
/// wading, the whirlpool clip and the key badge. The board carries this node
/// along the same `Timeline` tracks it would carry an `ActorNode` along, so
/// swapping it out later changes this file and nothing that drives it.
///
/// The tree below the node is `ActorNode`'s own, so the two stand in the same
/// place on a cell: feet `actorFeetDrop` below the cell's centre, the art
/// anchored at `characterFeetAnchor`, and the live eyes riding the art.
final class PlaySwitchlingNode: SKNode {
    let castID: String
    private let theme: WorldTheme
    private let cell: CGFloat
    /// Where the feet stand; everything the Switchling is hangs off it.
    private let feetNode = SKNode()
    private let art: SKSpriteNode
    private let eyes: CharacterEyesNode?
    private var isHome = false

    init(castID: String, theme: WorldTheme, cell: CGFloat) {
        self.castID = castID
        self.theme = theme
        self.cell = cell
        let size = cell * DesignSystem.actorArtScale * DesignSystem.characterArtPaddingScale
        art = sprite(theme.characterAsset(castID, .open), size: sz(size))
        eyes = CharacterEyesNode(
            character: theme.characterName(castID),
            unit: cell * DesignSystem.actorArtScale / 100
        )
        super.init()

        feetNode.position = pt(0, -cell * DesignSystem.actorFeetDrop)
        addChild(feetNode)
        art.anchorPoint = pt(0.5, DesignSystem.characterFeetAnchor)
        SceneLighting.light(art, asset: theme.characterAsset(castID, .open), theme: theme)
        feetNode.addChild(art)
        if let eyes {
            eyes.zPosition = DesignSystem.zStep
            art.addChild(eyes)
            eyes.startLooking()
        }
    }

    /// Home: the painted happy face, eyes and all, as `ActorNode` shows it.
    func setHome(_ home: Bool) {
        guard home != isHome else { return }
        isHome = home
        art.texture = txtr(theme.characterAsset(castID, home ? .happy : .open))
        eyes?.isHidden = home
    }
}
