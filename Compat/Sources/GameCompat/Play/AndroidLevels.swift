import Foundation
import SpriteKitShim

/// Gets the campaign's levels into `LevelCatalog` on Android, and hands the
/// shell a scene that plays one.
///
/// The catalog reads its own JSON out of `Bundle.main`, and a file inside an
/// APK is not a path on disk, so `Bundle.main` finds nothing there. Rather
/// than teach the catalog a second way to read, this goes in through the
/// door it already has: `LevelCatalog.contents(from:revision:)` takes the
/// same files as a dictionary and `use(_:)` plays them — the seam the Level
/// Designer's feed uses. Nothing in `Source/` changes.
///
/// That door checks its levels as it opens: it refuses a set unless every
/// file decodes **and** every level's stored solution replays to a complete
/// board through `GameEngine`. So installing the catalog on a device is also
/// 300 levels' worth of proof that the rules port — about 4,500 moves.
public enum AndroidLevels {
    public enum Problem: Error, CustomStringConvertible {
        case noIndex
        case missing([String])
        case incomplete
        case unsolved(String)

        public var description: String {
            switch self {
            case .noIndex: return "no Worlds.json"
            case let .missing(names): return "missing \(names.joined(separator: ", "))"
            case .incomplete: return "a level file is missing, cut short or will not decode"
            case let .unsolved(id): return "\(id)'s stored solution does not play through"
            }
        }
    }

    /// What `Worlds.json` and `SecretWorlds.json` look like from outside the
    /// catalog, which keeps its own copy of this private.
    private struct Index: Decodable {
        struct Entry: Decodable {
            let id: String
            let file: String
        }

        let worlds: [Entry]
    }

    private static let fileExtension = "json"
    /// The files that are not a world's, read whether or not they are listed.
    private static let extras = ["TipOverrides", "SecretWorlds"]

    /// Reads the level JSON through `read` (which answers by bare name, e.g.
    /// `"Garden"`) and plays it. Returns how many levels came in.
    @discardableResult
    public static func install(reading read: (String) -> Data?) throws -> Int {
        guard let indexData = read("Worlds"),
              let index = try? JSONDecoder().decode(Index.self, from: indexData) else {
            throw Problem.noIndex
        }

        var files: [String: Data] = ["Worlds.\(fileExtension)": indexData]
        var missing: [String] = []

        for name in index.worlds.map(\.file) {
            guard let data = read(name) else {
                missing.append(name)
                continue
            }
            files["\(name).\(fileExtension)"] = data
        }
        // TipOverrides must be there (the catalog is strict about it);
        // SecretWorlds need not be, but without it the catalog falls back to
        // `Bundle.main` for the Mainframe, which on Android has nothing.
        for name in extras {
            guard let data = read(name) else {
                if name == "TipOverrides" { missing.append(name) }
                continue
            }
            files["\(name).\(fileExtension)"] = data
            if name == "SecretWorlds",
               let secret = try? JSONDecoder().decode(Index.self, from: data) {
                for file in secret.worlds.map(\.file) {
                    files["\(file).\(fileExtension)"] = read(file)
                }
            }
        }
        files = files.compactMapValues { $0 }
        guard missing.isEmpty else { throw Problem.missing(missing) }

        // The revision labels where the levels came from; it reaches only
        // the solve log, which is deliberately off on Android (see
        // Android/README.md), so it names the source and goes no further.
        switch LevelCatalog.contents(from: files, revision: "apk") {
        case let .success(contents):
            LevelCatalog.use(contents)
            return contents.levels.count
        case .failure(.incomplete):
            throw Problem.incomplete
        case let .failure(.unsolved(id)):
            throw Problem.unsolved(id)
        }
    }

    /// How many worlds and levels are in play, for the shell to log.
    public static var summary: String {
        let worlds = LevelCatalog.worlds
        let secret = LevelCatalog.secretWorlds
        return "\(worlds.count) worlds, \(LevelCatalog.levels.count) levels"
            + (secret.isEmpty ? "" : " (+ \(secret.count) secret, \(secret.reduce(0) { $0 + $1.levels.count }) levels)")
    }

    /// A scene playing `levelID`, or the campaign's first level.
    public static func scene(levelID: String? = nil, size: CGSize) -> SKScene? {
        PlayScene(levelID: levelID, size: size)
    }

    /// Opens `levelID` (or the campaign's first level) in `view` the way the
    /// game opens a level: `TransitionManager` fades to the loading screen,
    /// which builds the level off the main thread and fades to it. False if
    /// the catalog has no such level.
    @discardableResult
    public static func present(levelID: String? = nil, in view: SKView) -> Bool {
        guard let entry = levelID.flatMap(LevelCatalog.level(withID:)) ?? LevelCatalog.levels.first else { return false }
        TransitionManager.present(.play(entry), in: view)
        return true
    }

    /// `DesignSystem.sceneSize(for:)`: the scene's size in points for a view
    /// this big, so a design point is a point. The real table rather than a
    /// copy of its numbers.
    public static func sceneSize(forViewSize size: CGSize) -> CGSize {
        DesignSystem.sceneSize(for: size)
    }
}
