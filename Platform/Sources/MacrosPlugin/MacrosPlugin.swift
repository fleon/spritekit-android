import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct MacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        NSCodingUnsupportedMacro.self,
        LocalizedStringsMacro.self, LocalizedCaseMacro.self,
        LaunchArgumentMacro.self,
        DecodableDefaultsMacro.self,
        StoredMacro.self, SyncedMacro.self, SyncedKeyMacro.self, SyncedKeysMacro.self,
        SingletonMacro.self,
    ]
}

public struct NSCodingUnsupportedMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let inherited = try passThroughInits(node, declaration)
        // A public or open class's required initializer is public too, as
        // Swift asks of one a subclass elsewhere must override.
        let isPublic = declaration.modifiers.contains {
            $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open)
        }
        let access = isPublic ? "public " : ""
        let initDecl: DeclSyntax =
            """
            \(raw: access)required init?(coder aDecoder: NSCoder) {
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
        let names = arguments.map { $0.expression.trimmedDescription.split(separator: ".").last.map(String.init) ?? "" }
        if names.contains("plain"), names.contains("requiredPlain") {
            throw NSCodingUnsupportedError(description: "@NSCodingUnsupported takes `.plain` or `.requiredPlain`, not both: each writes `init()`")
        }
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
            case "requiredPlain":
                return """
                \(raw: access)required override init() {
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
                throw NSCodingUnsupportedError(description: "@NSCodingUnsupported passes through `.plain`, `.requiredPlain` or `.size`, not \(argument.expression.trimmedDescription)")
            }
        }
    }
}

private struct NSCodingUnsupportedError: Error, CustomStringConvertible {
    let description: String
}
