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

                required init?(coder aDecoder: NSCoder) {
                    fatalError("init(coder:) has not been implemented")
                }
            }
            """,
            macros: macros
        )
    }
}
