import CAndroidShell
import Foundation
import ShellCore
import SpriteKitShim

/// Makes `Bundle.main` answer for the rigs.
///
/// `RigData` asks `Bundle.main.url(forResource: "RigGardenA", withExtension: "json")`
/// and then reads it with `Data(contentsOf:)`; `RigNode` asks for the `.png`
/// and loads it with `UIImage(contentsOfFile:)`. Neither may change — they
/// are the game's own files — so both have to come back a real path.
///
/// Inside the APK there are no real paths: an asset is an entry in a zip,
/// which is why the packed art goes through `SDL_LoadFile` rather than
/// through `FileManager`. So a rig is copied out the first time it is asked
/// for, into the app's cache directory, and the URL points there. It is
/// copied once per install: the second ask finds the file already written.
///
/// Only the rigs actually played are copied, which for a level is four
/// Switchlings and whatever mechanisms the board has — a few hundred
/// kilobytes, not the whole 11 MB.
///
/// The alternative was to keep the pages in the APK and have the renderer
/// read them through SDL, which would save copying the PNGs; it was not
/// worth making a rig's `.json` and its `.png` resolve two different ways.
public enum RigBundle {
    /// Where the rigs are staged inside the APK, from
    /// `npm run art -- --android` (`android-art.js`'s `rigs`).
    static let root = "rigs"

    /// Installs the provider. Call once, before the first scene builds.
    public static func install() {
        guard let cache = SDL_GetAndroidCachePath().map({ String(cString: $0) }) else {
            Log.error("no Android cache path — rigs cannot be unpacked, so nothing will animate")
            return
        }
        let directory = URL(fileURLWithPath: cache).appendingPathComponent(root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The sound effects and the soundtrack too, which a share film mixes
        // (`AudioManager.url(of:)`): staged under `assets/audio/` by Gradle.
        let audio = URL(fileURLWithPath: cache).appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        BundleResources.provider = { name, ext in
            switch ext {
            case "wav": unpack("\(name).\(ext)", from: "audio/SFX", into: audio)
            case "m4a": unpack("\(name).\(ext)", from: "audio/Music", into: audio)
            default: unpack("\(name).\(ext)", into: directory)
            }
        }
    }

    /// The staged file, copied out of the APK if it is not out yet.
    static func unpack(_ file: String, from folder: String = root, into directory: URL) -> URL? {
        let url = directory.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = AssetBundle.load("\(folder)/\(file)") else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.error("\(file) would not unpack: \(error)")
            return nil
        }
    }
}
