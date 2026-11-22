import PlatformSprite
import SpriteKit
import UIKit

/// The stand-in game's view controller on Apple platforms, as a game's is:
/// its one `SKView`, and the studio splash into `TitleScene`
/// (`StudioSplashScene.launch`). `Templates/Game` leaves it out on Android,
/// where its controller stands in for it.
final class GameViewController: UIViewController {
    private var launch: StudioSplashLaunch?

    override func loadView() {
        view = SKView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let view = view as? SKView else { return }
        launch = StudioSplashScene.launch(in: view, style: LaunchSplash.style, firstScene: .built { view in
            let scene = TitleScene(size: view.bounds.size)
            scene.scaleMode = .aspectFill
            return scene
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let view = view as? SKView else { return }
        _ = launch?.layout(view)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        launch?.start()
    }
}
