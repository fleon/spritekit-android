import CAndroidShell
import FilmMedia
import Foundation
import PlatformShim
import ShellCore
import SpriteKitShim

/// What writing a video needs from the platform, set up before anything asks.
enum FilmSetup {
    /// Points Foundation's temporary directory at the app's cache. Corelibs
    /// Foundation answers `/data/local/tmp/` on Android when `TMPDIR` isn't
    /// set, which an app can't write; the film writes there
    /// (`FileManager.default.temporaryDirectory`), and `FilmProvider` hands
    /// out files from under the cache. Before anything reads it.
    static func useCacheForTemporaryFiles() {
        guard let cache = SDL_GetAndroidCachePath().map({ String(cString: $0) }) else { return }
        setenv("TMPDIR", cache + "/", 1)
    }

    /// MediaCodec for the asset writer and the soundtrack's AAC, the share
    /// sheet through `MainActivity.shareFile`, and the clipboard through SDL.
    static func install() {
        NDKMediaBackend.install()
        SystemShare.sheet = { request in
            guard let file = request.files.first else {
                Log.error("a share with no file — Android's share sheet sends one")
                return false
            }
            let shared = ska_share_file(file.path, ShareRequest.mimeType(of: file), request.text)
            if !shared { Log.error("the share sheet could not be opened for \(file.lastPathComponent)") }
            return shared
        }
        SystemShare.pasteboard = { SDL_SetClipboardText($0) }
    }
}
