import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MacrosPlugin

// The test harness hands extension macros no missing conformances, so these
// expansions never show `: Decodable`; the round trip in PlatformCoreTests
// covers it.
final class DecodableDefaultsTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["DecodableDefaults": DecodableDefaultsMacro.self]

    func testStructDecodesDefaultsInAnExtension() {
        assertMacroExpansion(
            """
            @DecodableDefaults
            nonisolated struct Profile: Codable {
                static let limit = 3
                var name: String
                var coins = 0
                var badges: [String] = []
                var avatar: String?
                var level: Int? = 1
                var rank: Optional<Int>
                var score: Int { coins * 2 }
                var mood: Int = 0 {
                    didSet { print(mood) }
                }
                lazy var cache: [Int] = []
            }
            """,
            expandedSource: """
            nonisolated struct Profile: Codable {
                static let limit = 3
                var name: String
                var coins = 0
                var badges: [String] = []
                var avatar: String?
                var level: Int? = 1
                var rank: Optional<Int>
                var score: Int { coins * 2 }
                var mood: Int = 0 {
                    didSet { print(mood) }
                }
                lazy var cache: [Int] = []

                private enum CodingKeys: String, CodingKey {
                    case name, coins, badges, avatar, level, rank, mood
                }
            }

            extension Profile {
                nonisolated init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.name = try container.decode(String.self, forKey: .name)
                    self.coins = try container.decodeIfPresent(forKey: .coins) ?? 0
                    self.badges = try container.decodeIfPresent([String].self, forKey: .badges) ?? []
                    self.avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
                    self.level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 1
                    self.rank = try container.decodeIfPresent(Int.self, forKey: .rank)
                    self.mood = try container.decodeIfPresent(Int.self, forKey: .mood) ?? 0
                }
            }
            """,
            macros: macros
        )
    }

    func testDeclaredCodingKeysAreHonoured() {
        assertMacroExpansion(
            """
            @DecodableDefaults
            public struct Level: Decodable {
                let grid: [String]
                var words: [String] = []
                var hint: String?
                var seen = false

                private enum CodingKeys: String, CodingKey {
                    case grid = "cells", words, legacy
                }
            }
            """,
            expandedSource: """
            public struct Level: Decodable {
                let grid: [String]
                var words: [String] = []
                var hint: String?
                var seen = false

                private enum CodingKeys: String, CodingKey {
                    case grid = "cells", words, legacy
                }
            }

            extension Level {
                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.grid = try container.decode([String].self, forKey: .grid)
                    self.words = try container.decodeIfPresent([String].self, forKey: .words) ?? []
                }
            }
            """,
            macros: macros
        )
    }

    func testClassesGetTheInitializerInTheirBody() {
        assertMacroExpansion(
            """
            @DecodableDefaults
            final class Save: Codable {
                var best: Int = 0
            }
            @DecodableDefaults
            class Open: Codable {
                var count = 0
            }
            """,
            expandedSource: """
            final class Save: Codable {
                var best: Int = 0

                private enum CodingKeys: String, CodingKey {
                    case best
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.best = try container.decodeIfPresent(Int.self, forKey: .best) ?? 0
                }
            }
            class Open: Codable {
                var count = 0

                private enum CodingKeys: String, CodingKey {
                    case count
                }

                required init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.count = try container.decodeIfPresent(forKey: .count) ?? 0
                }
            }
            """,
            macros: macros
        )
    }

    func testPrivateStructsGetTheInitializerInTheirBody() {
        assertMacroExpansion(
            """
            @DecodableDefaults
            private struct Snapshot: Codable {
                var keys: [String] = []
            }
            """,
            expandedSource: """
            private struct Snapshot: Codable {
                var keys: [String] = []

                private enum CodingKeys: String, CodingKey {
                    case keys
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.keys = try container.decodeIfPresent([String].self, forKey: .keys) ?? []
                }
            }
            """,
            macros: macros
        )
    }

    func testOperatorDefaultsAreParenthesizedAndSharedTypesApply() {
        assertMacroExpansion(
            """
            @DecodableDefaults
            struct Mix: Codable {
                var a, b: Int
                var flag: Bool = Self.on ? true : false
                var sum = 1 + 2
            }
            """,
            expandedSource: """
            struct Mix: Codable {
                var a, b: Int
                var flag: Bool = Self.on ? true : false
                var sum = 1 + 2

                private enum CodingKeys: String, CodingKey {
                    case a, b, flag, sum
                }
            }

            extension Mix {
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.a = try container.decode(Int.self, forKey: .a)
                    self.b = try container.decode(Int.self, forKey: .b)
                    self.flag = try container.decodeIfPresent(Bool.self, forKey: .flag) ?? (Self.on ? true : false)
                    self.sum = try container.decodeIfPresent(forKey: .sum) ?? (1 + 2)
                }
            }
            """,
            macros: macros
        )
    }

    func testLetWithAValueIsKeptButNotDecoded() {
        assertMacroExpansion(
            """
            @DecodableDefaults
            struct Versioned: Codable {
                let version = 2
                var name: String
            }
            """,
            expandedSource: """
            struct Versioned: Codable {
                let version = 2
                var name: String

                private enum CodingKeys: String, CodingKey {
                    case version, name
                }
            }

            extension Versioned {
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.name = try container.decode(String.self, forKey: .name)
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "immutable property 'version' will not be decoded because it is declared with an initial value which cannot be overwritten; make it 'var' to decode it with that value as its default",
                    line: 3, column: 9, severity: .warning
                ),
            ],
            macros: macros
        )
    }

    func testMisuseIsDiagnosed() {
        assertMacroExpansion(
            """
            @DecodableDefaults
            enum Mode: Codable {
                case on
            }
            @DecodableDefaults
            struct Missing: Codable {
                var kept: Int
                private enum CodingKeys: String, CodingKey {
                    case other
                }
            }
            @DecodableDefaults
            struct Twice: Codable {
                var x: Int
                init(from decoder: Decoder) throws { x = 0 }
            }
            """,
            expandedSource: """
            enum Mode: Codable {
                case on
            }
            struct Missing: Codable {
                var kept: Int
                private enum CodingKeys: String, CodingKey {
                    case other
                }
            }
            struct Twice: Codable {
                var x: Int
                init(from decoder: Decoder) throws { x = 0 }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@DecodableDefaults applies to a struct or a class", line: 1, column: 1),
                DiagnosticSpec(
                    message: "'kept' has no key in CodingKeys and no initial value to take instead",
                    line: 7, column: 9
                ),
                DiagnosticSpec(
                    message: "@DecodableDefaults writes init(from:); remove the one declared here",
                    line: 12, column: 1
                ),
            ],
            macros: macros
        )
    }
}
