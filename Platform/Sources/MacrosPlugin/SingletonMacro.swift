import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Singleton` on a class, struct or actor: `static let shared`, and a
/// private `init()` unless the type writes one.
public struct SingletonMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let name: String
        var inherited: [String] = []
        if let type = declaration.as(ClassDeclSyntax.self) {
            name = type.name.text
            inherited = type.inheritanceClause?.inheritedTypes.map(\.type.trimmedDescription) ?? []
        } else if let type = declaration.as(StructDeclSyntax.self) {
            name = type.name.text
        } else if let type = declaration.as(ActorDeclSyntax.self) {
            name = type.name.text
        } else {
            throw SingletonError("@Singleton applies to a class, struct or actor")
        }

        let members = declaration.memberBlock.members.map(\.decl)
        let declaresShared = members.contains { member in
            member.as(VariableDeclSyntax.self)?.bindings.contains {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "shared"
            } ?? false
        }
        if declaresShared {
            throw SingletonError("@Singleton writes `shared`: remove the type's own")
        }
        let inits = members.compactMap { $0.as(InitializerDeclSyntax.self) }
        let hasPlainInit = inits.contains { $0.signature.parameterClause.parameters.isEmpty }
        if !inits.isEmpty, !hasPlainInit {
            throw SingletonError("@Singleton makes `shared` with `init()`: add a private `init()`, or make the instance where its arguments are known")
        }

        let isPublic = declaration.modifiers.contains { ["public", "open"].contains($0.name.text) }
        var result: [DeclSyntax] = ["\(raw: isPublic ? "public " : "")static let shared = \(raw: name)()"]
        if !hasPlainInit {
            if inherited.first == "NSObject" {
                result.append("private override init() { super.init() }")
            } else {
                result.append("private init() {}")
            }
        }
        return result
    }
}

private struct SingletonError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
