// Stands in for GameKit on Android: the signed-in player by their id and
// alias, and leaderboards (`GKLeaderboard`, `GKAccessPoint`,
// `GKGameCenterViewController`) through PlatformShim's `LeaderboardsBackend`
// (Play Games). Achievements and sign-in go through PlatformShim's
// `AchievementsBackend` instead.
import Foundation
import PlatformShim
import SpriteKitShim

/// A Game Center player: the one signed in to Play Games, or one named on a
/// leaderboard. Not actor-isolated, as Apple's isn't; the platform layer
/// updates the local player on the main thread.
open class GKPlayer {
    public internal(set) var gamePlayerID = ""
    public internal(set) var alias = ""
    public var displayName: String { alias }

    init() {}

    init(gamePlayerID: String, alias: String) {
        self.gamePlayerID = gamePlayerID
        self.alias = alias
    }
}

/// The local player: the one signed in to Play Games, by their Play Games ID
/// and name (set by the platform layer from
/// `PlayGamesAchievements.identity`), so a game can name them as it names a
/// Game Center player on iOS. Signed out, `isAuthenticated` is false, as on
/// iOS.
public final class GKLocalPlayer: GKPlayer {
    public static let local = GKLocalPlayer()

    public private(set) var isAuthenticated = false

    private override init() {
        super.init()
    }

    /// The Play Games player now signed in, or nil once nobody is.
    public func update(_ identity: (id: String, name: String)?) {
        isAuthenticated = identity != nil
        gamePlayerID = identity?.id ?? ""
        alias = identity?.name ?? ""
    }
}

/// GameKit's errors, by Apple's codes, as Swift sees Apple's: `catch
/// GKError.notAuthenticated`, `error.code`, and as an `NSError` in
/// `GKErrorDomain` with the code's number.
public let GKErrorDomain = "GKErrorDomain"

public struct GKError: Error, Equatable, Sendable, CustomNSError {
    public enum Code: Int, Sendable {
        case unknown = 1
        case cancelled = 2
        case communicationsFailure = 3
        case userDenied = 4
        case invalidCredentials = 5
        case notAuthenticated = 6
        case authenticationInProgress = 7
        case invalidPlayer = 8
        case scoreNotSet = 9
        case parentalControlsBlocked = 10
        case playerStatusExceedsMaximumLength = 11
        case playerStatusInvalid = 12
        case matchRequestInvalid = 13
        case underage = 14
        case gameUnrecognized = 15
        case notSupported = 16
        case invalidParameter = 17
        case unexpectedConnection = 18
        case challengeInvalid = 19
        case turnBasedMatchDataTooLarge = 20
        case turnBasedTooManySessions = 21
        case turnBasedInvalidParticipant = 22
        case turnBasedInvalidTurn = 23
        case turnBasedInvalidState = 24
        case invitationsDisabled = 25
        case playerPhotoFailure = 26
        case ubiquityContainerUnavailable = 27
        case matchNotConnected = 28
        case gameSessionRequestInvalid = 29
        case restrictedToAutomatch = 30
        case apiNotAvailable = 31
        case notAuthorized = 32
        case connectionTimeout = 33
        case apiObsolete = 34
        case iCloudUnavailable = 35
        case lockdownMode = 36
        case appUnlisted = 37
        case debugMode = 38
        case friendListDescriptionMissing = 100
        case friendListRestricted = 101
        case friendListDenied = 102
        case friendRequestNotAvailable = 103
    }

    public static var errorDomain: String { GKErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [:] }

    public let code: Code

    public init(_ code: Code) {
        self.code = code
    }

    init(leaderboard error: Error) {
        switch error as? LeaderboardError ?? .failed {
        case .signedOut: code = .notAuthenticated
        case .unavailable: code = .notSupported
        case .unknownLeaderboard: code = .invalidParameter
        case .failed: code = .communicationsFailure
        }
    }

