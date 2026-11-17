import CAndroidShell
import Foundation
import ShellCore
import SpriteKitShim

/// Makes `Bundle.main` answer for the game's own resources.
///
/// The game asks the main bundle for its rigs (`RigData`, `RigNode`), its
/// levels (`LevelCatalog`: `Worlds.json`, each world's file, the tips'
/// overrides, the title's showcase), its fonts (`FontRegistry`) and each
/// language's strings (`Localization`, through `path(forResource:ofType:
/// "lproj")` and `Bundle(path:)`). None of those calls may change, so each
/// has to come back a real path; inside the APK there are none, since an
/// asset is an entry in a zip. So a file is copied out the first time it is
/// asked for in a run, into the app's cache, and the path points there.
/// Copied afresh each run rather than once per install, since the cache
/// outlives an update and a level or a string may have changed in it.
///
/// Where each kind is staged in the APK (`app/build.gradle.kts`): the rigs
/// with the packed art (`rigs/`), the levels (`levels/`), the fonts
/// (`fonts/`) and the strings (`lproj/<language>.lproj/`).
public enum ResourceBundle {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var unpacked: Set<String> = []
    nonisolated(unsafe) private static var cache: URL?

    /// The strings each language's folder holds.
    static let stringTables = ["Localizable.strings", "Content.strings"]

    /// Installs the providers. Call once, before the first scene builds.
    public static func install() {
        guard let path = SDL_GetAndroidCachePath().map({ String(cString: $0) }) else {
            Log.error("no Android cache path — nothing can be read from Bundle.main")
            return
        }
        cache = URL(fileURLWithPath: path).appendingPathComponent("bundle")
        BundleResources.provider = { name, ext in
            unpack(folder(for: name, ext: ext), "\(name).\(ext)")
        }
        BundleResources.folderProvider = { name, ext in
            guard ext == "lproj" else { return nil }
            let folder = "lproj/\(name).lproj"
            let unpackedAny = stringTables.compactMap { unpack(folder, $0) }
            return unpackedAny.isEmpty ? nil : cache?.appendingPathComponent(folder).path
        }
    }

    /// Where a resource of this kind sits in the APK.
    private static func folder(for name: String, ext: String) -> String {
        switch ext {
        case "json" where name.hasPrefix("Rig"), "png": return "rigs"
        case "json": return "levels"
        case "ttf": return "fonts"
        // The audio, where `AudioAssets` reads it, for a game that opens
        // its sound files itself (to read a sound's length, say).
        case "wav": return "audio/SFX"
        case "m4a", "mp3", "ogg": return "audio/Music"
        default: return ext
        }
    }

    /// The file, copied out of the APK if it is not out yet this run.
    static func unpack(_ folder: String, _ file: String) -> URL? {
        guard let cache else { return nil }
        let key = "\(folder)/\(file)"
        let directory = cache.appendingPathComponent(folder)
        let url = directory.appendingPathComponent(file)
        lock.lock()
        defer { lock.unlock() }
        if unpacked.contains(key) { return url }
        guard let data = AssetBundle.load(key) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            unpacked.insert(key)
            return url
        } catch {
            Log.error("\(key) would not unpack: \(error)")
            return nil
        }
    }
}
