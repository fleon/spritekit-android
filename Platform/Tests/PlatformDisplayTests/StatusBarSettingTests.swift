import Foundation
import Testing
@testable import PlatformDisplay

@Suite(.serialized)
struct StatusBarSettingTests {
    private func fresh(_ change: (inout StatusBarSetting.Configuration) -> Void = { _ in }) -> UserDefaults {
        let name = "status-bar-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        var configuration = StatusBarSetting.Configuration()
        configuration.defaults = defaults
        change(&configuration)
        StatusBarSetting.configuration = configuration
        return defaults
    }

    @Test func hiddenUntilThePlayerPicks() {
        _ = fresh()
        #expect(!StatusBarSetting.isVisible)
        #expect(StatusBarSetting.isHidden)
        _ = fresh { $0.defaultVisible = true }
        #expect(StatusBarSetting.isVisible)
    }

    @Test func savesUnderItsKeyAndTellsObservers() {
        var saved: [String] = []
        let defaults = fresh {
            $0.key = "options.bar"
            $0.didSave = { saved.append($0) }
        }
        var heard: [Bool] = []
        let token = StatusBarSetting.observe { heard.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }

        StatusBarSetting.isVisible = true
        #expect(defaults.object(forKey: "options.bar") as? Bool == true)
        #expect(saved == ["options.bar"])
        StatusBarSetting.isVisible = false
        #expect(heard == [true, false])
    }

    @Test func hearsAnotherDevicesSwitch() {
        let defaults = fresh()
        var heard: [Bool] = []
        let token = StatusBarSetting.observe { heard.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }

        defaults.set(true, forKey: StatusBarSetting.configuration.key)
        StatusBarSetting.savedDataDidSync(["settings.other"])
        #expect(heard.isEmpty)
        StatusBarSetting.savedDataDidSync([StatusBarSetting.configuration.key])
        #expect(heard == [true])
    }
}