    public static var unknown: Code { .unknown }
    public static var cancelled: Code { .cancelled }
    public static var communicationsFailure: Code { .communicationsFailure }
    public static var userDenied: Code { .userDenied }
    public static var invalidCredentials: Code { .invalidCredentials }
    public static var notAuthenticated: Code { .notAuthenticated }
    public static var authenticationInProgress: Code { .authenticationInProgress }
    public static var invalidPlayer: Code { .invalidPlayer }
    public static var scoreNotSet: Code { .scoreNotSet }
    public static var parentalControlsBlocked: Code { .parentalControlsBlocked }
    public static var playerStatusExceedsMaximumLength: Code { .playerStatusExceedsMaximumLength }
    public static var playerStatusInvalid: Code { .playerStatusInvalid }
    public static var matchRequestInvalid: Code { .matchRequestInvalid }
    public static var underage: Code { .underage }
    public static var gameUnrecognized: Code { .gameUnrecognized }
    public static var notSupported: Code { .notSupported }
    public static var invalidParameter: Code { .invalidParameter }
    public static var unexpectedConnection: Code { .unexpectedConnection }
    public static var challengeInvalid: Code { .challengeInvalid }
    public static var turnBasedMatchDataTooLarge: Code { .turnBasedMatchDataTooLarge }
    public static var turnBasedTooManySessions: Code { .turnBasedTooManySessions }
    public static var turnBasedInvalidParticipant: Code { .turnBasedInvalidParticipant }
    public static var turnBasedInvalidTurn: Code { .turnBasedInvalidTurn }
    public static var turnBasedInvalidState: Code { .turnBasedInvalidState }
    public static var invitationsDisabled: Code { .invitationsDisabled }
    public static var playerPhotoFailure: Code { .playerPhotoFailure }
    public static var ubiquityContainerUnavailable: Code { .ubiquityContainerUnavailable }
    public static var matchNotConnected: Code { .matchNotConnected }
    public static var gameSessionRequestInvalid: Code { .gameSessionRequestInvalid }
    public static var restrictedToAutomatch: Code { .restrictedToAutomatch }
    public static var apiNotAvailable: Code { .apiNotAvailable }
    public static var notAuthorized: Code { .notAuthorized }
    public static var connectionTimeout: Code { .connectionTimeout }
    public static var apiObsolete: Code { .apiObsolete }
    public static var iCloudUnavailable: Code { .iCloudUnavailable }
    public static var lockdownMode: Code { .lockdownMode }
    public static var appUnlisted: Code { .appUnlisted }
    public static var debugMode: Code { .debugMode }
    public static var friendListDescriptionMissing: Code { .friendListDescriptionMissing }
    public static var friendListRestricted: Code { .friendListRestricted }
    public static var friendListDenied: Code { .friendListDenied }
    public static var friendRequestNotAvailable: Code { .friendRequestNotAvailable }
}

/// `catch GKError.notAuthenticated`: a code matches a `GKError` with it, as
/// Apple's bridged error codes do.
public func ~= (code: GKError.Code, error: Error) -> Bool {
    (error as? GKError)?.code == code
}

/// A Game Center leaderboard, on `backend` (Play Games once the game installs
/// it, else nowhere). Every completion handler runs on the main actor, once:
/// signed out with `.notAuthenticated`, without Play Games with
/// `.notSupported`, and with `.communicationsFailure` when Play says no or
/// doesn't answer in time. Not actor-isolated, as Apple's isn't, and its
/// `async` calls are nonisolated, running on the caller's actor: a caller on
/// any actor awaits them, while the backend's work runs on the main actor,
/// where it lives.
public final class GKLeaderboard {
    public enum TimeScope: Int, Sendable {
        case today = 0
        case week = 1
        case allTime = 2
    }

    public enum PlayerScope: Int, Sendable {
        case global = 0
        case friendsOnly = 1
    }

    public enum LeaderboardType: Int, Sendable {
        case classic = 0
        case recurring = 1
    }

    /// One player's score.
    public final class Entry {
        public let player: GKPlayer
        public let rank: Int
        public let score: Int
        public let formattedScore: String
        public let context: Int
        public let date: Date

        init(_ score: LeaderboardScore) {
            let local = GKLocalPlayer.local
            player = local.isAuthenticated && local.gamePlayerID == score.playerID
                ? local
                : GKPlayer(gamePlayerID: score.playerID, alias: score.playerName)
            rank = score.rank
            self.score = score.score
            formattedScore = score.formattedScore
            context = score.context
            date = score.date
        }
    }

    /// Where scores go. The game installs `PlayGamesLeaderboards` at launch.
    @MainActor public static var backend: LeaderboardsBackend = LocalLeaderboards()

    public let baseLeaderboardID: String
    public let title: String?
    /// Play's leaderboards don't recur.
    public var type: LeaderboardType { .classic }
    public var groupIdentifier: String? { nil }
    public var startDate: Date? { nil }
    public var nextStartDate: Date? { nil }
    public var duration: TimeInterval { 0 }

    private init(_ info: LeaderboardInfo) {
        baseLeaderboardID = info.id
        title = info.title
    }

