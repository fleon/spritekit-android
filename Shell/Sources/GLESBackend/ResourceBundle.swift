import CAndroidShell
import Foundation
import ShellCore
import SpriteKitShim

/// Makes `Bundle.main` answer for the game's own resources.
///
/// A game asks the main bundle for its data files (JSON, PNG pages that
/// aren't packed art), its fonts and each language's strings (through
/// `path(forResource:ofType: "lproj")` and `Bundle(path:)`). None of those
/// calls may change, so each
/// has to come back a real path; inside the APK there are none, since an
/// asset is an entry in a zip. So a file is copied out the first time it is
/// asked for in a run, into the app's cache, and the path points there.
/// Copied afresh each run rather than once per install, since the cache
/// outlives an update and a file or a string may have changed in it.
///
/// Where each file is staged in the APK is the game's Gradle project's to
/// say (`Shell.start(resourceFolder:)`): by default fonts in `fonts/` and
/// audio where `AudioAssets` plays it from (`audio/SFX`, `audio/Music`), so
/// a game that opens a sound file itself (to read its length, say) finds the
/// same file, and everything else in `resources/`. The strings are always in
/// `lproj/<language>.lproj/`.
public enum ResourceBundle {
    /// The APK folder a resource named `name` with extension `ext` is staged
    /// in.
    public typealias FolderRule = @Sendable (_ name: String, _ ext: String) -> String

    /// Fonts in `fonts/`, sounds in `audio/SFX/`, music in `audio/Music/`,
    /// everything else in `resources/`.
    public static let defaultFolder: FolderRule = { _, ext in
        switch ext {
        case "ttf", "otf": return "fonts"
        case "wav": return "audio/SFX"
        case "m4a", "mp3", "ogg": return "audio/Music"
        default: return "resources"
        }
    }

    nonisolated(unsafe) static var folder: FolderRule = defaultFolder

    private static let lock = NSLock()
    nonisolated(unsafe) private static var unpacked: Set<String> = []
    nonisolated(unsafe) private static var cache: URL?

    /// The strings each language's folder holds.
    static let stringTables = ["Localizable.strings", "Content.strings"]

    /// Installs the providers. Call once, before the first scene builds.
    public static func install(folder rule: @escaping FolderRule = defaultFolder) {
        folder = rule
        guard let path = SDL_GetAndroidCachePath().map({ String(cString: $0) }) else {
            Log.error("no Android cache path — nothing can be read from Bundle.main")
            return
        }
        cache = URL(fileURLWithPath: path).appendingPathComponent("bundle")
        BundleResources.provider = { name, ext in
            unpack(folder(name, ext), "\(name).\(ext)")
        }
        BundleResources.folderProvider = { name, ext in
            guard ext == "lproj" else { return nil }
            let folder = "lproj/\(name).lproj"
            let unpackedAny = stringTables.compactMap { unpack(folder, $0) }
            return unpackedAny.isEmpty ? nil : cache?.appendingPathComponent(folder).path
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
