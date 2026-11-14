import Foundation
import PlatformShim
import Testing

/// The argument domain the shell builds from an intent's arguments, against
/// what Foundation builds from a Mac process's argv for the same arguments.
@Suite struct LaunchArgumentDomainTests {
    @Test func pairsKeysWithValuesAndSkipsTheProcessName() {
        let domain = LaunchArgumentDomain.parse(["app_process", "-StartLevel", "reef-12", "-HideTips", "YES"])
        #expect(domain["StartLevel"] as? String == "reef-12")
        #expect(domain["HideTips"] as? String == "YES")
        #expect(domain.count == 2)
    }

    @Test func readsPropertyListsAndKeepsTheRestAsText() {
        let domain = LaunchArgumentDomain.parse([
            "-settings.musicEnabled", "<false/>",
            "-progress.cleared", "(garden-1,garden-2)",
            "-AppleLanguages", "(ja)",
            "-Stills", "move 3@0.05;celebrate@0.7",
            "-TouchScript", "0.2:0.85,wait,0.8:0.1",
            "-SolveTimes", "0,1.4,2.8",
        ])
        #expect(domain["settings.musicEnabled"] as? Bool == false)
        #expect(domain["progress.cleared"] as? [String] == ["garden-1", "garden-2"])
        #expect(domain["AppleLanguages"] as? [String] == ["ja"])
        #expect(domain["Stills"] as? String == "move 3@0.05;celebrate@0.7")
        #expect(domain["TouchScript"] as? String == "0.2:0.85,wait,0.8:0.1")
        #expect(domain["SolveTimes"] as? String == "0,1.4,2.8")
    }

    @Test func aKeyWithNoValueIsSkipped() {
        let domain = LaunchArgumentDomain.parse(["-Markers", "-StartLevel", "garden-1", "-Trailing"])
        #expect(domain["Markers"] == nil)
        #expect(domain["StartLevel"] as? String == "garden-1")
        #expect(domain["Trailing"] == nil)
    }

    /// As on Apple: nothing that starts with a dash is a value.
    @Test func dashesAreNeverValues() {
        let domain = LaunchArgumentDomain.parse(["-BoardCentre", "-0.1", "-Lone", "-", "-Empty", "", "-Q", "\"quoted\""])
        #expect(domain["BoardCentre"] == nil)
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
            "-StartLevel", "reef-12", "-HideTips", "YES", "-settings.musicEnabled", "<false/>",
            "-progress.cleared", "(garden-1,garden-2)", "-Stills", "move 3@0.05;celebrate@0.7",
            "-BoardCentre", "-0.1", "-Markers", "-Next", "x", "-Lone", "-", "-Empty", "",
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
