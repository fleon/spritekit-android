import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MacrosPlugin

final class NSCodingInheritTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["NSCodingUnsupported": NSCodingUnsupportedMacro.self]

    func testInheritSizePassesInitSizeThrough() {
        assertMacroExpansion(
            """
            @NSCodingUnsupported(inherit: .size)
            final class Scene: SKScene {
            }
            """,
            expandedSource: """
            final class Scene: SKScene {

                override init(size: CGSize) {
                    super.init(size: size)
                }

                required init?(coder aDecoder: NSCoder) {
                    fatalError("init(coder:) has not been implemented")
                }
            }
            """,
            macros: macros
        )
    }

    func testInheritBothMatchesThePublicClass() {
        assertMacroExpansion(
            """
            @NSCodingUnsupported(inherit: .plain, .size, .plain)
            public class Scene: SKScene {
            }
            """,
            expandedSource: """
            public class Scene: SKScene {

                public override init() {
                    super.init()
                }

                public override init(size: CGSize) {
                    super.init(size: size)
                }

                public required init?(coder aDecoder: NSCoder) {
                    fatalError("init(coder:) has not been implemented")
                }
            }
            """,
            macros: macros
        )
    }

    func testRequiredPlainOverridesARequiredInit() {
        assertMacroExpansion(
            """
            @NSCodingUnsupported(inherit: .requiredPlain)
            final class Tile: PieceNode {
            }
            """,
            expandedSource: """
            final class Tile: PieceNode {

                required init() {
                    super.init()
                }

                required init?(coder aDecoder: NSCoder) {
                    fatalError("init(coder:) has not been implemented")
                }
            }
            """,
            macros: macros
        )
    }

    func testRequiredPlainKeepsAPublicClassPublic() {
        assertMacroExpansion(
            """
            @NSCodingUnsupported(inherit: .requiredPlain)
            open class Tile: PieceNode {
            }
            """,
            expandedSource: """
            open class Tile: PieceNode {

                public required init() {
                    super.init()
                }

                public required init?(coder aDecoder: NSCoder) {
                    fatalError("init(coder:) has not been implemented")
                }
            }
            """,
            macros: macros
        )
    }

    func testPlainAndRequiredPlainTogetherIsAnError() {
        assertMacroExpansion(
            """
            @NSCodingUnsupported(inherit: .plain, .requiredPlain)
            final class Tile: PieceNode {
            }
            """,
            expandedSource: """
            final class Tile: PieceNode {
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: "@NSCodingUnsupported takes `.plain` or `.requiredPlain`, not both: each writes `init()`",
                line: 1, column: 1
            )],
            macros: macros
        )
    }
}
