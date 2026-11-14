import Foundation

/// The arguments the app was started with.
///
/// Not `CommandLine.arguments`: that reads the process's own argv, and an
/// Android app's process is the zygote's — it carries nothing the launcher
/// or `adb` passed. What SDL hands `SDL_main` is the array
/// `SDLActivity.getArguments()` returned, which `MainActivity` fills from
/// the intent's `args` extra:
///
///     adb shell am start -n com.fleon.switchlings/.MainActivity \
///         --esa args "-AudioProbe"
///
/// (or `--es args64 <base64 of a JSON array>`, which survives any quoting:
/// see `MainActivity.getArguments`, and `Android/Scripts/launch.sh`).
///
/// So this is where the port's answer to `LaunchArguments` begins: the whole
/// Apple testing story (`-StartLevel`, `-AutoSolve`, `-Markers`, …) is
/// launch arguments, and this is the only way they reach an Android build.
public enum ShellArguments {
    public private(set) static var values: [String] = []

    /// Called once, from `SDL_main`, before anything reads them.
    public static func install(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) {
        guard let argv, argc > 0 else {
            values = []
            return
        }
        values = (0..<Int(argc)).compactMap { argv[$0].map { String(cString: $0) } }
        // The game, like any Apple app, may ask `ProcessInfo` for them, as
        // on Apple, where a launch's arguments are the process's argv.
        // Foundation's `ProcessInfo` reads `CommandLine.arguments` once, the
        // first time it's asked, which is after this.
        setCommandLine(values)
    }

    @available(*, deprecated, message: "only so the setter's own deprecation stays here")
    private static func setCommandLine(_ values: [String]) {
        CommandLine.arguments = values
    }

    public static func has(_ name: String) -> Bool {
        values.contains(name)
    }

    /// The value after `name`, as `-StartLevel reef-12` gives it.
    public static func value(after name: String) -> String? {
        guard let index = values.firstIndex(of: name), index + 1 < values.count else { return nil }
        return values[index + 1]
    }
}
