import Foundation
import GameCompat
import ShellCore

/// Reads the campaign's level JSON out of the APK and plays it.
///
/// The Gradle project stages `Assets/Levels/*.json` into `assets/levels/`
/// (`stageLevelAssets`), beside — not among — the packed art, whose own
/// `index.json` sits at the root. `AssetBundle` already knows how to read a
/// file out of an APK through SDL; this only says which files and hands them
/// to `AndroidLevels`, which is where the game's own catalog takes over.
public enum LevelBundle {
    /// Where the levels sit inside the APK.
    static let root = "levels"

    /// Loads the levels and makes them the ones in play. Logs what happened
    /// either way: the catalog checks every level's stored solution as it
    /// opens, so a failure here is a real finding, not a missing file.
    @discardableResult
    public static func install() -> Bool {
        PlayLog.sink = { Log.info($0) }
        do {
            let count = try AndroidLevels.install { name in
                AssetBundle.load("\(root)/\(name).json")
            }
            Log.info("levels: \(count) in play — \(AndroidLevels.summary)")
            return true
        } catch {
            Log.error("levels would not load: \(error) — the board falls back to the preview")
            return false
        }
    }
}
