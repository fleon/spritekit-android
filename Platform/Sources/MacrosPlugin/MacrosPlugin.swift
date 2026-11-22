import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct MacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        NSCodingUnsupportedMacro.self,
    ]
}

public struct NSCodingUnsupportedMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let inherited = try passThroughInits(node, declaration)
        let initDecl: DeclSyntax =
            """
            required init?(coder aDecoder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }
            """

        return inherited + [initDecl]
    }

    /// The designated initializers `inherit:` names, passed straight to super.
    private static func passThroughInits(_ node: AttributeSyntax, _ declaration: some DeclGroupSyntax) throws -> [DeclSyntax] {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return [] }
        let access = declaration.modifiers.contains { ["public", "open"].contains($0.name.text) } ? "public " : ""
        var seen = Set<String>()
        return try arguments.compactMap { argument -> DeclSyntax? in
            let name = argument.expression.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
            guard seen.insert(name).inserted else { return nil }
            switch name {
            case "plain":
                return """
                \(raw: access)override init() {
                    super.init()
                }
                """
            case "size":
                return """
                \(raw: access)override init(size: CGSize) {
                    super.init(size: size)
                }
                """
            default:
                throw NSCodingUnsupportedError(description: "@NSCodingUnsupported passes through `.plain` or `.size`, not \(argument.expression.trimmedDescription)")
            }
        }
    }
}

private struct NSCodingUnsupportedError: Error, CustomStringConvertible {
    let description: String
}
