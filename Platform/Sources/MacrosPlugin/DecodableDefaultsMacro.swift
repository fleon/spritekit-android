import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@DecodableDefaults`: writes `init(from:)` so a stored property with an
/// initial value takes it when its key is missing or null.
///
/// A struct gets the initializer in an extension, so it keeps its memberwise
/// initializer; a class gets it in its body, where a designated initializer
/// has to be, and so does a `private` struct, which an extension couldn't
/// name. All get a private `CodingKeys` unless they declare their own.
public struct DecodableDefaultsMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let plan = Plan(declaration, node: node) else {
            context.diagnose(Diagnostic(node: node, message: Message.notStructOrClass))
            return []
        }
        plan.diagnostics.forEach(context.diagnose)
        guard plan.isValid else { return [] }

        var members: [DeclSyntax] = []
        if let codingKeys = plan.generatedCodingKeys { members.append(codingKeys) }
        if plan.inBody { members.append(plan.initializer) }
        return members
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let plan = Plan(declaration, node: node), plan.isValid else { return [] }
        // A private type can't be extended by name from file scope: it
        // states its own conformance.
        if plan.inBody && (protocols.isEmpty || plan.isPrivate) { return [] }
        let conformance = protocols.isEmpty ? "" : ": Decodable"
        let body = plan.inBody ? "" : plan.initializer.description
        let decl: DeclSyntax = "extension \(type.trimmed)\(raw: conformance) {\n\(raw: body)\n}"
        guard let ext = decl.as(ExtensionDeclSyntax.self) else { return [] }
        return [ext]
    }
}

private struct StoredProperty {
    let name: String
    let type: TypeSyntax?
    let initializer: ExprSyntax?
    let isLet: Bool
    let node: Syntax
}

private struct Plan {
    let isClass: Bool
    let isPrivate: Bool
    let initializer: DeclSyntax
    let generatedCodingKeys: DeclSyntax?
    let diagnostics: [Diagnostic]

    var inBody: Bool { isClass || isPrivate }
    var isValid: Bool { !diagnostics.contains { $0.diagMessage.severity == .error } }

    init?(_ declaration: some DeclGroupSyntax, node: AttributeSyntax) {
        let modifiers: DeclModifierListSyntax
        if let s = declaration.as(StructDeclSyntax.self) {
            isClass = false
            modifiers = s.modifiers
        } else if let c = declaration.as(ClassDeclSyntax.self) {
            isClass = true
            modifiers = c.modifiers
        } else {
            return nil
        }

        isPrivate = modifiers.contains { $0.name.text == "private" }
        var diagnostics: [Diagnostic] = []
        let members = declaration.memberBlock.members.map(\.decl)
        let properties = Self.storedProperties(in: members)
        let declaredKeys = Self.declaredCodingKeys(in: members)

        if members.contains(where: Self.isInitFromDecoder) {
            diagnostics.append(Diagnostic(node: node, message: Message.alreadyDecodes))
        }

        let keys = declaredKeys ?? properties.map(\.name)
        let keySet = Set(keys.map(Self.bare))
        var lines: [String] = []
        for property in properties {
            let key = Self.bare(property.name)
            guard keySet.contains(key) else {
                let hasDefault = property.initializer != nil
                    || (!property.isLet && property.type.flatMap(Self.optionalWrapped) != nil)
                if !hasDefault {
                    diagnostics.append(Diagnostic(
                        node: property.node, message: Message.notInCodingKeys(key)))
                }
                continue
            }
            if property.isLet && property.initializer != nil {
                diagnostics.append(Diagnostic(node: property.node, message: Message.letWithValue(key)))
                continue
            }
            guard let line = Self.decodeLine(for: property) else {
                diagnostics.append(Diagnostic(node: property.node, message: Message.needsType(key)))
                continue
            }
            lines.append(line)
        }

        var prefix: [String] = []
        if modifiers.contains(where: { ["public", "open"].contains($0.name.text) }) {
            prefix.append("public")
        }
        if isClass && !modifiers.contains(where: { $0.name.text == "final" }) {
            prefix.append("required")
        }
        if modifiers.contains(where: { $0.name.text == "nonisolated" }) {
            prefix.append("nonisolated")
        }
        let head = (prefix + ["init(from decoder: Decoder) throws"]).joined(separator: " ")
        let body = lines.isEmpty
            ? ""
            : (["let container = try decoder.container(keyedBy: CodingKeys.self)"] + lines)
                .map { "    " + $0 }.joined(separator: "\n")
        initializer = "\(raw: head) {\n\(raw: body)\n}"

        if declaredKeys == nil && !keys.isEmpty {
            generatedCodingKeys = """
                private enum CodingKeys: String, CodingKey {
                    case \(raw: keys.joined(separator: ", "))
                }
                """
        } else {
            generatedCodingKeys = nil
        }
        self.diagnostics = diagnostics
    }

    private static func decodeLine(for property: StoredProperty) -> String? {
        let key = ".\(property.name)"
        let target = "self.\(property.name)"
        if let initializer = property.initializer {
            let fallback = parenthesizedIfNeeded(initializer)
            guard let type = property.type else {
                return "\(target) = try container.decodeIfPresent(forKey: \(key)) ?? \(fallback)"
            }
            let decoded = optionalWrapped(type) ?? type
            return "\(target) = try container.decodeIfPresent(\(decoded.trimmed).self, forKey: \(key)) ?? \(fallback)"
        }
        guard let type = property.type else { return nil }
        if let wrapped = optionalWrapped(type) {
            return "\(target) = try container.decodeIfPresent(\(wrapped.trimmed).self, forKey: \(key))"
        }
        return "\(target) = try container.decode(\(type.trimmed).self, forKey: \(key))"
    }

    /// Stored instance properties in declaration order: no statics, no
    /// computed or lazy ones. Observers (`willSet`, `didSet`) keep storage.
    private static func storedProperties(in members: [DeclSyntax]) -> [StoredProperty] {
        var result: [StoredProperty] = []
        for member in members {
            guard let variable = member.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: {
                      ["static", "class", "lazy"].contains($0.name.text)
                  })
            else { continue }
            let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
            let bindings = Array(variable.bindings)
            for (index, binding) in bindings.enumerated() {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      !isComputed(binding)
                else { continue }
                // `var a, b: Int` gives `a` the type written after `b`.
                let type = binding.typeAnnotation?.type ?? (binding.initializer == nil
                    ? bindings[(index + 1)...].lazy.compactMap { $0.typeAnnotation?.type }.first
                    : nil)
                result.append(StoredProperty(
                    name: pattern.identifier.text,
                    type: type,
                    initializer: binding.initializer?.value,
                    isLet: isLet,
                    node: Syntax(binding)
                ))
            }
        }
        return result
    }

    private static func isComputed(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessors = binding.accessorBlock?.accessors else { return false }
        switch accessors {
        case .getter:
            return true
        case .accessors(let list):
            return list.contains {
                ![.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind)
            }
        }
    }

    private static func declaredCodingKeys(in members: [DeclSyntax]) -> [String]? {
        guard let keys = members.lazy.compactMap({ $0.as(EnumDeclSyntax.self) })
            .first(where: { $0.name.text == "CodingKeys" })
        else { return nil }
        return keys.memberBlock.members.flatMap { member -> [String] in
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { return [] }
            return caseDecl.elements.map(\.name.text)
        }
    }

    private static func isInitFromDecoder(_ decl: DeclSyntax) -> Bool {
        guard let initDecl = decl.as(InitializerDeclSyntax.self) else { return false }
        let parameters = initDecl.signature.parameterClause.parameters
        return parameters.count == 1 && parameters.first?.firstName.text == "from"
    }

    static func optionalWrapped(_ type: TypeSyntax) -> TypeSyntax? {
        if let optional = type.as(OptionalTypeSyntax.self) { return optional.wrappedType }
        if let iuo = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return iuo.wrappedType }
        if let named = type.as(IdentifierTypeSyntax.self), named.name.text == "Optional",
           let argument = named.genericArgumentClause?.arguments.first {
            return argument.argument
        }
        return nil
    }

    /// `?? a ? b : c` and `?? try f()` don't parse as meant; bracket anything
    /// built from operators.
    private static func parenthesizedIfNeeded(_ expr: ExprSyntax) -> String {
        let text = expr.trimmedDescription
        let needsParens = expr.is(SequenceExprSyntax.self) || expr.is(TernaryExprSyntax.self)
            || expr.is(TryExprSyntax.self) || expr.is(AwaitExprSyntax.self)
            || expr.is(InfixOperatorExprSyntax.self) || expr.is(AsExprSyntax.self)
            || expr.is(IsExprSyntax.self)
        return needsParens ? "(\(text))" : text
    }

    static func bare(_ name: String) -> String {
        guard name.count > 1, name.hasPrefix("`"), name.hasSuffix("`") else { return name }
        return String(name.dropFirst().dropLast())
    }
}

private enum Message: DiagnosticMessage {
    case notStructOrClass
    case alreadyDecodes
    case letWithValue(String)
    case notInCodingKeys(String)
    case needsType(String)

    var message: String {
        switch self {
        case .notStructOrClass:
            return "@DecodableDefaults applies to a struct or a class"
        case .alreadyDecodes:
            return "@DecodableDefaults writes init(from:); remove the one declared here"
        case .letWithValue(let name):
            return "immutable property '\(name)' will not be decoded because it is declared with an initial value which cannot be overwritten; make it 'var' to decode it with that value as its default"
        case .notInCodingKeys(let name):
            return "'\(name)' has no key in CodingKeys and no initial value to take instead"
        case .needsType(let name):
            return "'\(name)' needs a type annotation to be decoded"
        }
    }

    var diagnosticID: MessageID {
        let id: String
        switch self {
        case .notStructOrClass: id = "notStructOrClass"
        case .alreadyDecodes: id = "alreadyDecodes"
        case .letWithValue: id = "letWithValue"
        case .notInCodingKeys: id = "notInCodingKeys"
        case .needsType: id = "needsType"
        }
        return MessageID(domain: "DecodableDefaults", id: id)
    }

    var severity: DiagnosticSeverity {
        if case .letWithValue = self { return .warning }
        return .error
    }
}
