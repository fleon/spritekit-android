import Foundation
import PlatformShim
import SpriteKitShim

// What the platform managers below reach for outside themselves, and why
// each is a stand-in rather than the real file. Same rule as `Stubs.swift`:
// every one of these is a seam that belongs to a later ring, named here so
// the managers can be compiled and cross-compiled now.

/// Real one is `Source/Utils/LaunchArguments.swift`, 479 lines that read
/// debug flags out of `UserDefaults`' argument domain. It does not compile
/// here yet because it reaches `Level`, `LevelCatalog`, `AppLanguage` and
/// `UIKeyboardHIDUsage` — the rules and input rings.
///
/// Every value below is what a release build takes, which is also what an
/// Android build takes today: arguments do reach the process (see
/// `ShellArguments` in the shell, filled from the intent's `args` extra),
/// but nothing parses them into this yet.
enum LaunchArguments {
    /// Never touches iCloud's key-value store. Always true here: there is no
    /// iCloud on Android, and `ICloudSyncManager` is built so that this is
    /// the whole difference.
    static var keepsICloudOff: Bool { true }
    static var simulatesPurchases: Bool { false }
    static var unlocksAllWorlds: Bool { false }
    static var locksFullGame: Bool { false }
    static var previewPrice: String? { nil }
    static var launchEventRunning: Bool? { nil }
    static var resetsAchievements: Bool { false }
    static var sharePlayerName: String? { nil }
    /// Plays the Level Designer's feed. Off for good on Android — see
    /// `DesignerFeed` below.
    static var playsDesignerLevels: Bool { false }
    /// `-HoldLoading`: the loading screen stays up. Off, as in a release build.
    static var holdsLoading: Bool { false }
}

/// Real one is in `Source/GameViewController.swift`, which is the Apple
/// app's own view controller and has no Android counterpart. The loading
/// screen hands the scene it built whatever another device changed
/// meanwhile; nothing syncs between devices on Android yet, so nothing calls
/// it, but the protocol is the game's and must be the same.
protocol SavedDataObserving: AnyObject {
    func savedDataDidSync(_ keys: Set<String>)
}

/// Real one prints `[marker] …` lines for the recording tools
/// (`Tools/Pitch`, `Tools/Screenshots`, `Tools/PreviewVideo`), all of which
/// drive a simulator. None of them has an Android counterpart, and the real
/// file reaches `LaunchArguments` and `SKScene`.
enum Markers {
    static func note(_ name: String, in scene: SKScene? = nil) {}
}

// `LevelCatalog` and `World` used to stand in here, for the one `Version`
// `PlaytestLog` takes and the three fields `StoreManager` reads off a
// world. The real `LevelCatalog.swift` is compiled now (the gameplay ring),
// so both are the game's own.

/// Real one is `Source/Game/Models/Progress.swift`.
enum Progress {
    static func isAffected(by keys: Set<String>) -> Bool { false }
}

/// Real one is `Source/Game/Models/GameSession.swift`, which reaches
/// `Progress`. `GameCenterManager.played(from:to:)` and `PlaytestLog` take a
/// `Move` without reading it. (`GameState` stood in beside it until the
/// gameplay ring; the real one is compiled now.)
enum GameSession {
    struct Move: Sendable {}
}

/// UIKit types the managers name but never use on Android.
///
/// `GameCenterManager.start(presentSignIn:)` takes a view controller
/// because GameKit hands it a sign-in sheet; `showDashboard(over:)` takes
/// the window GameKit's overlay would cover. Neither happens here, but the
/// signatures are the game's and must stay, so the types have to exist.
/// They belong to the UIKit shim proper, which has none of them yet —
/// nothing in the port presents anything.
///
/// `UIImage` was here too, for `localPlayer()`'s photo. It is the shim's
/// own now (the rigs load their pages through it), and a second one
/// declared in this module would shadow it everywhere in it. `UIWindow`
/// was too; it is the shim's now, beside `SKView`, because `SceneLayout`
/// asks the view for its window.
class UIViewController {}

/// Real one is `Source/Game/Models/Achievement.swift`, which is portable
/// rules code — it works out how far each achievement has come from the
/// levels cleared and the board firsts had. It is not here because it
/// reaches `LevelCatalog`, `Progress` and `GameState`, so it lands with the
/// rules ring and `GameCenterManager` below starts reporting for real then.
struct Achievement: Sendable {
    enum Moment: String, CaseIterable, Sendable {
        case bump
        case wake
        case pass
    }

    let id: String

    static let all: [Achievement] = []

    func percentComplete(moments: Set<Moment>) -> Double { 0 }

    static func moments(from previous: GameState, to next: GameState) -> Set<Moment> { [] }
}
