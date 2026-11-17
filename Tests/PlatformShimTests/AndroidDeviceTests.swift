import Foundation
import PlatformShim
import Testing

/// The device as `MainActivity` hands it over.
@Suite struct AndroidDeviceTests {
    @Test func readsWhatMainActivityExports() {
        let device = AndroidDevice(environment: [
            "SKA_DEVICE_MODEL": "Google Pixel 9",
            "SKA_OS_VERSION": "17",
            "SKA_EMULATOR": "0",
        ])
        #expect(device.model == "Google Pixel 9")
        #expect(device.osVersion == "17")
        #expect(!device.isEmulator)
    }

    @Test func nothingExportedIsAPhoneWithNoName() {
        let device = AndroidDevice(environment: [:])
        #expect(device.model.isEmpty && device.osVersion.isEmpty && !device.isEmulator)
    }
}

/// The beta switch, one of the app's build properties, as `MainActivity`
/// hands it over.
@Suite struct BetaBuildTests {
    @Test func onlyAOneIsOn() {
        #expect(BetaBuild(environment: ["SKA_BETA": "1"]).isOn)
        #expect(!BetaBuild(environment: ["SKA_BETA": "0"]).isOn)
        #expect(!BetaBuild(environment: [:]).isOn)
    }
}

/// A game's launch defaults: added only where they apply and the launch
/// doesn't name them.
@Suite struct LaunchDefaultsTests {
    let defaults = LaunchDefaults(onEmulator: ["Recording": false], outsideBeta: ["RemoteContent": false, "Recording": false])
    let emulator = AndroidDevice(environment: ["SKA_EMULATOR": "1"])
    let phone = AndroidDevice(environment: ["SKA_EMULATOR": "0"])

    @Test func noneAddsNothing() {
        #expect(LaunchDefaults.none.apply(to: [:], device: emulator, beta: BetaBuild(isOn: false)).isEmpty)
    }

    @Test func anEmulatorTakesItsDefaults() {
        let arguments = defaults.apply(to: ["StartLevel": "level-12"], device: emulator, beta: BetaBuild(isOn: true))
        #expect(arguments["Recording"] as? Bool == false)
        #expect(arguments["RemoteContent"] == nil)
        #expect(arguments["StartLevel"] as? String == "level-12")
    }

    @Test func aPhoneInABetaBuildKeepsItsArguments() {
        #expect(defaults.apply(to: [:], device: phone, beta: BetaBuild(isOn: true)).isEmpty)
    }

    @Test func outsideABetaTheBuildsDefaultsApply() {
        let arguments = defaults.apply(to: [:], device: phone, beta: BetaBuild(isOn: false))
        #expect(arguments["RemoteContent"] as? Bool == false)
        #expect(arguments["Recording"] as? Bool == false)
    }

    @Test func theLaunchWins() {
        let arguments = defaults.apply(to: ["Recording": "YES", "RemoteContent": "YES"], device: emulator, beta: BetaBuild(isOn: false))
        #expect(arguments["Recording"] as? String == "YES")
        #expect(arguments["RemoteContent"] as? String == "YES")
    }
}
