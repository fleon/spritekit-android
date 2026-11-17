import CAndroidShell
import SpriteKitShim

/// logcat, under one tag. From any thread: Android's log is thread-safe,
/// and decodes and builds off the frame thread log too.
///
///     adb logcat -s <AppIdentity.name>
nonisolated public enum Log {
    public static var tag: String { AppIdentity.current.name }

    public static func info(_ message: @autoclosure () -> String) {
        ska_log(Int32(ANDROID_LOG_INFO.rawValue), tag, message())
    }

    public static func warning(_ message: @autoclosure () -> String) {
        ska_log(Int32(ANDROID_LOG_WARN.rawValue), tag, message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        ska_log(Int32(ANDROID_LOG_ERROR.rawValue), tag, message())
    }
}
