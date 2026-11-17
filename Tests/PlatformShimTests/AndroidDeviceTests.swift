import Foundation
import PlatformShim
import Testing

/// The device the beta's solve log names, as `MainActivity` hands it over,
/// and the emulator's `-Playtest NO`.
@Suite struct AndroidDeviceTests {
    @Test func readsWhatMainActivityExports() {
        let device = AndroidDevice(environment: [
            "SKA_DEVICE_MODEL": "Google Pixel 6",
            "SKA_OS_VERSION": "17",
            "SKA_EMULATOR": "0",
        ])
        #expect(device.model == "Google Pixel 6")
        #expect(device.osVersion == "17")
        #expect(!device.isEmulator)
    }

    @Test func anEmulatorRecordsNoSolvesUnlessTold() {
        let emulator = AndroidDevice(environment: ["SKA_EMULATOR": "1"])
        #expect(emulator.arguments([:])["Playtest"] as? Bool == false)
        #expect(emulator.arguments(["Playtest": "YES"])["Playtest"] as? String == "YES")
        #expect(emulator.arguments(["StartLevel": "reef-12"])["StartLevel"] as? String == "reef-12")
    }

    @Test func aPhoneKeepsItsArguments() {
        let phone = AndroidDevice(environment: ["SKA_EMULATOR": "0"])
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
        #expect(BetaBuild(environment: ["SKA_BETA": "1"]).isOn)
        #expect(!BetaBuild(environment: ["SKA_BETA": "0"]).isOn)
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
        let emulator = AndroidDevice(environment: ["SKA_EMULATOR": "1"])
        let arguments = BetaBuild(isOn: true).arguments(emulator.arguments([:]))
        #expect(arguments["Playtest"] as? Bool == false)
        #expect(arguments["DesignerLevels"] == nil)
    }
}

@Suite("Music loops")
struct MusicLoopTests {
    @Test("The whole track's loop starts at the top and ends past any file, without overflowing the mixer's microseconds")
    func wholeTrack() {
        let loop = MusicLoop.wholeTrack
        #expect(loop.start == 0)
        // An hour at 192 kHz is well inside it.
        #expect(loop.end > 192_000 * 3_600)
        // `MusicMixer.microseconds`: frame × 1 000 000 / rate, at the lowest rate it meets.
        let (product, overflow) = loop.end.multipliedReportingOverflow(by: 1_000_000)
        #expect(!overflow && product / 8_000 > 0)
    }
}
