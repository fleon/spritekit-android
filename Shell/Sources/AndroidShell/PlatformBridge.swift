import CAndroidShell
import Foundation
import PlatformShim
import ShellCore

/// The JNI half of `PlatformChannel`: calls go to `MainActivity.platformCall`
/// and events come back from `platformDrain`, both JSON as UTF-8 bytes
/// (`switchlings_platform_*` in `shim.c`).
enum PlatformBridge {
    /// Registers the native method Java wakes the frame loop with, and
    /// installs the channel the game's platform managers talk through.
    static func install() {
        guard switchlings_platform_install() else {
            Log.error("platform services: could not register with MainActivity — no Play Billing, Play Games or haptics")
            return
        }
        PlatformChannel.shared = PlatformChannel { name, arguments in
            arguments.withUnsafeBytes { raw -> Data? in
                var length: Int32 = 0
                let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                guard let answer = switchlings_platform_call(name, bytes, Int32(raw.count), &length) else { return nil }
                defer { free(answer) }
                return Data(bytes: answer, count: Int(length))
            }
        }
    }

    /// Hands the game whatever Java has queued. Once a frame; a flag read
    /// when nothing is waiting.
    static func deliverPendingEvents() {
        guard switchlings_platform_take_pending(), let channel = PlatformChannel.shared else { return }
        var length: Int32 = 0
        guard let batch = switchlings_platform_drain(&length) else { return }
        defer { free(batch) }
        channel.deliver(Data(bytes: batch, count: Int(length)))
    }
}
