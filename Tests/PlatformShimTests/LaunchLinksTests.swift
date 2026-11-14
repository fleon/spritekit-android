import Foundation
import PlatformShim
import Testing

/// `-OpenLink`, `-OpenLinkAfter` and `-OpenCode` beside a real link, decided
/// as `SceneDelegate` decides them on Apple.
@Suite struct LaunchLinksTests {
    @Test func aRealLinkOpensAtLaunch() {
        let plan = LaunchLinks.plan(link: "switchlings://level/K7Q2MX", openLink: nil, openLinkAfter: nil, openCode: nil)
        #expect(plan == LaunchLinks(atLaunch: "switchlings://level/K7Q2MX"))
    }

    @Test func openLinkOpensAtLaunchWithoutADelay() {
        let plan = LaunchLinks.plan(link: nil, openLink: "switchlings://world/mainframe", openLinkAfter: nil, openCode: nil)
        #expect(plan == LaunchLinks(atLaunch: "switchlings://world/mainframe"))
    }

    @Test func openLinkAfterHoldsTheLinkBack() {
        let plan = LaunchLinks.plan(link: nil, openLink: "switchlings://world/mainframe", openLinkAfter: 6, openCode: nil)
        #expect(plan == LaunchLinks(later: "switchlings://world/mainframe", delay: 6))
    }

    @Test func aRealLinkWinsOverOpenLinkButADelayedOneStillOpens() {
        let plan = LaunchLinks.plan(link: "switchlings://level/AAA111", openLink: "switchlings://world/reef", openLinkAfter: 3, openCode: "K7Q-2MX")
        #expect(plan.atLaunch == "switchlings://level/AAA111")
        #expect(plan.later == "switchlings://world/reef")
        #expect(plan.delay == 3)
        #expect(plan.code == "K7Q-2MX")
    }

    @Test func aRealLinkWinsOverAnImmediateOpenLink() {
        let plan = LaunchLinks.plan(link: "switchlings://level/AAA111", openLink: "switchlings://world/reef", openLinkAfter: nil, openCode: nil)
        #expect(plan == LaunchLinks(atLaunch: "switchlings://level/AAA111"))
    }

    @Test func openCodeIsKeptForWhenNoLinkOpensALevel() {
        let plan = LaunchLinks.plan(link: nil, openLink: nil, openLinkAfter: nil, openCode: "play my level K7Q-2MX!")
        #expect(plan == LaunchLinks(code: "play my level K7Q-2MX!"))
    }

    @Test func aDelayWithNoLinkDoesNothing() {
        let plan = LaunchLinks.plan(link: nil, openLink: nil, openLinkAfter: 6, openCode: nil)
        #expect(plan == LaunchLinks())
    }

    /// Through the argument domain, as the intent hands them over.
    @Test func readFromTheIntentsArguments() {
        let arguments = ["app_process", "-OpenLink", "switchlings://world/mainframe", "-OpenLinkAfter", "6", "-OpenCode", "K7Q-2MX",
                         LaunchLinks.launchLinkArgument, "switchlings://level/AAA111"]
        let domain = LaunchArgumentDomain.parse(arguments)
        let plan = LaunchLinks.plan(
            link: domain["LaunchLink"] as? String,
            openLink: domain["OpenLink"] as? String,
            openLinkAfter: (domain["OpenLinkAfter"] as? String).flatMap(Double.init),
            openCode: domain["OpenCode"] as? String
        )
        #expect(plan == LaunchLinks(atLaunch: "switchlings://level/AAA111", code: "K7Q-2MX", later: "switchlings://world/mainframe", delay: 6))
    }
}
