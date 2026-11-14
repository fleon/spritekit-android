import Foundation
import PlatformShim
import Testing

/// The device the beta's solve log names, as `MainActivity` hands it over,
/// and the emulator's `-Playtest NO`.
@Suite struct AndroidDeviceTests {
    @Test func readsWhatMainActivityExports() {
        let device = AndroidDevice(environment: [
            "SWITCHLINGS_DEVICE_MODEL": "Google Pixel 6",
            "SWITCHLINGS_OS_VERSION": "17",
            "SWITCHLINGS_EMULATOR": "0",
        ])
        #expect(device.model == "Google Pixel 6")
        #expect(device.osVersion == "17")
        #expect(!device.isEmulator)
    }

    @Test func anEmulatorRecordsNoSolvesUnlessTold() {
        let emulator = AndroidDevice(environment: ["SWITCHLINGS_EMULATOR": "1"])
        #expect(emulator.arguments([:])["Playtest"] as? Bool == false)
        #expect(emulator.arguments(["Playtest": "YES"])["Playtest"] as? String == "YES")
        #expect(emulator.arguments(["StartLevel": "reef-12"])["StartLevel"] as? String == "reef-12")
    }

    @Test func aPhoneKeepsItsArguments() {
        let phone = AndroidDevice(environment: ["SWITCHLINGS_EMULATOR": "0"])
        #expect(phone.arguments([:]).isEmpty)
        #expect(phone.arguments(["Playtest": "NO"])["Playtest"] as? String == "NO")
    }

    @Test func nothingExportedIsAPhoneWithNoName() {
        let device = AndroidDevice(environment: [:])
        #expect(device.model.isEmpty && device.osVersion.isEmpty && !device.isEmulator)
    }
}

/// The beta switch (`-Pswitchlings.beta`), as `MainActivity` hands it over
/// from `SwitchlingsBuild.json`.
@Suite struct BetaBuildTests {
    @Test func onlyAOneIsOn() {
        #expect(BetaBuild(environment: ["SWITCHLINGS_BETA": "1"]).isOn)
        #expect(!BetaBuild(environment: ["SWITCHLINGS_BETA": "0"]).isOn)
        #expect(!BetaBuild(environment: [:]).isOn)
    }

    @Test func aBetaBuildKeepsItsArguments() {
        #expect(BetaBuild(isOn: true).arguments([:]).isEmpty)
    }

    @Test func offTurnsTheFeedAndTheSolveLogOffUnlessTheLaunchSaysOtherwise() {
        let off = BetaBuild(isOn: false)
        let plain = off.arguments([:])
        #expect(plain["DesignerLevels"] as? Bool == false)
        #expect(plain["Playtest"] as? Bool == false)
        let told = off.arguments(["DesignerLevels": "YES", "Playtest": "YES"])
        #expect(told["DesignerLevels"] as? String == "YES")
        #expect(told["Playtest"] as? String == "YES")
    }

    @Test func anEmulatorInABetaBuildStillPostsNothingUnlessTold() {
        let emulator = AndroidDevice(environment: ["SWITCHLINGS_EMULATOR": "1"])
        let arguments = BetaBuild(isOn: true).arguments(emulator.arguments([:]))
        #expect(arguments["Playtest"] as? Bool == false)
        #expect(arguments["DesignerLevels"] == nil)
    }
}
