import Foundation
import PlatformShim
import Testing

/// The argument domain the shell builds from an intent's arguments, against
/// what Foundation builds from a Mac process's argv for the same arguments.
@Suite struct LaunchArgumentDomainTests {
    @Test func pairsKeysWithValuesAndSkipsTheProcessName() {
        let domain = LaunchArgumentDomain.parse(["app_process", "-StartLevel", "level-12", "-Quiet", "YES"])
        #expect(domain["StartLevel"] as? String == "level-12")
        #expect(domain["Quiet"] as? String == "YES")
        #expect(domain.count == 2)
    }

    @Test func readsPropertyListsAndKeepsTheRestAsText() {
        let domain = LaunchArgumentDomain.parse([
            "-settings.musicEnabled", "<false/>",
            "-progress.done", "(level-1,level-2)",
            "-AppleLanguages", "(ja)",
            "-Steps", "a 3@0.05;b@0.7",
            "-TouchScript", "0.2:0.85,wait,0.8:0.1",
            "-Times", "0,1.4,2.8",
        ])
        #expect(domain["settings.musicEnabled"] as? Bool == false)
        #expect(domain["progress.done"] as? [String] == ["level-1", "level-2"])
        #expect(domain["AppleLanguages"] as? [String] == ["ja"])
        #expect(domain["Steps"] as? String == "a 3@0.05;b@0.7")
        #expect(domain["TouchScript"] as? String == "0.2:0.85,wait,0.8:0.1")
        #expect(domain["Times"] as? String == "0,1.4,2.8")
    }

    @Test func aKeyWithNoValueIsSkipped() {
        let domain = LaunchArgumentDomain.parse(["-Verbose", "-StartLevel", "level-1", "-Trailing"])
        #expect(domain["Verbose"] == nil)
        #expect(domain["StartLevel"] as? String == "level-1")
        #expect(domain["Trailing"] == nil)
    }

    /// As on Apple: nothing that starts with a dash is a value.
    @Test func dashesAreNeverValues() {
        let domain = LaunchArgumentDomain.parse(["-Offset", "-0.1", "-Lone", "-", "-Empty", "", "-Q", "\"quoted\""])
        #expect(domain["Offset"] == nil)
        #expect(domain["Lone"] == nil)
        #expect(domain["Empty"] as? String == "")
        #expect(domain["Q"] as? String == "quoted")
    }

    @Test func textThatOnlyLooksLikeAPropertyListStaysText() {
        let domain = LaunchArgumentDomain.parse(["-Odd", "(unclosed", "-Tag", "<not xml"])
        #expect(domain["Odd"] as? String == "(unclosed")
        #expect(domain["Tag"] as? String == "<not xml")
    }

    /// The same arguments given to a real process on the Mac: Foundation's
    /// own argument domain is the reference.
    @Test func matchesFoundationsOwnArgumentDomain() throws {
        #if os(macOS)
        let arguments = [
            "-StartLevel", "level-12", "-Quiet", "YES", "-settings.musicEnabled", "<false/>",
            "-progress.done", "(level-1,level-2)", "-Steps", "a 3@0.05;b@0.7",
            "-Offset", "-0.1", "-Verbose", "-Next", "x", "-Lone", "-", "-Empty", "",
            "-Spaced", "  spaced value ", "-Dict", "{a = 1;}", "-Q", "\"quoted\"",
        ]
        // JXA reads NSUserDefaults' argument domain of its own process,
        // whose argv carries the arguments after the script's file.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("argument-domain-\(UUID().uuidString).js")
        try """
            ObjC.import('Foundation');
            function run() {
              const d = $.NSUserDefaults.standardUserDefaults.volatileDomainForName($.NSArgumentDomain);
              const data = $.NSJSONSerialization.dataWithJSONObjectOptionsError(d, 0, null);
              return $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
            }
            """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        // osascript's own `-l JavaScript` lands in the domain too.
        let apple = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any]).filter { $0.key != "l" }
        let ours = LaunchArgumentDomain.parse(arguments)
        #expect(Set(apple.keys) == Set(ours.keys))
        for (key, value) in apple {
            #expect(String(describing: value) == String(describing: ours[key] ?? "missing"), "\(key)")
        }
        #endif
    }
}
