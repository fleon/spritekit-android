import Foundation
import PlatformCore
import SpriteKitShim
import Testing
@testable import PlatformDisplay

/// Each test starts DisplaySettings over on a store of its own.
private func fresh(_ change: (inout DisplaySettings.Configuration) -> Void = { _ in }) -> UserDefaults {
    let name = "display-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    var configuration = DisplaySettings.Configuration()
    configuration.defaults = defaults
    configuration.isLowPower = { false }
    configuration.isSimulator = false
    change(&configuration)
    DisplaySettings.configuration = configuration
    DisplaySettings.screenMaximum = configuration.defaultFrameRate
    return defaults
}

struct DisplaySettingsTests {
    @Test func autoGovernsUntilItChoosesAndThenKeepsTheChoice() {
        _ = fresh()
        var choices = DisplaySettings.choices
        #expect(choices == .init(rate: 60, scales: RenderScaleGovernor.autoSteps, governs: true, decided: nil))
        DisplaySettings.noteAutoChosen(.init(rate: 60, scale: 0.875))
        choices = DisplaySettings.choices
        #expect(choices.governs && choices.decided == 0.875)
        // Kept per rate.
        #expect(DisplaySettings.autoScale(rate: 30) == nil)
    }

    @Test func picksPersistAndHold() {
        let defaults = fresh()
        var saved: [String] = []
        DisplaySettings.configuration.didSave = { saved.append($0) }
        DisplaySettings.pickedFrameRate = 30
        DisplaySettings.pickedGraphics = .low
        #expect(defaults.integer(forKey: "settings.frameRate") == 30)
        #expect(defaults.double(forKey: "settings.renderScale") == 0.625)
        #expect(saved == ["settings.frameRate", "settings.renderScale"])
        #expect(DisplaySettings.choices == .init(rate: 30, scales: [0.625], governs: false, decided: nil))
        DisplaySettings.pickedGraphics = nil
        DisplaySettings.pickedFrameRate = nil
        #expect(defaults.object(forKey: "settings.renderScale") == nil)
        #expect(DisplaySettings.choices.governs)
    }

    @Test func aRateTheScreenCantDrawFallsBack() {
        _ = fresh()
        #expect(DisplaySettings.frameRates == [30, 60])
        DisplaySettings.pickedFrameRate = 120
        #expect(DisplaySettings.pickedFrameRate == 60)
        DisplaySettings.screenMaximum = 120
        #expect(DisplaySettings.frameRates == [30, 60, 120])
        #expect(DisplaySettings.pickedFrameRate == 120)
    }

    @Test func lowPowerHoldsAPickedRateAndAutoPacesTheScreen() {
        _ = fresh { $0.isLowPower = { true } }
        DisplaySettings.screenMaximum = 120
        DisplaySettings.pickedFrameRate = 120
        #expect(DisplaySettings.choices.rate == 60)
        DisplaySettings.pickedFrameRate = nil
        DisplaySettings.screenMaximum = 50
        #expect(DisplaySettings.autoFrameRate == 50)
    }

    @Test func aPinnedScaleStandsAndAutoChoosesNothing() {
        let defaults = fresh { $0.pinnedRenderScale = { 0.5 } }
        #expect(DisplaySettings.choices == .init(rate: 60, scales: [0.5], governs: false, decided: nil))
        DisplaySettings.noteAutoChosen(.init(rate: 60, scale: 0.75))
        #expect(defaults.object(forKey: "settings.graphicsAuto60") == nil)
    }

    @Test func aSimulatorDrawsEveryPixelUnlessPicked() {
        _ = fresh { $0.isSimulator = true }
        #expect(DisplaySettings.choices == .init(rate: 60, scales: [1], governs: false, decided: nil))
        DisplaySettings.pickedGraphics = .medium
        #expect(DisplaySettings.choices.scales == [0.75])
    }

