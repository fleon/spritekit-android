import Foundation
import Testing
@testable import PlatformCore

struct LaunchArgumentReaderTests {
    private enum Screen: String { case title, worlds }

    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let name = "LaunchArgumentReaderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    @Test func readsTypedValues() {
        let reader = LaunchArgumentReader(defaults: defaults([
            "Flag": "YES", "Off": "NO", "Name": "level-3", "Slow": "8", "Count": "2", "Screen": "worlds",
            "Times": "0, 1.4,x,2.8", "Tour": "a,b, c", "Size": "1376x1032", "Step": "1/30",
        ]), enabled: true)
        #expect(reader.bool("Flag"))
        #expect(!reader.bool("Off"))
        #expect(!reader.bool("Missing"))
        #expect(reader.string("Name") == "level-3")
        #expect(reader.double("Slow") == 8)
        #expect(reader.double("Missing") == nil)
        #expect(reader.int("Count") == 2)
        #expect(reader.value("Screen") == Screen.worlds)
        #expect(reader.numbers("Times") == [0, 1.4, 2.8])
        #expect(reader.list("Tour") == ["a", "b", "c"])
        #expect(reader.list("Missing") == nil)
        #expect(reader.size("Size") == CGSize(width: 1376, height: 1032))
        #expect(reader.fraction("Step") == 1.0 / 30)
        #expect(reader.isSet("Count") && !reader.isSet("Missing"))
        #expect(reader.bool("Off", unset: true, release: true) == false)
        #expect(reader.bool("Missing", unset: true, release: false))
    }

    @Test func releaseBuildsTakeTheirFixedValues() {
        let reader = LaunchArgumentReader(defaults: defaults(["Flag": "YES", "Name": "x", "Slow": "8"]), enabled: false)
        #expect(!reader.bool("Flag"))
        #expect(reader.bool("Flag", release: true))
        #expect(reader.string("Name") == nil)
        #expect(reader.double("Slow", release: 1) == 1)
        #expect(!reader.isSet("Flag"))
        #expect(reader.list("Name", release: []) == [])
    }
}
