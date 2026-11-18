import Foundation
import Testing
@testable import PlatformShare
#if SPRITEKIT_SHIM
import PlatformShim
import SpriteKitShim
#endif

@Suite("Feedback mail")
struct FeedbackMailTests {
    @Test("Its link carries the address, subject and body, encoded")
    func link() throws {
        let url = try #require(FeedbackMail.url(to: "help@example.com", subject: "Hi & bye", body: "Line one\nLine two"))
        #expect(url.scheme == "mailto")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "help@example.com")
        #expect(components.queryItems?.first { $0.name == "subject" }?.value == "Hi & bye")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == "Line one\nLine two")
    }
}

#if SPRITEKIT_SHIM
@Suite("Share sheet on the shell", .serialized)
@MainActor
struct ShellShareTests {
    init() {
        AppIdentity.current = AppIdentity(name: "Game", bundleIdentifier: "com.example.game", key: "game")
    }

    @Test("Items go to the shell sorted; an App Store link becomes the Play page in the game's language")
    func present() throws {
        var sent: [ShareRequest] = []
        var presented = 0
        SystemShare.sheet = { sent.append($0); return true }
        ShareSheet.didPresent = { presented += 1 }
        ShareSheet.storePageLanguage = { "zh-Hans" }
        defer { SystemShare.sheet = nil; ShareSheet.didPresent = nil; ShareSheet.storePageLanguage = { nil } }
        #expect(ShareSheet.isAvailable)
        let film = URL(fileURLWithPath: "/tmp/film.mp4")
        ShareSheet.present(["Look!", try #require(URL(string: "https://apps.apple.com/app/id123")), film], from: SKNode())
        #expect(sent.count == 1 && presented == 1)
        #expect(sent.first?.files == [film])
        #expect(sent.first?.text == "Look! https://play.google.com/store/apps/details?id=com.example.game&hl=zh-CN")
    }

    @Test("A sheet the shell turns down isn't counted, and none is unavailable")
    func refused() {
        var presented = 0
        ShareSheet.didPresent = { presented += 1 }
        defer { SystemShare.sheet = nil; ShareSheet.didPresent = nil }
        SystemShare.sheet = { _ in false }
        ShareSheet.present(["x"], from: SKNode())
        SystemShare.sheet = nil
        #expect(!ShareSheet.isAvailable)
        ShareSheet.present(["x"], from: SKNode())
        #expect(presented == 0)
    }

    @Test("Copying reaches the shell's pasteboard")
    func copy() {
        var copied: String?
        SystemShare.pasteboard = { copied = $0 }
        defer { SystemShare.pasteboard = nil }
        ShareSheet.copy("K7Q-2MX")
        #expect(copied == "K7Q-2MX")
    }

    @Test("The review page is the game's Play page, and the mail opens its link")
    func reviewAndMail() throws {
        var opened: [URL] = []
        let original = SystemLinks.open
        SystemLinks.open = { opened.append($0); return true }
        defer { SystemLinks.open = original }
        #expect(StoreReviewPage.open(appStoreID: "123", language: "es-MX"))
        FeedbackMail.compose(to: "help@example.com", subject: "Hi", body: "Body")
        #expect(opened.first?.absoluteString == "https://play.google.com/store/apps/details?id=com.example.game&hl=es-419")
        #expect(opened.last?.scheme == "mailto")
    }
}
#else
@Suite("Store review page")
struct ReviewPageTests {
    @Test("It's the App Store's write-a-review page for the game")
    func page() {
        #expect(StoreReviewPage.url(appStoreID: "123")?.absoluteString == "https://apps.apple.com/app/id123?action=write-review")
    }
}
#endif
