import CAndroidShell
import Foundation
import ShellCore

/// Where the soundtrack and the sound effects sit inside the APK.
///
/// The Gradle project stages `Assets/Music` and `Assets/SFX` — the same
/// files the Apple build bundles, not a second encoding — under `audio/`,
/// clear of the art at the assets root. Both are in the app's `noCompress`
/// list, so they are stored rather than deflated: the music needs a file
/// descriptor into the APK to decode without being copied out first, and a
/// WAV gains nothing from being deflated anyway.
public enum AudioAssets {
    public static let root = "audio"
    /// The soundtrack's container, as the game ships it: Switchlings' m4a
    /// (AAC), Hue Rings' mp3. MediaCodec takes the format from the file
    /// itself, so only the name changes; a game sets this in its entry's
    /// `configure`, before the audio device opens.
    public nonisolated(unsafe) static var musicExtension = "m4a"
    public static let soundExtension = "wav"

    public static func music(_ name: String) -> String {
        "\(root)/Music/\(name).\(musicExtension)"
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
