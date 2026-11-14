import SpriteKit
import UIKit

/// The Apple controller's debug drivers, which `Tools/Capture` and the
/// parity sweep (`Android/Scripts/parity.js`) time captures by: each the
/// `GameViewController` method of the same name, reading the same
/// `LaunchArguments`, in debug builds only (`build-shell.sh` defines DEBUG
/// in every build but `--store`).
///
/// - `-KeyScript`, `-TouchScript` (`-ScriptTimes`, `-ScriptAfter`) and
///   `-RemoteScript` (Apple TV's presses, as a TV's remote or a d-pad would
///   press them here: arrows move focus, `select` presses, `menu` is Back);
///   `-GamepadScript` is `GamepadInput`'s, as on Apple.
/// - `-Stills` holds the view still after each marker; `-Markers`' lines
///   reach logcat through the shell (`switchlings_redirect_stdio`).
/// - `-SnapshotEvery` and `-SnapshotLevels` save what the view shows into
///   the app's cache (`snapshot.png`, `levels/<id>.png` and `layout.json`),
///   read back from the frame the renderer draws next (`captureFrame`).
/// - `-FrameLog`, `-SyncedClears`, `-SyncedMoves`, `-SyncedLanguage`.
///
/// Left out: `-Orientation turn` (the shell holds `landscape`, `flipped`
/// and `portrait` as the window is made), `-SimulateViewSize`,
/// `-MacWindowSize` and `-HoverAt` (Apple's windows), `-VirtualGamepad`
/// (Apple's on-screen pad).
extension AndroidGameController {
    /// What `viewDidLoad` starts: the scripts, paced from launch.
    func startScripts() {
        #if DEBUG
        if let duration = LaunchArguments.frameLogDuration {
            frameLog = FrameLog(duration: duration)
            view.delegate = frameLog
        }
        playRemoteScriptIfNeeded()
        playKeyScriptIfNeeded()
        playTouchScriptIfNeeded()
        simulateSyncIfNeeded()
        #endif
    }

    /// What `viewDidAppear` starts: the captures.
    func startCaptures() {
        #if DEBUG
        snapshotForTesting()
        snapshotLevelsForTesting()
        holdStillsForTesting()
        #endif
    }

    #if DEBUG
    private var caches: URL? { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first }

    /// The next frame the view draws, as a PNG, to `url`; then `done`.
    private func saveNextFrame(to url: URL, then done: @escaping () -> Void = {}) {
        guard let captureFrame else {
            done()
            return
        }
        captureFrame { image in
            if let image, let data = UIImage(cgImage: image).pngData() {
                try? data.write(to: url, options: .atomic)
            }
            done()
        }
    }

