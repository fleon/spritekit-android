import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Stored`: a property read from and saved to user defaults.
public struct StoredMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let arguments = SavedValueArguments(node)
        let store = arguments["defaults"] ?? "UserDefaults.standard"
        let property = try SavedProperty(declaration, macro: "Stored")
        return try property.accessors(key: arguments.key(macro: "Stored"), store: store, default: arguments["default"], readOnly: false)
    }
}

/// `@Synced`: a property read through the sync manager and saved through it.
public struct SyncedMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let arguments = SavedValueArguments(node)
        let property = try SavedProperty(declaration, macro: "Synced")
        let pooled = arguments.merge == ".union"
        if pooled, !property.kind.isStringCollection {
            throw SavedValueError("a `.union` key is a set of strings: give it a `[String]` or `Set<String>` property")
        }
        return try property.accessors(
            key: arguments.key(macro: "Synced"),
            store: "ICloudSyncManager.shared",
            default: arguments["default"],
            readOnly: pooled
        )
    }
}

/// `@SyncedKey`: only a mark for `@SyncedKeys` to find.
public struct SyncedKeyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              variable.bindings.count == 1,
              variable.bindings.first?.pattern.is(IdentifierPatternSyntax.self) == true else {
            throw SavedValueError("@SyncedKey marks one key constant, as `static let cleared = \"progress.cleared\"`")
        }
        return []
    }
}

/// `@SyncedKeys`: every synced key the owner declares, with its merge.
public struct SyncedKeysMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        var entries: [(key: String, merge: String)] = []
        collect(in: declaration.memberBlock, path: [], into: &entries)

        var seen = Set<String>()
        for entry in entries where !seen.insert(entry.key).inserted {
            throw SavedValueError("\(entry.key) is listed twice")
        }

        let list = entries.isEmpty
            ? "[:]"
            : "[\n" + entries.map { "    \($0.key): \($0.merge),\n" }.joined() + "]"
        let access = declaration.modifiers.contains { ["public", "open"].contains($0.name.text) } ? "public " : ""
        return ["\(raw: access)nonisolated static let syncedKeys: [String: ICloudSyncManager.Merge] = \(raw: list)"]
    }

    /// `@Synced` properties among the owner's own members (their keys read
    /// in its scope), `@SyncedKey` constants in it and its nested types.
    private static func collect(in members: MemberBlockSyntax, path: [String], into entries: inout [(key: String, merge: String)]) {
        for member in members.members {
            let decl = member.decl
            if let variable = decl.as(VariableDeclSyntax.self) {
                for attribute in variable.attributes {
                    guard let attribute = attribute.as(AttributeSyntax.self) else { continue }
                    let arguments = SavedValueArguments(attribute)
                    switch attribute.attributeName.trimmedDescription {
                    case "Synced" where path.isEmpty:
                        if let key = try? arguments.key(macro: "Synced") { entries.append((key, arguments.merge)) }
                    case "SyncedKey":
                        guard let name = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                        entries.append(((path + [name]).joined(separator: "."), arguments.merge))
                    default:
                        continue
                    }
                }
            } else if let nested = decl.asProtocol(DeclGroupSyntax.self), let name = nestedName(of: decl) {
                collect(in: nested.memberBlock, path: path + [name], into: &entries)
            }
        }
    }

    private static func nestedName(of decl: DeclSyntax) -> String? {
        if let type = decl.as(EnumDeclSyntax.self) { return type.name.text }
        if let type = decl.as(StructDeclSyntax.self) { return type.name.text }
        if let type = decl.as(ClassDeclSyntax.self) { return type.name.text }
        return nil
    }
}

// MARK: - Shared

private struct SavedValueError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The attribute's arguments, by label (the key is the unlabeled first).
private struct SavedValueArguments {
    private var labeled: [String: String] = [:]
    private var unlabeled: String?

    init(_ node: AttributeSyntax) {
        guard let list = node.arguments?.as(LabeledExprListSyntax.self) else { return }
        for argument in list {
            let text = argument.expression.trimmedDescription
            if let label = argument.label?.text { labeled[label] = text } else if unlabeled == nil { unlabeled = text }
        }
    }

    subscript(label: String) -> String? { labeled[label] }

    var merge: String {
        let text = labeled["merge"] ?? ".latest"
        return text.hasSuffix(".union") ? ".union" : text.hasSuffix(".latest") ? ".latest" : text
    }

