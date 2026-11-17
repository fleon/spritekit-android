import CAndroidShell
import Foundation
import ShellCore

/// Where the soundtrack and the sound effects sit inside the APK.
///
/// The game's Gradle project stages its music and sound effects — the same
/// files the Apple build bundles, not a second encoding — under `audio/`
/// (`audio/Music`, `audio/SFX`), clear of the art at the assets root. Both
/// are in the app's `noCompress` list, so they are stored rather than
/// deflated: the music needs a file descriptor into the APK to decode
/// without being copied out first, and a WAV gains nothing from being
/// deflated anyway.
public enum AudioAssets {
    public static let root = "audio"
    /// The containers a soundtrack may come in, the first one found winning:
    /// AAC in `.m4a`, MP3 or Ogg, which MediaCodec decodes through the same C.
    public static let musicExtensions = ["m4a", "mp3", "ogg"]
    public static let soundExtension = "wav"

    /// Where `name` is: the first of `musicExtensions` the APK holds, or the
    /// first's path when none is there (so the error names a file).
    public static func music(_ name: String) -> String {
        let paths = musicExtensions.map { "\(root)/Music/\(name).\($0)" }
        var info = SDL_PathInfo()
        return paths.first { SDL_GetPathInfo($0, &info) } ?? paths[0]
    }

    public static func sound(_ name: String) -> String {
        "\(root)/SFX/\(name).\(soundExtension)"
    }

    /// Reads a whole file out of the APK's assets, as `AssetBundle` does for
    /// the art.
    public static func load(_ path: String) -> Data? {
        var size = 0
        guard let raw = SDL_LoadFile(path, &size), size > 0 else { return nil }
        defer { SDL_free(raw) }
        return Data(bytes: raw, count: size)
    }
}
