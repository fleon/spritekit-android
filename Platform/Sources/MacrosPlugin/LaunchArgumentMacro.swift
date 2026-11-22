import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@LaunchArgument("Key")` on a `var` with an explicit type: a getter that
/// reads the key through a `LaunchArgumentReader`, by the reader method the
/// declared type picks (or `as:`).
public struct LaunchArgumentMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw LaunchArgumentError("@LaunchArgument applies to a `var`")
        }
        guard variable.bindings.count == 1, let binding = variable.bindings.first else {
            throw LaunchArgumentError("@LaunchArgument applies to one property at a time")
        }
        guard binding.initializer == nil else {
            throw LaunchArgumentError("@LaunchArgument takes no initial value: give a release build's value as `release:`")
        }
        guard binding.accessorBlock == nil else {
            throw LaunchArgumentError("@LaunchArgument writes the property's getter: leave out its accessors")
        }
        guard let declaredType = binding.typeAnnotation?.type else {
            throw LaunchArgumentError("@LaunchArgument needs the property's type written out (`: Bool`, `: String?`, ...)")
        }

        let arguments = try LaunchArgumentArguments(node)
        let (wrapped, isOptional) = unwrapOptional(declaredType)
        guard let shape = LaunchArgumentShape(wrapped) else {
            throw LaunchArgumentError("@LaunchArgument can't read `\(declaredType.trimmedDescription)`: write its getter by hand")
        }
        let method = try arguments.method ?? defaultMethod(for: shape, optional: isOptional, declared: declaredType)
        guard let conversion = method.conversion(to: shape, optional: isOptional) else {
            throw LaunchArgumentError("@LaunchArgument can't read `\(declaredType.trimmedDescription)` as `.\(method.rawValue)`")
        }
        if arguments.separator != nil, method != .list, method != .numbers {
            throw LaunchArgumentError("`separator:` applies only to lists (`.list`, `.numbers`)")
        }

        let body = try getterBody(
            method: method, conversion: conversion, shape: shape, optional: isOptional,
            declared: declaredType, arguments: arguments
        )
        return ["get { \(raw: body) }"]
    }

    private static func getterBody(
        method: LaunchArgumentMethod, conversion: LaunchArgumentConversion, shape: LaunchArgumentShape, optional: Bool,
        declared: TypeSyntax, arguments: LaunchArgumentArguments
    ) throws -> String {
        let reader = arguments.reader
        var call = "\(reader).\(method.rawValue)(\(arguments.key)"
        if let separator = arguments.separator { call += ", separator: \(separator)" }

        if method == .bool {
            if let unset = arguments.unset {
                return call + ", unset: \(unset), release: \(arguments.release ?? unset))"
            }
            return call + (arguments.release.map { ", release: \($0))" } ?? ")")
        }

        // What an unset key reads as: nil for an optional, else `unset:`,
        // the release value or the type's zero.
        let fallback: String?
        if let unset = arguments.unset {
            fallback = unset
        } else if optional {
            fallback = nil
        } else if let value = arguments.release ?? shape.zero {
            fallback = value
        } else {
            throw LaunchArgumentError(
                "@LaunchArgument needs `unset:` or `release:` for a non-optional `\(declared.trimmedDescription)`, or declare it optional"
            )
        }

        var read = call
        if case .direct = conversion, optional, arguments.unset == nil {
            // The reader answers the release value itself.
            return read + (arguments.release.map { ", release: \($0))" } ?? ")")
        }
        read += ")"
        if case .map(let suffix) = conversion { read += suffix }
        if let fallback { read += " ?? \(fallback)" }
        // Unset and in a release build read alike unless both are given, or
        // a converted optional has its own release value.
        guard let release = arguments.release, optional || arguments.unset != nil else { return read }
        return "\(reader).isEnabled ? \(read) : \(release)"
    }

    private static func defaultMethod(for shape: LaunchArgumentShape, optional: Bool, declared: TypeSyntax) throws -> LaunchArgumentMethod {
        switch shape {
        case .named(let name, _):
            switch name {
            case "Bool":
                guard !optional else {
                    throw LaunchArgumentError(
                        "@LaunchArgument reads a missing flag as false: declare it `Bool`, with `unset:` for another default"
                    )
                }
                return .bool
            case "String", "URL": return .string
            case "Int": return .int
            case "Double", "TimeInterval", "CGFloat", "Float": return .double
            case "CGSize": return .size
            case _ where LaunchArgumentShape.integers.contains(name): return .string
            case _ where LaunchArgumentShape.unreadable.contains(name):
                throw LaunchArgumentError("@LaunchArgument can't read `\(declared.trimmedDescription)`: write its getter by hand")
            default: return .value
            }
        case .array(let name, _):
            return LaunchArgumentShape.floats.contains(name) ? .numbers : .list
        }
    }

    private static func unwrapOptional(_ type: TypeSyntax) -> (TypeSyntax, Bool) {
        if let optional = type.as(OptionalTypeSyntax.self) { return (optional.wrappedType, true) }
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.name.text == "Optional",
           let arguments = identifier.genericArgumentClause?.arguments, arguments.count == 1,
           let argument = arguments.first {
            return (argument.argument, true)
        }
        return (type, false)
    }
}

/// The reader's methods, as `LaunchArgumentRead` names them.
enum LaunchArgumentMethod: String {
    case bool, string, int, double, value, list, numbers, size, fraction

    func conversion(to shape: LaunchArgumentShape, optional: Bool) -> LaunchArgumentConversion? {
        switch (self, shape) {
        case (.bool, .named("Bool", _)):
            return optional ? nil : .direct
        case (.bool, _):
            return nil
        case (.string, .named(let name, let spelled)):
            if name == "String" { return .direct }
            if name == "URL" { return .map(".flatMap { \(spelled)(string: $0) }") }
            return LaunchArgumentShape.integers.contains(name) || LaunchArgumentShape.floats.contains(name) ? .map(".flatMap { \(spelled)($0) }") : nil
        case (.int, .named("Int", _)):
            return .direct
        case (.double, .named(let name, let spelled)), (.fraction, .named(let name, let spelled)):
            if name == "Double" || name == "TimeInterval" { return .direct }
            return name == "CGFloat" || name == "Float" ? .map(".map { \(spelled)($0) }") : nil
        case (.size, .named("CGSize", _)):
            return .direct
        case (.value, .named(let name, _)):
            return LaunchArgumentShape.unreadable.contains(name) || name == "Bool" ? nil : .direct
        case (.list, .array(let name, let spelled)):
            if name == "String" { return .direct }
            if name == "URL" { return .map(".map { $0.compactMap { \(spelled)(string: $0) } }") }
            if LaunchArgumentShape.integers.contains(name) || LaunchArgumentShape.floats.contains(name) || name == "Int" {
                return .map(".map { $0.compactMap { \(spelled)($0) } }")
            }
            return LaunchArgumentShape.unreadable.contains(name) || name == "Bool" ? nil : .map(".map { $0.compactMap { \(spelled)(rawValue: $0) } }")
        case (.numbers, .array(let name, let spelled)):
            if name == "Double" || name == "TimeInterval" { return .direct }
            return name == "CGFloat" || name == "Float" ? .map(".map { $0.map { \(spelled)($0) } }") : nil
        default:
            return nil
        }
    }
}

enum LaunchArgumentConversion {
    /// The reader's answer is the property's type.
    case direct
    /// The reader's optional answer, mapped onto the property's type.
    case map(String)
}

/// A declared type, by its last name (`Foundation.URL` is `URL`) and as spelled.
enum LaunchArgumentShape {
    case named(String, spelled: String)
    case array(String, spelled: String)

    static let integers: Set<String> = ["Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64"]
    static let floats: Set<String> = ["Double", "TimeInterval", "CGFloat", "Float"]
    /// Types no reader method answers and that aren't string-backed enums.
    static let unreadable: Set<String> = ["CGPoint", "CGRect", "CGVector", "Date", "Data", "Character", "Any"]

    init?(_ type: TypeSyntax) {
        if let array = type.as(ArrayTypeSyntax.self) {
            guard let element = Self.name(array.element) else { return nil }
            self = .array(element, spelled: array.element.trimmedDescription)
        } else if let name = Self.name(type) {
            self = .named(name, spelled: type.trimmedDescription)
        } else {
            return nil
        }
    }

    private static func name(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil {
            return member.name.text
        }
        return nil
    }

    /// What an unset key reads as for a non-optional of this type.
    var zero: String? {
        switch self {
        case .named(let name, _):
            if name == "String" { return "\"\"" }
            if name == "CGSize" { return ".zero" }
            return name == "Int" || Self.integers.contains(name) || Self.floats.contains(name) ? "0" : nil
        case .array:
            return "[]"
        }
    }
}

private struct LaunchArgumentArguments {
    var key = ""
    var release: String?
    var unset: String?
    var method: LaunchArgumentMethod?
    var separator: String?
    var reader = "Self.reader"

    init(_ node: AttributeSyntax) throws {
        guard let list = node.arguments?.as(LabeledExprListSyntax.self), let first = list.first, first.label == nil else {
            throw LaunchArgumentError("@LaunchArgument needs its key first: `@LaunchArgument(\"Key\")`")
        }
        key = first.expression.trimmedDescription
        for argument in list.dropFirst() {
            let expression = argument.expression
            switch argument.label?.text {
            case "release":
                release = expression.is(NilLiteralExprSyntax.self) ? nil : expression.trimmedDescription
            case "unset":
                unset = expression.trimmedDescription
            case "as":
                guard let name = expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text,
                      let named = LaunchArgumentMethod(rawValue: name) else {
                    throw LaunchArgumentError("`as:` takes one of `LaunchArgumentRead`'s cases (`.fraction`, ...)")
                }
                method = named
            case "separator":
                separator = expression.trimmedDescription
            case "reader":
                guard let literal = expression.as(StringLiteralExprSyntax.self),
                      literal.segments.count == 1,
                      let text = literal.segments.first?.as(StringSegmentSyntax.self)?.content.text,
                      !text.isEmpty else {
                    throw LaunchArgumentError("`reader:` takes the reader's expression as a string literal (`reader: \"Debug.reader\"`)")
                }
                reader = text
            default:
                throw LaunchArgumentError("@LaunchArgument has no argument `\(argument.label?.text ?? "_")`")
            }
        }
    }
}

struct LaunchArgumentError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