    func key(macro: String) throws -> String {
        guard let unlabeled else { throw SavedValueError("@\(macro) needs its key: @\(macro)(\"settings.example\")") }
        return unlabeled
    }
}

/// What a saved value's type reads and saves through.
private enum SavedKind {
    /// Read through a typed reader that answers a missing key with `zero`.
    case number(reader: String, zero: String)
    /// Read through a reader that answers nil for a missing key.
    case optionalReader(reader: String, zero: String)
    case stringSet
    /// Any other type, saved as is and read back cast.
    case object(type: String)

    init(_ type: String) {
        switch type {
        case "Int": self = .number(reader: "integer", zero: "0")
        case "Bool": self = .number(reader: "bool", zero: "false")
        case "Double": self = .number(reader: "double", zero: "0")
        case "String": self = .optionalReader(reader: "string", zero: "\"\"")
        case "[String]", "Array<String>": self = .optionalReader(reader: "stringArray", zero: "[]")
        case "Data": self = .optionalReader(reader: "data", zero: "Data()")
        case "Set<String>": self = .stringSet
        default: self = .object(type: type)
        }
    }

    var isStringCollection: Bool {
        switch self {
        case .stringSet: return true
        case .optionalReader(reader: "stringArray", _): return true
        default: return false
        }
    }
}

private struct SavedProperty {
    let kind: SavedKind
    let isOptional: Bool

    init(_ declaration: some DeclSyntaxProtocol, macro: String) throws {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              variable.bindingSpecifier.tokenKind == .keyword(.var),
              variable.bindings.count == 1,
              let binding = variable.bindings.first else {
            throw SavedValueError("@\(macro) goes on one `var` with its type: `static var example: Int`")
        }
        guard let type = binding.typeAnnotation?.type else {
            throw SavedValueError("@\(macro) needs the property's type written out")
        }
        if binding.initializer != nil {
            throw SavedValueError("@\(macro) takes its starting value as `default:`, not an initializer")
        }
        if binding.accessorBlock != nil {
            throw SavedValueError("@\(macro) writes the property's accessors: leave them out")
        }
        if let optional = type.as(OptionalTypeSyntax.self) {
            isOptional = true
            kind = SavedKind(optional.wrappedType.trimmedDescription)
        } else if let generic = type.as(IdentifierTypeSyntax.self), generic.name.text == "Optional",
                  let wrapped = generic.genericArgumentClause?.arguments.first?.argument {
            isOptional = true
            kind = SavedKind(wrapped.trimmedDescription)
        } else {
            isOptional = false
            kind = SavedKind(type.trimmedDescription)
        }
    }

    func accessors(key: String, store: String, default value: String?, readOnly: Bool) throws -> [AccessorDeclSyntax] {
        if isOptional, value != nil {
            throw SavedValueError("an optional reads nil until saved: leave out `default:`")
        }
        let read = try reading(key: key, store: store, default: value)
        let getter: AccessorDeclSyntax =
            """
            get {
                \(raw: read)
            }
            """
        guard !readOnly else { return [getter] }
        var saved = "newValue"
        if case .stringSet = kind { saved = isOptional ? "newValue?.sorted()" : "newValue.sorted()" }
        let setter: AccessorDeclSyntax =
            """
            set {
                \(raw: store).set(\(raw: saved), forKey: \(raw: key))
            }
            """
        return [getter, setter]
    }

    private func reading(key: String, store: String, default value: String?) throws -> String {
        let object = "\(store).object(forKey: \(key))"
        switch kind {
        case let .number(reader, zero):
            let typed = "\(store).\(reader)(forKey: \(key))"
            if isOptional { return "\(object) != nil ? \(typed) : nil" }
            guard let value, value != zero else { return typed }
            return "\(object) != nil ? \(typed) : \(value)"
        case let .optionalReader(reader, zero):
            let typed = "\(store).\(reader)(forKey: \(key))"
            return isOptional ? typed : "\(typed) ?? \(value ?? zero)"
        case .stringSet:
            let typed = "\(store).stringArray(forKey: \(key)).map(Set.init)"
            return isOptional ? typed : "\(typed) ?? \(value ?? "[]")"
        case let .object(type):
            if isOptional { return "\(object) as? \(type)" }
            guard let value else {
                throw SavedValueError("a \(type) needs `default:`, what it reads before it's saved")
            }
            return "\(object) as? \(type) ?? \(value)"
        }
    }
}
