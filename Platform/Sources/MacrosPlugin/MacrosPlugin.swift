import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct MacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        NSCodingUnsupportedMacro.self,
        LocalizedStringsMacro.self, LocalizedCaseMacro.self,
    ]
}

public struct NSCodingUnsupportedMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
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

        return [initDecl]
    }
}
