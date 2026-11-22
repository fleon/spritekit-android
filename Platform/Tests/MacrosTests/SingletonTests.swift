import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MacrosPlugin

final class SingletonTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["Singleton": SingletonMacro.self]

    func testAPlainTypeGetsItsInstanceAndAPrivateInit() {
        assertMacroExpansion(
            """
            @Singleton
            final class Store {
                var count = 0
            }
            """,
            expandedSource: """
            final class Store {
                var count = 0

                static let shared = Store()

                private init() {
                }
            }
            """,
            macros: macros
        )
    }

    func testATypesOwnInitIsKept() {
        assertMacroExpansion(
            """
            @Singleton
            public final class Feed {
                private init() {
                    load()
                }
            }
            """,
            expandedSource: """
            public final class Feed {
                private init() {
                    load()
                }

                public static let shared = Feed()
            }
            """,
            macros: macros
        )
    }

    func testAnObjectSubclassOverridesInit() {
        assertMacroExpansion(
            """
            @Singleton
            nonisolated final class Listener: NSObject, Delegate {
            }
            """,
            expandedSource: """
            nonisolated final class Listener: NSObject, Delegate {

                static let shared = Listener()

                private override init() {
                    super.init()
                }
            }
            """,
            macros: macros
        )
    }

    func testOnlyInitsWithArgumentsIsAnError() {
        assertMacroExpansion(
            """
            @Singleton
            final class Manager {
                init(configuration: Int) {}
            }
            """,
            expandedSource: """
            final class Manager {
                init(configuration: Int) {}
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: "@Singleton makes `shared` with `init()`: add a private `init()`, or make the instance where its arguments are known",
                line: 1, column: 1
            )],
            macros: macros
        )
    }

    func testAnEnumOrAnExistingSharedIsAnError() {
        assertMacroExpansion(
            """
            @Singleton
            enum Space {}
            """,
            expandedSource: """
            enum Space {}
            """,
            diagnostics: [DiagnosticSpec(message: "@Singleton applies to a class, struct or actor", line: 1, column: 1)],
            macros: macros
        )
        assertMacroExpansion(
            """
            @Singleton
            struct Twice {
                static let shared = Twice()
            }
            """,
            expandedSource: """
            struct Twice {
                static let shared = Twice()
            }
            """,
            diagnostics: [DiagnosticSpec(message: "@Singleton writes `shared`: remove the type's own", line: 1, column: 1)],
            macros: macros
        )
    }
}
