import CAndroidShell

/// logcat, under one tag.
///
///     adb logcat -s Switchlings
public enum Log {
    public static let tag = "Switchlings"

    public static func info(_ message: @autoclosure () -> String) {
        switchlings_log(Int32(ANDROID_LOG_INFO.rawValue), tag, message())
    }

    public static func warning(_ message: @autoclosure () -> String) {
        switchlings_log(Int32(ANDROID_LOG_WARN.rawValue), tag, message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        switchlings_log(Int32(ANDROID_LOG_ERROR.rawValue), tag, message())
    }
}
