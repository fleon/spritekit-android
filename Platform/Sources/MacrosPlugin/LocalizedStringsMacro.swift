import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@LocalizedStrings` on an enum whose every case carries `@L(...)`: the
/// enum's `key`, `fallback` and `comment` (when any case gives one) and
/// `localized`, each one switch written once here instead of by hand.
public struct LocalizedStringsMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: LocalizedStringsMessage.notAnEnum))
            return []
        }
        let options = EnumOptions(node)
        let cases = collectCases(enumDecl, in: context)
        guard !cases.isEmpty else { return [] }
        diagnoseDuplicates(cases, in: context)

        let hasFallback = cases.contains { $0.fallback != nil }
        let hasComment = cases.contains { $0.comment != nil }
        for entry in cases where !entry.customKey {
            if hasFallback, entry.fallback == nil {
                context.diagnose(Diagnostic(node: entry.attribute, message: LocalizedStringsMessage.missing("fallback", entry.name)))
            }
            if hasComment, entry.comment == nil {
                context.diagnose(Diagnostic(node: entry.attribute, message: LocalizedStringsMessage.missing("comment", entry.name)))
            }
            diagnosePlaceholders(entry, defaultFormatting: options.formatting, in: context)
        }

        let prefix = memberPrefix(enumDecl)
        var members: [DeclSyntax] = [
            property("key", prefix: prefix, cases: cases) { $0.customKey ? "customKey" : $0.key ?? "\"\"" },
        ]
        if hasFallback {
            members.append(property("fallback", prefix: prefix, cases: cases) { $0.customKey ? "customFallback" : $0.fallback ?? "\"\"" })
        }
        if hasComment {
            members.append(property("comment", prefix: prefix, cases: cases) { $0.customKey ? "customComment" : $0.comment ?? "\"\"" })
        }
        members.append(localized(prefix: prefix, cases: cases, options: options, hasFallback: hasFallback, hasComment: hasComment))
        return members
    }

    // MARK: - Reading the enum

    private static func collectCases(_ enumDecl: EnumDeclSyntax, in context: some MacroExpansionContext) -> [CaseEntry] {
        var cases: [CaseEntry] = []
        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            let marker = caseDecl.attributes.lazy
                .compactMap { $0.as(AttributeSyntax.self) }
                .first { $0.attributeName.trimmedDescription == "L" }
            guard let marker else {
                context.diagnose(Diagnostic(
                    node: caseDecl,
                    message: LocalizedStringsMessage.unmarked(caseDecl.elements.map(\.name.text).joined(separator: ", ")),
                    fixIts: [addMarkerFixIt(caseDecl)]
                ))
                continue
            }
            guard caseDecl.elements.count == 1, let element = caseDecl.elements.first else {
                context.diagnose(Diagnostic(node: caseDecl, message: LocalizedStringsMessage.sharedMarker))
                continue
            }
            if let entry = CaseEntry(element: element, attribute: marker, in: context) {
                cases.append(entry)
            }
        }
        return cases
    }

    private static func addMarkerFixIt(_ caseDecl: EnumCaseDeclSyntax) -> FixIt {
        let name = caseDecl.elements.first?.name.text ?? "key"
        var marked = caseDecl
        let attribute = AttributeSyntax(
            attributeName: IdentifierTypeSyntax(name: .identifier("L")),
            leftParen: .leftParenToken(),
            arguments: .argumentList([LabeledExprSyntax(expression: StringLiteralExprSyntax(content: name))]),
            rightParen: .rightParenToken(),
            trailingTrivia: .space
        )
        marked.attributes = AttributeListSyntax([.attribute(attribute)] + Array(caseDecl.attributes))
        marked.leadingTrivia = []
        marked.attributes = marked.attributes.with(\.leadingTrivia, caseDecl.leadingTrivia)
        return FixIt(message: LocalizedStringsFixIt.addMarker(name), changes: [.replace(oldNode: Syntax(caseDecl), newNode: Syntax(marked))])
    }

    private static func diagnoseDuplicates(_ cases: [CaseEntry], in context: some MacroExpansionContext) {
        var first: [String: CaseEntry] = [:]
        for entry in cases {
            guard let key = entry.keyValue else { continue }
            if let earlier = first[key] {
                context.diagnose(Diagnostic(
                    node: entry.keyNode ?? Syntax(entry.attribute),
                    message: LocalizedStringsMessage.duplicateKey(key, earlier.name),
                    notes: [Note(node: earlier.keyNode ?? Syntax(earlier.attribute), message: LocalizedStringsNote.firstUse(key))]
                ))
            } else {
                first[key] = entry
            }
        }
    }

    private static func diagnosePlaceholders(_ entry: CaseEntry, defaultFormatting: Formatting, in context: some MacroExpansionContext) {
        guard (entry.formatting ?? defaultFormatting) != .custom,
              !entry.values.isEmpty,
              let fallback = entry.fallbackValue,
              let node = entry.fallbackNode
        else { return }
        let count = placeholderCount(fallback)
        guard count != entry.values.count else { return }
        context.diagnose(Diagnostic(node: node, message: LocalizedStringsMessage.placeholders(entry.name, count, entry.values.count)))
    }

    /// How many arguments a format string takes: its highest position when
    /// it numbers them (`%2$@`), else one per specifier. `%%` takes none.
    static func placeholderCount(_ format: String) -> Int {
        let characters = Array(format)
        var index = 0
        var count = 0
        var highest = 0
        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            index += 1
            guard index < characters.count else { break }
            if characters[index] == "%" { index += 1; continue }
            var digits = ""
            while index < characters.count, characters[index].isNumber {
                digits.append(characters[index])
                index += 1
            }
            if index < characters.count, characters[index] == "$", let position = Int(digits) {
                highest = max(highest, position)
                index += 1
            }
            while index < characters.count, !characters[index].isLetter, characters[index] != "@" {
                if characters[index] == "*" { count += 1 }
                index += 1
            }
            while index < characters.count, "hlqLztj".contains(characters[index]) {
                index += 1
            }
            guard index < characters.count else { break }
            if "@dDiuUxXoOfFeEgGcCsSpaA".contains(characters[index]) { count += 1 }
            index += 1
        }
        return highest > 0 ? highest : count
    }

    // MARK: - Writing the members

    /// `nonisolated` and the enum's `public` or `package`, as the enum says.
    private static func memberPrefix(_ enumDecl: EnumDeclSyntax) -> String {
        enumDecl.modifiers
            .map(\.name.text)
            .filter { ["public", "package", "nonisolated"].contains($0) }
            .map { $0 + " " }
            .joined()
    }

    private static func property(
        _ name: String,
        prefix: String,
        cases: [CaseEntry],
        value: (CaseEntry) -> String
    ) -> DeclSyntax {
        let arms = cases.map { "    case .\($0.name): return \(value($0))" }.joined(separator: "\n")
        return DeclSyntax(stringLiteral: "\(prefix)var \(name): String {\n    switch self {\n\(arms)\n    }\n}")
    }

    private static func localized(
        prefix: String,
        cases: [CaseEntry],
        options: EnumOptions,
        hasFallback: Bool,
        hasComment: Bool
    ) -> DeclSyntax {
        let lookup: String
        if options.customLookup {
            lookup = hasFallback ? "Self.lookup(key, fallback: fallback)" : "Self.lookup(key)"
        } else {
            var arguments = ["key"]
            if let table = options.table { arguments.append("tableName: \(table)") }
            if let bundle = options.bundle { arguments.append("bundle: \(bundle)") }
            if hasFallback { arguments.append("value: fallback") }
            arguments.append(hasComment ? "comment: comment" : "comment: \"\"")
            lookup = "NSLocalizedString(\(arguments.joined(separator: ", ")))"
        }
        var verbatim: [String] = []
        var arms: [String] = []
        for entry in cases {
            let formatting = entry.customKey ? entry.formatting : (entry.formatting ?? options.formatting)
            switch formatting {
            case .custom:
                arms.append("    case .\(entry.name): return customLocalized(format)")
            case .plain?, .localized?:
                guard !entry.values.isEmpty else {
                    verbatim.append(entry.name)
                    continue
                }
                let names = entry.values.indices.map { "value\($0)" }.joined(separator: ", ")
                let call = formatting == .localized ? "String.localizedStringWithFormat(format, " : "String(format: format, "
                arms.append("    case let .\(entry.name)(\(names)): return \(call)\(names))")
            case nil:
                verbatim.append(entry.name)
            }
        }
        if !verbatim.isEmpty {
            arms.append("    case \(verbatim.map { ".\($0)" }.joined(separator: ", ")): return format")
        }
        let body: String
        if arms.count == 1, !verbatim.isEmpty {
            body = "    \(lookup)"
        } else {
            body = "    let format = \(lookup)\n    switch self {\n\(arms.joined(separator: "\n"))\n    }"
        }
        return DeclSyntax(stringLiteral: "\(prefix)var localized: String {\n\(body)\n}")
    }
}

/// `@L(...)`: marks a case for `@LocalizedStrings`, which reads it; it adds
/// nothing itself.
public struct LocalizedCaseMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

// MARK: - Model

enum Formatting {
    case plain, localized, custom

    init?(_ expression: ExprSyntax) {
        switch expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text {
        case "plain": self = .plain
        case "localized": self = .localized
        case "custom": self = .custom
        default: return nil
        }
    }
}

private struct EnumOptions {
    var table: String?
    var bundle: String?
    var customLookup = false
    var formatting = Formatting.plain

    init(_ node: AttributeSyntax) {
        guard case let .argumentList(arguments) = node.arguments else { return }
        for argument in arguments {
            let expression = argument.expression
            if expression.is(NilLiteralExprSyntax.self) { continue }
            switch argument.label?.text {
            case "table": table = expression.trimmedDescription
            case "bundle": bundle = expression.trimmedDescription
            case "lookup": customLookup = expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "custom"
            case "formatting": formatting = Formatting(expression) ?? .plain
            default: break
            }
        }
    }
}

private struct CaseEntry {
    let name: String
    let attribute: AttributeSyntax
    let values: [EnumCaseParameterSyntax]
    var customKey = false
    var key: String?
    var keyValue: String?
    var keyNode: Syntax?
    var fallback: String?
    var fallbackValue: String?
    var fallbackNode: Syntax?
    var comment: String?
    var formatting: Formatting?

    init?(element: EnumCaseElementSyntax, attribute: AttributeSyntax, in context: some MacroExpansionContext) {
        name = element.name.text
        self.attribute = attribute
        values = element.parameterClause.map { Array($0.parameters) } ?? []
        guard case let .argumentList(arguments) = attribute.arguments, !arguments.isEmpty else {
            context.diagnose(Diagnostic(node: attribute, message: LocalizedStringsMessage.noKey(name)))
            return nil
        }
        var position = 0
        for argument in arguments {
            let expression = argument.expression
            switch argument.label?.text {
            case nil where position == 0:
                position += 1
                if expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "custom" {
                    customKey = true
                } else if let text = Self.literal(expression, in: context) {
                    key = expression.trimmedDescription
                    keyValue = text
                    keyNode = Syntax(expression)
                } else {
                    return nil
                }
            case nil:
                position += 1
                if expression.is(NilLiteralExprSyntax.self) { continue }
                guard let text = Self.literal(expression, in: context) else { return nil }
                fallback = expression.trimmedDescription
                fallbackValue = text
                fallbackNode = Syntax(expression)
            case "comment":
                if expression.is(NilLiteralExprSyntax.self) { continue }
                guard Self.literal(expression, in: context) != nil else { return nil }
                comment = expression.trimmedDescription
            case "formatting":
                formatting = Formatting(expression)
            default:
                break
            }
        }
    }

    /// A string literal's text, escapes as written; a literal with
    /// interpolation, or anything else, is diagnosed.
    private static func literal(_ expression: ExprSyntax, in context: some MacroExpansionContext) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else {
            context.diagnose(Diagnostic(node: expression, message: LocalizedStringsMessage.notALiteral))
            return nil
        }
        var text = ""
        for segment in literal.segments {
            guard let piece = segment.as(StringSegmentSyntax.self) else {
                context.diagnose(Diagnostic(node: expression, message: LocalizedStringsMessage.notALiteral))
                return nil
            }
            text += piece.content.text
        }
        return text
    }
}

// MARK: - Diagnostics

enum LocalizedStringsMessage: DiagnosticMessage {
    case notAnEnum
    case unmarked(String)
    case sharedMarker
    case noKey(String)
    case notALiteral
    case missing(String, String)
    case duplicateKey(String, String)
    case placeholders(String, Int, Int)

    var message: String {
        switch self {
        case .notAnEnum:
            return "@LocalizedStrings applies to an enum"
        case let .unmarked(names):
            return "case \(names) has no @L(...): give it its key"
        case .sharedMarker:
            return "@L marks one case: declare each case on its own line"
        case let .noKey(name):
            return "@L on case \(name) needs a key: @L(\"key\") or @L(.custom)"
        case .notALiteral:
            return "@L takes string literals without interpolation; a key built at run time is @L(.custom)"
        case let .missing(what, name):
            return "case \(name) has no \(what), though other cases do; it gets \"\""
        case let .duplicateKey(key, earlier):
            return "key \"\(key)\" is already used by case \(earlier)"
        case let .placeholders(name, placeholders, values):
            return "the fallback of case \(name) takes \(placeholders) argument\(placeholders == 1 ? "" : "s"), but the case has \(values) associated value\(values == 1 ? "" : "s")"
        }
    }

    var diagnosticID: MessageID {
        let id: String
        switch self {
        case .notAnEnum: id = "notAnEnum"
        case .unmarked: id = "unmarked"
        case .sharedMarker: id = "sharedMarker"
        case .noKey: id = "noKey"
        case .notALiteral: id = "notALiteral"
        case .missing: id = "missing"
        case .duplicateKey: id = "duplicateKey"
        case .placeholders: id = "placeholders"
        }
        return MessageID(domain: "LocalizedStrings", id: id)
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .missing: return .warning
        default: return .error
        }
    }
}

private enum LocalizedStringsNote: NoteMessage {
    case firstUse(String)

    var message: String {
        switch self {
        case let .firstUse(key): return "\"\(key)\" first used here"
        }
    }

    var fixItID: MessageID { MessageID(domain: "LocalizedStrings", id: "firstUse") }
}

private enum LocalizedStringsFixIt: FixItMessage {
    case addMarker(String)

    var message: String {
        switch self {
        case let .addMarker(name): return "add @L(\"\(name)\")"
        }
    }

    var fixItID: MessageID { MessageID(domain: "LocalizedStrings", id: "addMarker") }
}
