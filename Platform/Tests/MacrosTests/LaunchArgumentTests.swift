import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MacrosPlugin

final class LaunchArgumentTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["LaunchArgument": LaunchArgumentMacro.self]

    private func expect(_ declaration: String, reads body: String, file: StaticString = #filePath, line: UInt = #line) {
        assertMacroExpansion(
            "@LaunchArgument\(declaration)",
            expandedSource: expanded(declaration, body),
            macros: macros,
            file: file,
            line: line
        )
    }

    private func expanded(_ declaration: String, _ body: String) -> String {
        let property = String(declaration[declaration.range(of: ") ")!.upperBound...])
        let body = body.replacingOccurrences(of: "\n", with: "\n        ")
        return """
        \(property) {
            get {
                \(body)
            }
        }
        """
    }

    private func expectError(_ source: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let property = String(source[source.range(of: ") ")!.upperBound...])
        assertMacroExpansion(
            source,
            expandedSource: property,
            diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
            macros: macros,
            file: file,
            line: line
        )
    }

    func testTheDeclaredTypePicksTheMethod() {
        expect(#"("Flag") static var flag: Bool"#, reads: #"Self.reader.bool("Flag")"#)
        expect(#"("Name") static var name: String?"#, reads: #"Self.reader.string("Name")"#)
        expect(#"("Count") static var count: Int?"#, reads: #"Self.reader.int("Count")"#)
        expect(#"("Slow") static var slow: Double?"#, reads: #"Self.reader.double("Slow")"#)
        expect(#"("Wait") static var wait: TimeInterval?"#, reads: #"Self.reader.double("Wait")"#)
        expect(#"("Size") static var size: CGSize?"#, reads: #"Self.reader.size("Size")"#)
        expect(#"("Tour") static var tour: [String]?"#, reads: #"Self.reader.list("Tour")"#)
        expect(#"("Times") static var times: [Double]?"#, reads: #"Self.reader.numbers("Times")"#)
        expect(#"("Mode") static var mode: Mode?"#, reads: #"Self.reader.value("Mode")"#)
        expect(#"("Mode") static var mode: Optional<Debug.Mode>"#, reads: #"Self.reader.value("Mode")"#)
    }

    func testConvertedTypes() {
        expect(#"("Centre") static var centre: CGFloat?"#, reads: #"""
            Self.reader.double("Centre").map {
                CGFloat($0)
            }
            """#)
        expect(#"("Seed") static var seed: UInt64?"#, reads: #"""
            Self.reader.string("Seed").flatMap {
                UInt64($0)
            }
            """#)
        expect(#"("Link") static var link: URL?"#, reads: #"""
            Self.reader.string("Link").flatMap {
                URL(string: $0)
            }
            """#)
        expect(#"("Frames") static var frames: [Int]?"#, reads: #"""
            Self.reader.list("Frames").map {
                $0.compactMap {
                    Int($0)
                }
            }
            """#)
        expect(#"("Tour") static var tour: [Place]?"#, reads: #"""
            Self.reader.list("Tour").map {
                $0.compactMap {
                    Place(rawValue: $0)
                }
            }
            """#)
        expect(#"("Gaps") static var gaps: [CGFloat]?"#, reads: #"""
            Self.reader.numbers("Gaps").map {
                $0.map {
                    CGFloat($0)
                }
            }
            """#)
    }

    func testNonOptionalsFallBack() {
        expect(#"("Script") static var script: [String]"#, reads: #"Self.reader.list("Script") ?? []"#)
        expect(#"("Clears") static var clears: Int"#, reads: #"Self.reader.int("Clears") ?? 0"#)
        expect(#"("Slow", unset: 1) static var slow: Double"#, reads: #"Self.reader.double("Slow") ?? 1"#)
        expect(#"("Scale", release: 1) static var scale: CGFloat"#, reads: #"""
            Self.reader.double("Scale").map {
                CGFloat($0)
            } ?? 1
            """#)
        expect(#"("Turn", unset: Turn.none) static var turn: Turn"#, reads: #"Self.reader.value("Turn") ?? Turn.none"#)
    }

    func testReleaseValues() {
        expect(#"("Flag", release: true) static var flag: Bool"#, reads: #"Self.reader.bool("Flag", release: true)"#)
        expect(#"("Name", release: "x") static var name: String?"#, reads: #"Self.reader.string("Name", release: "x")"#)
        expect(#"("Name", release: nil) static var name: String?"#, reads: #"Self.reader.string("Name")"#)
        expect(#"("Script", release: ["a"]) static var script: [String]"#, reads: #"Self.reader.list("Script") ?? ["a"]"#)
        expect(
            #"("Slow", unset: 1, release: 2) static var slow: Double"#,
            reads: #"Self.reader.isEnabled ? Self.reader.double("Slow") ?? 1 : 2"#
        )
        expect(
            #"("Centre", release: 0.5) static var centre: CGFloat?"#,
            reads: #"""
            Self.reader.isEnabled ? Self.reader.double("Centre").map {
                CGFloat($0)
            } : 0.5
            """#
        )
    }

    func testBoolWithAnUnsetDefault() {
        expect(#"("Feed", unset: true) static var feed: Bool"#, reads: #"Self.reader.bool("Feed", unset: true, release: true)"#)
        expect(
            #"("Record", unset: !isSimulator, release: false) static var records: Bool"#,
            reads: #"Self.reader.bool("Record", unset: !isSimulator, release: false)"#
        )
    }

    func testOverrides() {
        expect(#"("Step", as: .fraction) static var step: TimeInterval?"#, reads: #"Self.reader.fraction("Step")"#)
        expect(#"("Stills", separator: ";") static var stills: [String]?"#, reads: #"Self.reader.list("Stills", separator: ";")"#)
        expect(#"("Flag", reader: "Debug.reader") static var flag: Bool"#, reads: #"Debug.reader.bool("Flag")"#)
        expect(#"("Flag", reader: "reader") var flag: Bool"#, reads: #"reader.bool("Flag")"#)
        expect(#"("Flag") nonisolated static var flag: Bool"#, reads: #"Self.reader.bool("Flag")"#)
        expect(#"(Key.flag) static var flag: Bool"#, reads: #"Self.reader.bool(Key.flag)"#)
    }

    func testDiagnostics() {
        expectError(
            #"@LaunchArgument("Flag") static var flag = false"#,
            "@LaunchArgument takes no initial value: give a release build's value as `release:`"
        )
        expectError(
            #"@LaunchArgument("Flag") static let flag: Bool"#,
            "@LaunchArgument applies to a `var`"
        )
        expectError(
            #"@LaunchArgument("Point") static var point: CGPoint?"#,
            "@LaunchArgument can't read `CGPoint?`: write its getter by hand"
        )
        expectError(
            #"@LaunchArgument("Pair") static var pair: (Int, Int)?"#,
            "@LaunchArgument can't read `(Int, Int)?`: write its getter by hand"
        )
        expectError(
            #"@LaunchArgument("Flag") static var flag: Bool?"#,
            "@LaunchArgument reads a missing flag as false: declare it `Bool`, with `unset:` for another default"
        )
        expectError(
            #"@LaunchArgument("Mode") static var mode: Mode"#,
            "@LaunchArgument needs `unset:` or `release:` for a non-optional `Mode`, or declare it optional"
        )
        expectError(
            #"@LaunchArgument("Name", as: .size) static var name: String?"#,
            "@LaunchArgument can't read `String?` as `.size`"
        )
        expectError(
            #"@LaunchArgument("Name", separator: ";") static var name: String?"#,
            "`separator:` applies only to lists (`.list`, `.numbers`)"
        )
    }

    func testAMissingTypeIsDiagnosed() {
        assertMacroExpansion(
            #"@LaunchArgument("Flag") static var flag"#,
            expandedSource: "static var flag",
            diagnostics: [
                DiagnosticSpec(
                    message: "@LaunchArgument needs the property's type written out (`: Bool`, `: String?`, ...)",
                    line: 1, column: 1
                ),
            ],
            macros: macros
        )
    }
}
