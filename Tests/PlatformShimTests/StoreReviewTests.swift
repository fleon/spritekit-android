import Foundation
import Testing
@testable import PlatformShim

// Play In-App Review behind `SKStoreReviewController`: a request reaches
// Java, and one already with Play holds back the next.

@Suite("Play In-App Review")
@MainActor
struct StoreReviewTests {
    @Test("A request goes to Java, and another waits until Play's flow is over")
    func request() {
        let java = FakeJava()
        let review = PlayInAppReview(channel: java.channel)
        review.request()
        #expect(java.names == ["review.request"])
        #expect(review.isRequesting)
        review.request()
        #expect(java.count("review.request") == 1)
        java.send("review", "requested", ["ok": true])
        #expect(!review.isRequesting)
        review.request()
        #expect(java.count("review.request") == 2)
    }

    @Test("A flow that failed frees the next request too")
    func failed() {
        let java = FakeJava()
        let review = PlayInAppReview(channel: java.channel)
        review.request()
        java.send("review", "requested", ["ok": false])
        review.request()
        #expect(java.count("review.request") == 2)
    }

    @Test("Without a channel a request does nothing, as on a simulator")
    func noChannel() {
        let saved = StoreReview.playInAppReview
        defer { StoreReview.playInAppReview = saved }
        StoreReview.playInAppReview = nil
        StoreReview.request()
    }
}
