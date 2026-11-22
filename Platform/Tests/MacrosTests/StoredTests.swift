import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MacrosPlugin

private let macros: [String: Macro.Type] = [
    "Stored": StoredMacro.self,
    "Synced": SyncedMacro.self,
    "SyncedKey": SyncedKeyMacro.self,
    "SyncedKeys": SyncedKeysMacro.self,
]

final class StoredTests: XCTestCase {
    func testStoredReadsItsDefaultUntilSaved() {
        assertMacroExpansion(
            """
            @Stored("settings.visible", default: true)
            static var isVisible: Bool
            """,
            expandedSource: """
            static var isVisible: Bool {
                get {
                    UserDefaults.standard.object(forKey: "settings.visible") != nil ? UserDefaults.standard.bool(forKey: "settings.visible") : true
                }
                set {
                    UserDefaults.standard.set(newValue, forKey: "settings.visible")
                }
            }
            """,
            macros: macros
        )
    }

    func testStoredWithoutADefaultReadsTheTypedReader() {
        assertMacroExpansion(
            """
            @Stored(Key.count, defaults: suite)
            var count: Int
            """,
            expandedSource: """
            var count: Int {
                get {
                    suite.integer(forKey: Key.count)
                }
                set {
                    suite.set(newValue, forKey: Key.count)
                }
            }
            """,
            macros: macros
        )
    }

    func testStoredOptionalReadsNilUntilSaved() {
        assertMacroExpansion(
            """
            @Stored("example.index")
            static var index: Int?
            @Stored("example.name")
            static var name: String?
            """,
            expandedSource: """
            static var index: Int? {
                get {
                    UserDefaults.standard.object(forKey: "example.index") != nil ? UserDefaults.standard.integer(forKey: "example.index") : nil
                }
                set {
                    UserDefaults.standard.set(newValue, forKey: "example.index")
                }
            }
            static var name: String? {
                get {
                    UserDefaults.standard.string(forKey: "example.name")
                }
                set {
                    UserDefaults.standard.set(newValue, forKey: "example.name")
                }
            }
            """,
            macros: macros
        )
    }

    func testStoredSetsAndOtherTypes() {
        assertMacroExpansion(
            """
            @Stored("example.seen")
            static var seen: Set<String>
            @Stored("example.levels", default: [1])
            static var levels: [Int]
            """,
            expandedSource: """
            static var seen: Set<String> {
                get {
                    UserDefaults.standard.stringArray(forKey: "example.seen").map(Set.init) ?? []
                }
                set {
                    UserDefaults.standard.set(newValue.sorted(), forKey: "example.seen")
                }
            }
            static var levels: [Int] {
                get {
                    UserDefaults.standard.object(forKey: "example.levels") as? [Int] ?? [1]
                }
                set {
                    UserDefaults.standard.set(newValue, forKey: "example.levels")
                }
            }
            """,
            macros: macros
        )
    }

    func testSyncedSavesThroughTheManager() {
        assertMacroExpansion(
            """
            @Synced("progress.lastWorld", merge: .latest, default: 2)
            static var lastWorld: Int
            """,
            expandedSource: """
            static var lastWorld: Int {
                get {
                    ICloudSyncManager.shared.object(forKey: "progress.lastWorld") != nil ? ICloudSyncManager.shared.integer(forKey: "progress.lastWorld") : 2
                }
                set {
                    ICloudSyncManager.shared.set(newValue, forKey: "progress.lastWorld")
                }
            }
            """,
            macros: macros
        )
    }

    func testSyncedPooledSetOnlyReads() {
        assertMacroExpansion(
            """
            @Synced(Key.cleared, merge: .union)
            static var cleared: Set<String>
            """,
            expandedSource: """
            static var cleared: Set<String> {
                get {
                    ICloudSyncManager.shared.stringArray(forKey: Key.cleared).map(Set.init) ?? []
                }
            }
            """,
            macros: macros
        )
    }

    func testSyncedKeysListsPropertiesAndMarkedKeys() {
        assertMacroExpansion(
            """
            @SyncedKeys
            enum Progress {
                enum Key {
                    @SyncedKey(merge: .union) static let cleared = "progress.cleared"
                    @SyncedKey static let suspended = "progress.suspended"
                    static let local = "progress.local"
                }
                @Synced("progress.lastWorld") static var lastWorld: Int
                @Stored(Key.local) static var local: Bool
            }
            """,
            expandedSource: """
            enum Progress {
                enum Key {
                    static let cleared = "progress.cleared"
                    static let suspended = "progress.suspended"
                    static let local = "progress.local"
                }
                static var lastWorld: Int {
                    get {
                        ICloudSyncManager.shared.integer(forKey: "progress.lastWorld")
                    }
                    set {
                        ICloudSyncManager.shared.set(newValue, forKey: "progress.lastWorld")
                    }
                }
                static var local: Bool {
                    get {
                        UserDefaults.standard.bool(forKey: Key.local)
                    }
                    set {
                        UserDefaults.standard.set(newValue, forKey: Key.local)
                    }
                }

                nonisolated static let syncedKeys: [String: ICloudSyncManager.Merge] = [
                    Key.cleared: .union,
                    Key.suspended: .latest,
                    "progress.lastWorld": .latest,
                ]
            }
            """,
            macros: macros
        )
    }

    func testSyncedKeysWithNoneIsEmpty() {
        assertMacroExpansion(
            """
            @SyncedKeys
            public struct Settings {
            }
            """,
            expandedSource: """
            public struct Settings {

                public nonisolated static let syncedKeys: [String: ICloudSyncManager.Merge] = [:]
            }
            """,
            macros: macros
        )
    }

    func testMisuseIsDiagnosed() {
        assertMacroExpansion(
            """
            @Synced("example.count", merge: .union)
            static var count: Int
            """,
            expandedSource: """
            static var count: Int
            """,
            diagnostics: [
                DiagnosticSpec(message: "a `.union` key is a set of strings: give it a `[String]` or `Set<String>` property", line: 1, column: 1),
            ],
            macros: macros
        )
        assertMacroExpansion(
            """
            @Stored("example.count")
            static var count = 0
            """,
            expandedSource: """
            static var count = 0
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Stored needs the property's type written out", line: 1, column: 1),
            ],
            macros: macros
        )
        assertMacroExpansion(
            """
            @Stored("example.count")
            static var count: Int = 0
            """,
            expandedSource: """
            static var count: Int = 0
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Stored takes its starting value as `default:`, not an initializer", line: 1, column: 1),
            ],
            macros: macros
        )
        assertMacroExpansion(
            """
            @Stored("example.mode")
            static var mode: Mode
            """,
            expandedSource: """
            static var mode: Mode
            """,
            diagnostics: [
                DiagnosticSpec(message: "a Mode needs `default:`, what it reads before it's saved", line: 1, column: 1),
            ],
            macros: macros
        )
        assertMacroExpansion(
            """
            @SyncedKeys
            enum Progress {
                enum Key {
                    @SyncedKey static let world = "progress.world"
                }
                @Synced(Key.world) static var world: Int
            }
            """,
            expandedSource: """
            enum Progress {
                enum Key {
                    static let world = "progress.world"
                }
                static var world: Int {
                    get {
                        ICloudSyncManager.shared.integer(forKey: Key.world)
                    }
                    set {
                        ICloudSyncManager.shared.set(newValue, forKey: Key.world)
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Key.world is listed twice", line: 1, column: 1),
            ],
            macros: macros
        )
    }
}