    /// `-SnapshotEvery`: keeps saving what the view shows.
    private func snapshotForTesting() {
        guard let interval = LaunchArguments.snapshotInterval, let caches else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.saveNextFrame(to: caches.appendingPathComponent("snapshot.png")) { self?.snapshotForTesting() }
        }
    }

    /// `-Stills`: holds the view still as each still comes due.
    private func holdStillsForTesting() {
        guard !LaunchArguments.stills.isEmpty else { return }
        Markers.holdStill = { [weak self] index, delay, target in
            guard let view = self?.view, let scene = target ?? view.scene else { return }
            scene.run(.sequence([.wait(forDuration: delay), .run { [weak view] in
                guard let view else { return }
                view.isPaused = true
                Markers.note("still \(index)")
                // The hold counts from the frame it paused in reaching the
                // screen: the shell drains the main queue only after that
                // frame is swapped, and an unoptimised build can take longer
                // than the whole hold to draw a scene's first frame.
                DispatchQueue.main.async {
                    DispatchQueue.main.asyncAfter(deadline: .now() + LaunchArguments.stillHold) { view.isPaused = false }
                }
            }]))
        }
    }

    /// `-SnapshotLevels`: opens each level in turn and saves what the view
    /// shows once the board has settled, with every board's fitted layout.
    private func snapshotLevelsForTesting(index: Int = 0, report: [[String: Any]] = []) {
        guard let ids = LaunchArguments.snapshotLevelIDs, let caches else { return }
        let folder = caches.appendingPathComponent("levels")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard ids.indices.contains(index) else {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("layout.json"))
            return
        }
        guard let entry = LevelCatalog.level(withID: ids[index]) else {
            snapshotLevelsForTesting(index: index + 1, report: report)
            return
        }
        let scene = GameScene(size: DesignSystem.sceneSize(for: view.bounds.size), entry: entry)
        scene.scaleMode = .aspectFill
        view.presentScene(scene)
        let delay = index == 0 ? LaunchArguments.firstLevelSnapshotDelay : LaunchArguments.levelSnapshotDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.saveNextFrame(to: folder.appendingPathComponent("\(entry.id).png")) {
                var row = GameScene.layoutReport
                row["id"] = entry.id
                self?.snapshotLevelsForTesting(index: index + 1, report: report + [row])
            }
        }
    }

    /// `-SyncedClears`, `-SyncedMoves`, `-SyncedLanguage`.
    private func simulateSyncIfNeeded() {
        let clears = LaunchArguments.syncedClears
        let moves = LaunchArguments.syncedMoves
        let language = LaunchArguments.syncedLanguage
        guard clears > 0 || moves > 0 || language != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + LaunchArguments.syncDelay) {
            if clears > 0 { Progress.simulateSyncedClears(clears) }
            if moves > 0, let level = LaunchArguments.startLevelID { Progress.simulateSyncedMoves(moves, in: level) }
            if let language { Localization.simulateSyncedPick(language) }
        }
    }

    /// `-RemoteScript "right,select,menu"`: Apple TV's presses, as a TV
    /// remote's d-pad presses them here — the arrows move focus, `select`
    /// and `playpause` press, `menu` is Back.
    private func playRemoteScriptIfNeeded() {
        for (step, name) in LaunchArguments.remoteScript.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + LaunchArguments.remoteScriptDelay + LaunchArguments.remoteStepInterval * Double(step)) { [weak self] in
                guard let self else { return }
                let ways: [String: FocusNavigator.Direction] = ["up": .up, "down": .down, "left": .left, "right": .right]
                switch name.lowercased() {
                case let way where ways[way] != nil:
                    remoteFocus().move(ways[way]!)
                case "select", "playpause":
                    _ = remoteFocus().select()
                case "menu":
                    if !handleBack() { leave?() }
                default:
                    break
                }
            }
        }
    }

    /// The remote's focus is always up, as on Apple TV.
    private func remoteFocus() -> FocusNavigator {
        if let focus { return focus }
        let navigator = FocusNavigator(view: view)
        _ = navigator.refresh()
        focus = navigator
        return navigator
    }

    /// `-KeyScript "1,2,wait,u"`: keyboard keys, a beat apart.
    private func playKeyScriptIfNeeded() {
        if !LaunchArguments.keyScript.isEmpty { UIApplication.shared.isIdleTimerDisabled = true }
        for (step, name) in LaunchArguments.keyScript.enumerated() {
            guard let key = LaunchArguments.keyCode(name) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + LaunchArguments.remoteScriptDelay + LaunchArguments.remoteStepInterval * Double(step)) { [weak self] in
                _ = (self?.view.scene as? KeyboardControllable)?.handleKey(key, modifiers: [])
            }
        }
    }

    /// `-TouchScript "0.2:0.85,wait,0.8:0.1"`: taps a beat apart (or at
    /// `-ScriptTimes`), from launch or `-ScriptAfter`'s marker.
    private func playTouchScriptIfNeeded() {
        let script = LaunchArguments.touchScript
        guard !script.isEmpty else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        guard let marker = LaunchArguments.scriptAfter else {
            playTouchScript(script, after: LaunchArguments.remoteScriptDelay)
            return
        }
        Markers.scriptTrigger = (marker, { [weak self] in self?.playTouchScript(script, after: 0) })
    }

    private func playTouchScript(_ script: [LaunchArguments.TouchStep], after delay: TimeInterval) {
        let times = LaunchArguments.scriptTimes
        for (step, item) in script.enumerated() {
            let at = times.indices.contains(step) ? times[step] : LaunchArguments.remoteStepInterval * Double(step)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + at) { [weak self] in
                guard let view = self?.view else { return }
                switch item {
                case .wait:
                    break
                case let .tap(share):
                    guard let scene = view.scene as? ScriptedTouchable else { return }
                    // Shares of the whole screen, which the view fills here.
                    let point = (scene as SKScene).convertPoint(fromView: pt(view.bounds.width * share.x, view.bounds.height * share.y))
                    (scene as SKScene).noteScriptStep(step + 1, "tap", at: [point])
                    scene.scriptedTap(at: point)
                case let .named(name):
                    (view.scene as? ScriptedStepping)?.scriptedStep(name, number: step + 1)
                }
            }
        }
    }
    #endif
}
