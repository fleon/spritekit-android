import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MacrosPlugin

final class MacrosTests: XCTestCase {
    func testNSCodingUnsupportedAddsTheInitializer() {
        assertMacroExpansion(
            """
            @NSCodingUnsupported
            final class Node: SKNode {
            }
            """,
            expandedSource: """
            final class Node: SKNode {

                required init?(coder aDecoder: NSCoder) {
                    fatalError("init(coder:) has not been implemented")
                }
            }
            """,
            macros: ["NSCodingUnsupported": NSCodingUnsupportedMacro.self]
        )
    }
}
