import SpriteKit

/// The stand-in game's one scene, which `Templates/Game`'s controller opens
/// after the splash. It prints `TitleScene.shownMessage` once it shows, which
/// the CI's emulator run waits for in logcat.
final class TitleScene: SKScene {
    static let shownMessage = "template-check: first scene shown"

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1)
        let logo = SKSpriteNode(imageNamed: "Logo")
        logo.position = CGPoint(x: frame.midX, y: frame.midY)
        addChild(logo)
        print(Self.shownMessage)
    }
}
