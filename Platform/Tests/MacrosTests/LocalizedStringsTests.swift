import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MacrosPlugin

private let macros: [String: Macro.Type] = [
    "LocalizedStrings": LocalizedStringsMacro.self,
    "L": LocalizedCaseMacro.self,
]

final class LocalizedStringsTests: XCTestCase {
    func testKeysFallbacksCommentsAndFormatting() {
        assertMacroExpansion(
            """
            @LocalizedStrings
            enum Text {
                @L("menu.start", "Start", comment: "Menu button")
                case start
                @L("menu.progress", "%d of %d", comment: "Done and total")
                case progress(Int, Int)
            }
            """,
            expandedSource: """
            enum Text {
                case start
                case progress(Int, Int)

                var key: String {
                    switch self {
                    case .start:
                        return "menu.start"
                    case .progress:
                        return "menu.progress"
                    }
                }

                var fallback: String {
                    switch self {
                    case .start:
                        return "Start"
                    case .progress:
                        return "%d of %d"
                    }
                }

                var comment: String {
                    switch self {
                    case .start:
                        return "Menu button"
                    case .progress:
                        return "Done and total"
                    }
                }

                var localized: String {
                    let format = NSLocalizedString(key, value: fallback, comment: comment)
                    switch self {
                    case let .progress(value0, value1):
                        return String(format: format, value0, value1)
                    case .start:
                        return format
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testKeysAloneUseNoValueAndAnEmptyComment() {
        assertMacroExpansion(
            """
            @LocalizedStrings(table: "Menu", bundle: .main)
            public nonisolated enum Text {
                @L("menu.start") case start
            }
            """,
            expandedSource: """
            public nonisolated enum Text {
                case start

                public nonisolated var key: String {
                    switch self {
                    case .start:
                        return "menu.start"
                    }
                }

                public nonisolated var localized: String {
                    NSLocalizedString(key, tableName: "Menu", bundle: .main, comment: "")
                }
            }
            """,
            macros: macros
        )
    }

    func testCustomLookupKeysAndFormatting() {
        assertMacroExpansion(
            """
            @LocalizedStrings(lookup: .custom, formatting: .localized)
            enum Text {
                @L("score", "%d points") case score(Int)
                @L("rank", "#%@", formatting: .custom) case rank(Int)
                @L("price", "%@", formatting: .plain) case price(String)
                @L(.custom) case name(Kind)
                @L(.custom, formatting: .localized) case days(Int)
            }
            """,
            expandedSource: """
            enum Text {
                case score(Int)
                case rank(Int)
                case price(String)
                case name(Kind)
                case days(Int)

                var key: String {
                    switch self {
                    case .score:
                        return "score"
                    case .rank:
                        return "rank"
                    case .price:
                        return "price"
                    case .name:
                        return customKey
                    case .days:
                        return customKey
                    }
                }

                var fallback: String {
                    switch self {
                    case .score:
                        return "%d points"
                    case .rank:
                        return "#%@"
                    case .price:
                        return "%@"
                    case .name:
                        return customFallback
                    case .days:
                        return customFallback
                    }
                }

                var localized: String {
                    let format = Self.lookup(key, fallback: fallback)
                    switch self {
                    case let .score(value0):
                        return String.localizedStringWithFormat(format, value0)
                    case .rank:
                        return customLocalized(format)
                    case let .price(value0):
                        return String(format: format, value0)
                    case let .days(value0):
                        return String.localizedStringWithFormat(format, value0)
                    case .name:
                        return format
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testDiagnosesUnmarkedCasesPlaceholdersAndDuplicates() {
        assertMacroExpansion(
            """
            @LocalizedStrings
            enum Text {
                @L("a", "%d and %@") case a(Int)
                @L("a", "%1$@ %2$@ 100%%") case b(String, String)
                case c
            }
            """,
            expandedSource: """
            enum Text {
                case a(Int)
                case b(String, String)
                case c

                var key: String {
                    switch self {
                    case .a:
                        return "a"
                    case .b:
                        return "a"
                    }
                }

                var fallback: String {
                    switch self {
                    case .a:
                        return "%d and %@"
                    case .b:
                        return "%1$@ %2$@ 100%%"
                    }
                }

                var localized: String {
                    let format = NSLocalizedString(key, value: fallback, comment: "")
                    switch self {
                    case let .a(value0):
                        return String(format: format, value0)
                    case let .b(value0, value1):
                        return String(format: format, value0, value1)
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "case c has no @L(...): give it its key",
                    line: 5,
                    column: 5,
                    fixIts: [FixItSpec(message: "add @L(\"c\")")]
                ),
                DiagnosticSpec(
                    message: "key \"a\" is already used by case a",
                    line: 4,
                    column: 8,
                    notes: [NoteSpec(message: "\"a\" first used here", line: 3, column: 8)]
                ),
                DiagnosticSpec(
                    message: "the fallback of case a takes 2 arguments, but the case has 1 associated value",
                    line: 3,
                    column: 13
                ),
            ],
            macros: macros
        )
    }

    func testDiagnosesInterpolationAndNonEnums() {
        assertMacroExpansion(
            """
            @LocalizedStrings
            struct Text {}
            """,
            expandedSource: """
            struct Text {}
            """,
            diagnostics: [DiagnosticSpec(message: "@LocalizedStrings applies to an enum", line: 1, column: 1)],
            macros: macros
        )
        assertMacroExpansion(
            """
            @LocalizedStrings
            enum Text {
                @L("a.\\(1)") case a
            }
            """,
            expandedSource: """
            enum Text {
                case a
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@L takes string literals without interpolation; a key built at run time is @L(.custom)",
                    line: 3,
                    column: 8
                ),
            ],
            macros: macros
        )
    }

    func testCountsPlaceholders() {
        XCTAssertEqual(LocalizedStringsMacro.placeholderCount("%d %@ %ld %f %.1f %%"), 5)
        XCTAssertEqual(LocalizedStringsMacro.placeholderCount("%2$@ then %1$@"), 2)
        XCTAssertEqual(LocalizedStringsMacro.placeholderCount("100%% sure"), 0)
        XCTAssertEqual(LocalizedStringsMacro.placeholderCount("%'d and %-5s and %lld"), 3)
    }
}