    @Test func aTierPickedWhenThereWereThreeKeepsItsShare() {
        let defaults = fresh { $0.keyPrefix = "game." }
        defaults.set("low", forKey: "game.graphics")
        #expect(DisplaySettings.pickedGraphics == .lowest)
        defaults.set("high", forKey: "game.graphics")
        #expect(DisplaySettings.pickedGraphics == .highest)
        DisplaySettings.pickedGraphics = .high
        #expect(defaults.object(forKey: "game.graphics") == nil)
        #expect(DisplaySettings.Graphics.nearest(0.7) == .medium)
        #expect(DisplaySettings.Graphics.allCases.map(\.renderScale) == RenderScaleGovernor.steps)
    }

    @Test func obsoleteKeysGoOnce() {
        let defaults = fresh { $0.obsoleteKeys = ["old.measure"] }
        defaults.set(3, forKey: "old.measure")
        _ = DisplaySettings.choices
        #expect(defaults.object(forKey: "old.measure") == nil)
    }

    @Test func runningChangesAreAnnounced() {
        _ = fresh()
        var logged: [String] = []
        DisplaySettings.configuration.log = { logged.append($0) }
        var heard = 0
        let observer = NotificationCenter.default.addObserver(forName: DisplaySettings.runningDidChange, object: nil, queue: nil) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        DisplaySettings.running = .init(rate: 30, scale: 0.5)
        DisplaySettings.running = .init(rate: 30, scale: 0.5)
        #expect(heard == 1 && logged.count == 1)
    }

    @Test func aFrameHasAsManyRefreshesAsItsRateTakes() {
        _ = fresh()
        #expect(abs(DisplaySettings.frameBudget(rate: 60, refresh: 50) - 0.02) < 1e-9)
        #expect(abs(DisplaySettings.frameBudget(rate: 30, refresh: 50) - 0.04) < 1e-9)
        #expect(abs(DisplaySettings.frameBudget(rate: 60, refresh: 120) - 1.0 / 60) < 1e-9)
        #expect(abs(DisplaySettings.frameBudget(rate: 60, refresh: nil) - 1.0 / 60) < 1e-9)
    }

    @Test func syncedPicksApplyAtOnce() {
        _ = fresh()
        var heard = 0
        let observer = NotificationCenter.default.addObserver(forName: DisplaySettings.choicesDidChange, object: nil, queue: nil) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        DisplaySettings.savedDataDidSync(["progress"])
        DisplaySettings.savedDataDidSync(["settings.frameRate"])
        #expect(heard == 1)
    }
}

/// The shell's `GameHost` display members, as it declares them.
@MainActor
private protocol ShellDisplayMembers {
    static var displayChoices: (rate: Int, scales: [Double], governs: Bool, decided: Double?) { get }
    static var pinnedRenderScale: Double? { get }
    static func observeDisplayChoices(_ changed: @escaping @MainActor () -> Void)
    static func isMeasured(_ scene: SKScene?) -> Bool
    static func setRunning(rate: Int, scale: Double)
    static func noteAutoChosen(rate: Int, scale: Double)
}

private final class Host: ShellDisplayMembers, DisplaySettingsHost {}

struct DisplaySettingsHostTests {
    @Test func theHostsMembersComeFromTheSettings() {
        let defaults = fresh { $0.isMeasured = { $0 is MeasuredScene } }
        let host: any ShellDisplayMembers.Type = Host.self
        #expect(host.displayChoices.governs)
        host.noteAutoChosen(rate: 60, scale: 0.75)
        #expect(defaults.double(forKey: "settings.graphicsAuto60") == 0.75)
        #expect(host.displayChoices.decided == 0.75)
        host.setRunning(rate: 60, scale: 0.75)
        #expect(DisplaySettings.running == .init(rate: 60, scale: 0.75))
        #expect(host.isMeasured(MeasuredScene(size: .zero)) && !host.isMeasured(SKScene(size: .zero)) && !host.isMeasured(nil))
        #expect(host.pinnedRenderScale == nil)
    }
}

private final class MeasuredScene: SKScene {}