    /// The leaderboards in `leaderboardIDs` that Play Games knows, or all of
    /// the game's for nil.
    public static func loadLeaderboards(
        IDs leaderboardIDs: [String]?,
        completionHandler: @escaping @MainActor ([GKLeaderboard]?, Error?) -> Void
    ) {
        Task { @MainActor in
            do {
                completionHandler(try await leaderboardInfo(leaderboardIDs).map(GKLeaderboard.init), nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    nonisolated(nonsending) public static func loadLeaderboards(IDs leaderboardIDs: [String]?) async throws -> [GKLeaderboard] {
        try await leaderboardInfo(leaderboardIDs).map(GKLeaderboard.init)
    }

    /// Sends `score` to the leaderboards in `leaderboardIDs` for `player`
    /// (always the local player: Game Center accepts no other, and Play Games
    /// knows only the one signed in).
    public static func submitScore(
        _ score: Int,
        context: Int,
        player: GKPlayer,
        leaderboardIDs: [String],
        completionHandler: @escaping @MainActor (Error?) -> Void
    ) {
        Task { @MainActor in
            do {
                try await send(score, context: context, to: leaderboardIDs)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    nonisolated(nonsending) public static func submitScore(
        _ score: Int,
        context: Int,
        player: GKPlayer,
        leaderboardIDs: [String]
    ) async throws {
        try await send(score, context: context, to: leaderboardIDs)
    }

    public func submitScore(
        _ score: Int,
        context: Int,
        player: GKPlayer,
        completionHandler: @escaping @MainActor (Error?) -> Void
    ) {
        Self.submitScore(score, context: context, player: player, leaderboardIDs: [baseLeaderboardID], completionHandler: completionHandler)
    }

    nonisolated(nonsending) public func submitScore(_ score: Int, context: Int, player: GKPlayer) async throws {
        try await Self.send(score, context: context, to: [baseLeaderboardID])
    }

    /// The scores at the ranks in `range` (from 1, up to 100 at a time), the
    /// local player's, and how many players have one.
    public func loadEntries(
        for playerScope: PlayerScope,
        timeScope: TimeScope,
        range: NSRange,
        completionHandler: @escaping @MainActor (Entry?, [Entry]?, Int, Error?) -> Void
    ) {
        let id = baseLeaderboardID
        Task { @MainActor in
            do {
                let scores = try await Self.scores(id, playerScope.collection, timeScope.timeSpan, Self.ranks(range))
                completionHandler(scores.local.map(Entry.init), scores.entries.map(Entry.init), scores.total, nil)
            } catch {
                completionHandler(nil, nil, 0, error)
            }
        }
    }

    nonisolated(nonsending) public func loadEntries(
        for playerScope: PlayerScope,
        timeScope: TimeScope,
        range: NSRange
    ) async throws -> (Entry?, [Entry], Int) {
        let scores = try await Self.scores(baseLeaderboardID, playerScope.collection, timeScope.timeSpan, Self.ranks(range))
        return (scores.local.map(Entry.init), scores.entries.map(Entry.init), scores.total)
    }

    /// Play Games loads no other player's score by ID, so of `players` only
    /// the local player's comes back.
    public func loadEntries(
        for players: [GKPlayer],
        timeScope: TimeScope,
        completionHandler: @escaping @MainActor (Entry?, [Entry]?, Error?) -> Void
    ) {
        let id = baseLeaderboardID, asked = Set(players.map(\.gamePlayerID))
        Task { @MainActor in
            do {
                let scores = try await Self.scores(id, .public, timeScope.timeSpan, nil)
                let (local, entries) = Self.entries(scores, asked)
                completionHandler(local, entries, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
    }

    nonisolated(nonsending) public func loadEntries(for players: [GKPlayer], timeScope: TimeScope) async throws -> (Entry?, [Entry]) {
        let asked = Set(players.map(\.gamePlayerID))
        return Self.entries(try await Self.scores(baseLeaderboardID, .public, timeScope.timeSpan, nil), asked)
    }

    // The async entry points are nonisolated, as Apple's are, and run on
    // their caller's actor, so a caller on any actor, the main one included,
    // can await them and keep using the leaderboard and entries it gets. Each
    // reaches the backend, which lives on the main actor, through one of
    // these, handing it only Sendable values and taking Sendable values
    // back; the GameKit objects are made on the caller's side.

    @MainActor
    private static func leaderboardInfo(_ ids: [String]?) async throws -> [LeaderboardInfo] {
        do {
            return try await backend.loadLeaderboards(ids)
        } catch {
            throw GKError(leaderboard: error)
        }
    }

    @MainActor
    private static func send(_ score: Int, context: Int, to ids: [String]) async throws {
        do {
            try await backend.submitScore(score, context: context, to: ids)
        } catch {
            throw GKError(leaderboard: error)
        }
    }

    @MainActor
    private static func scores(
        _ id: String, _ collection: LeaderboardCollection, _ timeSpan: LeaderboardTimeSpan, _ ranks: ClosedRange<Int>?
    ) async throws -> LeaderboardScores {
        do {
            return try await backend.loadScores(id, timeSpan: timeSpan, collection: collection, range: ranks)
        } catch {
            throw GKError(leaderboard: error)
        }
    }

    /// Game Center's range as ranks, or `.invalidParameter`.
    private static func ranks(_ range: NSRange) throws -> ClosedRange<Int> {
        guard range.location >= 1, (1...100).contains(range.length) else {
            throw GKError(.invalidParameter)
        }
        return range.location...(range.location + range.length - 1)
    }

    private static func entries(_ scores: LeaderboardScores, _ asked: Set<String>) -> (Entry?, [Entry]) {
        let local = scores.local.map(Entry.init)
        return (local, [local].compactMap { $0 }.filter { asked.contains($0.player.gamePlayerID) })
    }
}

extension GKLeaderboard.TimeScope {
    var timeSpan: LeaderboardTimeSpan {
        switch self {
        case .today: .daily
        case .week: .weekly
        case .allTime: .allTime
        }
    }
}

extension GKLeaderboard.PlayerScope {
    var collection: LeaderboardCollection {
        self == .friendsOnly ? .friends : .public
    }
}

/// What Game Center's own interface opens to.
public enum GKGameCenterViewControllerState: Int, Sendable {
    case `default` = -1
    case leaderboards = 0
    case achievements = 1
    case challenges = 2
    case localPlayerProfile = 3
    case dashboard = 4
    case localPlayerFriendsList = 5
}

/// Game Center's access point. Android draws no widget, so `isActive` and
/// `location` are only kept; `trigger` opens Play Games' leaderboards for
/// `.leaderboards` and a leaderboard ID, and nothing for the other states.
/// Each handler runs once the request has gone to Play Games. Not
/// actor-isolated, as Apple's isn't: the request reaches the backend on the
/// main actor, at once when called there.
public final class GKAccessPoint: @unchecked Sendable {
    public enum Location: Int, Sendable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    public static let shared = GKAccessPoint()

    public var isActive = false
    public var location = Location.topLeading
    public var isVisible: Bool { false }
    public var isPresentingGameCenter: Bool { false }

    private init() {}

    public func trigger(handler: @escaping () -> Void) {
        trigger(state: .default, handler: handler)
    }

    public func trigger(state: GKGameCenterViewControllerState, handler: @escaping () -> Void) {
        if state == .leaderboards {
            Self.onMain { GKLeaderboard.backend.showLeaderboards(nil, timeSpan: .allTime, collection: .public) }
        }
        handler()
    }

    public func trigger(
        leaderboardID: String,
        playerScope: GKLeaderboard.PlayerScope,
        timeScope: GKLeaderboard.TimeScope,
        handler: (() -> Void)? = nil
    ) {
        let timeSpan = timeScope.timeSpan, collection = playerScope.collection
        Self.onMain { GKLeaderboard.backend.showLeaderboards(leaderboardID, timeSpan: timeSpan, collection: collection) }
        handler?()
    }

    private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }
}

public protocol GKGameCenterControllerDelegate: AnyObject {
    func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController)
}

/// Game Center's interface, presented as on iOS. Play Games' leaderboards
/// are an activity of their own over the game, so once presented this opens
/// them (for `.leaderboards` or a leaderboard ID; nothing for the other
/// states) and tells its delegate it has finished.
@MainActor
open class GKGameCenterViewController: UIViewController {
    public weak var gameCenterDelegate: GKGameCenterControllerDelegate?

    private let state: GKGameCenterViewControllerState
    private let leaderboard: (id: String, playerScope: GKLeaderboard.PlayerScope, timeScope: GKLeaderboard.TimeScope)?

    public init(state: GKGameCenterViewControllerState) {
        self.state = state
        leaderboard = nil
        super.init()
    }

    public init(leaderboardID: String, playerScope: GKLeaderboard.PlayerScope, timeScope: GKLeaderboard.TimeScope) {
        state = .leaderboards
        leaderboard = (leaderboardID, playerScope, timeScope)
        super.init()
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let leaderboard {
            GKAccessPoint.shared.trigger(
                leaderboardID: leaderboard.id, playerScope: leaderboard.playerScope, timeScope: leaderboard.timeScope
            )
        } else {
            GKAccessPoint.shared.trigger(state: state) {}
        }
        // After `present` returns, so the delegate can dismiss.
        Task { @MainActor [weak self] in
            guard let self else { return }
            gameCenterDelegate?.gameCenterViewControllerDidFinish(self)
        }
    }
}
