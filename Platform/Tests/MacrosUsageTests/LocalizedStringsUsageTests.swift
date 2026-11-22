import Foundation
import Macros
import Testing
#if SPRITEKIT_SHIM
// Its `LocalizedStrings` (the tables) and the macro live side by side, as
// in a game's Android package.
import SpriteKitShim
#endif

// The macro's members as the compiler expands and type-checks them, under
// Swift 5 with main-actor default isolation. No table holds these keys, so
// each string is its fallback.

@LocalizedStrings
enum MenuText {
    @L("menu.start", "Start", comment: "Menu button")
    case start
    @L("menu.progress", "%d of %d", comment: "Done and total")
    case progress(Int, Int)
    @L("menu.greeting", "Hello, %@", comment: "Greets the player", formatting: .localized)
    case greeting(String)
}

@LocalizedStrings(table: "Menu", bundle: .main)
nonisolated enum KeyOnlyText {
    @L("menu.quit") case quit
}

nonisolated enum Kind: String {
    case small, large
}

@LocalizedStrings(lookup: .custom)
nonisolated enum LookedUpText {
    @L("menu.rank", "#%@", formatting: .custom)
    case rank(Int)
    @L(.custom)
    case kind(Kind)
    @L(.custom, formatting: .plain)
    case days(Int)

    static func lookup(_ key: String, fallback: String) -> String {
        "[\(key)] " + fallback
    }

    private var customKey: String {
        switch self {
        case let .kind(kind): return "kind." + kind.rawValue
        case let .days(days): return days == 1 ? "days.one" : "days.other"
        default: return ""
        }
    }

    private var customFallback: String {
        switch self {
        case let .kind(kind): return kind == .small ? "Small" : "Large"
        case let .days(days): return days == 1 ? "%d day" : "%d days"
        default: return ""
        }
    }

    private func customLocalized(_ format: String) -> String {
        switch self {
        case let .rank(rank): return String(format: format, String(rank * 10))
        default: return format
        }
    }
}

struct LocalizedStringsUsageTests {
    @Test @MainActor func fillsInTheFallbacks() {
        #expect(MenuText.start.key == "menu.start")
        #expect(MenuText.start.comment == "Menu button")
        #expect(MenuText.start.localized == "Start")
        #expect(MenuText.progress(3, 8).fallback == "%d of %d")
        #expect(MenuText.progress(3, 8).localized == "3 of 8")
        #expect(MenuText.greeting("Ada").localized == "Hello, Ada")
    }

    @Test func readsKeysAloneOffTheMainActor() {
        #expect(KeyOnlyText.quit.key == "menu.quit")
        #expect(KeyOnlyText.quit.localized == "menu.quit")
    }

    @Test func handsCustomCasesToTheEnum() {
        #expect(LookedUpText.rank(4).localized == "[menu.rank] #40")
        #expect(LookedUpText.kind(.large).key == "kind.large")
        #expect(LookedUpText.kind(.large).localized == "[kind.large] Large")
        #expect(LookedUpText.days(1).localized == "[days.one] 1 day")
        #expect(LookedUpText.days(3).localized == "[days.other] 3 days")
    }
}
