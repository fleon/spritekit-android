#if !SPRITEKIT_SHIM
import Foundation
import GameKit
import UIKit

/// GameKit behind `AchievementsBackend`: Game Center's sign-in,
/// achievements, dashboard and local player.
///
/// GameKit calls the authentication handler at launch and again whenever
/// the player signs in or out; `answered` runs at its first answer (signed
/// in, offering its sign-in sheet, or failed) and again each time the player
/// signs in or out, so the manager catches up and tells the game, as Play
/// Games' backend does. The sheet is offered once a launch.
public final class GameKitAchievements: AchievementsBackend {
    /// Shows GameKit's sign-in sheet; over the top view controller when nil.
    public var presentSignIn: ((UIViewController) -> Void)?
    public private(set) var player: GamePlayer?
    public var playerChanged: ((GamePlayer?) -> Void)?

    private var answered: (() -> Void)?
    private var hasStarted = false
    private var hasAnswered = false
    private var hasOfferedSignIn = false
    private var wasSignedIn = false

    public init() {}

    public var isSignedIn: Bool { GKLocalPlayer.local.isAuthenticated }

    public func start(answered: @escaping () -> Void) {
        self.answered = answered
        guard !hasStarted else { return }
        hasStarted = true
        GKLocalPlayer.local.authenticateHandler = { [weak self] signIn, _ in
            Task { @MainActor in self?.authenticated(signIn: signIn) }
        }
    }

    public func load() async -> [String: Double] {
        guard isSignedIn, let loaded = try? await GKAchievement.loadAchievements() else { return [:] }
        return Dictionary(loaded.map { ($0.identifier, $0.percentComplete) }, uniquingKeysWith: max)
    }

    public func report(_ progress: [String: Double], showingBanners: Bool) async -> Bool {
        guard isSignedIn else { return false }
        let entries = progress.sorted { $0.key < $1.key }.map { id, percent in
            let entry = GKAchievement(identifier: id)
            entry.percentComplete = percent
            entry.showsCompletionBanner = showingBanners
            return entry
        }
        do {
            try await GKAchievement.report(entries)
            return true
        } catch {
            return false
        }
    }

    public func reset() async -> Bool {
        guard isSignedIn else { return false }
        do {
            try await GKAchievement.resetAchievements()
            return true
        } catch {
            return false
        }
    }

    /// Game Center's dashboard can't sign a signed-out player in: a game
    /// tells them to sign in from Settings instead.
    public var hasDashboard: Bool { false }

    public func showDashboard() {
        show(.dashboard, over: nil)
    }

    /// Opens Game Center in GameKit's overlay at `state`, over `window`;
    /// the game carries on underneath and the overlay closes itself.
    public func show(_ state: GKGameCenterViewControllerState, over window: UIWindow?) {
        guard isSignedIn else { return }
        let accessPoint = GKAccessPoint.shared
        accessPoint.parentWindow = window ?? TopViewController.keyWindow
        accessPoint.trigger(state: state) {}
    }

    public func localPlayer() async -> (name: String, photo: Data?)? {
        let local = GKLocalPlayer.local
        guard local.isAuthenticated else { return nil }
        let photo = try? await local.loadPhoto(for: .normal)
        return (local.alias, photo?.pngData())
    }

    private func authenticated(signIn: UIViewController?) {
        if let signIn, !hasOfferedSignIn {
            hasOfferedSignIn = true
            (presentSignIn ?? TopViewController.present)(signIn)
        }
        updatePlayer()
        let signedIn = isSignedIn
        defer { wasSignedIn = signedIn }
        guard !hasAnswered || signedIn != wasSignedIn else { return }
        hasAnswered = true
        answered?()
    }

    private func updatePlayer() {
        let local = GKLocalPlayer.local
        let now = local.isAuthenticated
            ? GamePlayer(id: local.gamePlayerID, name: local.displayName, legacyID: (local as LegacyPlayerID).playerID)
            : nil
        guard now != player else { return }
        player = now
        playerChanged?(now)
    }
}

/// GameKit's `playerID`, deprecated but still what older accounts were
/// keyed on; read through a protocol so the deprecation stays here.
private protocol LegacyPlayerID {
    var playerID: String { get }
}

extension GKPlayer: LegacyPlayerID {}

/// Where GameKit's sheets and overlays go when the game doesn't say.
enum TopViewController {
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    static func present(_ controller: UIViewController) {
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        top?.present(controller, animated: true)
    }
}
#endif
