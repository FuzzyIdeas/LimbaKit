import Foundation

/// printf-style placeholders in a localized format string (`%@`, `%lld`, `%1$@`, `%.1f`).
public struct FormatSpecifier: Equatable, Hashable, Sendable {
    /// The placeholder as written.
    public var raw: String
    /// 1-based argument position when written as `%2$@`.
    public var position: Int?
    /// Length modifier and conversion, such as `lld` or `@`.
    public var type: String
    /// Where it sits in the string.
    public var range: Range<String.Index>

    /// True for integer conversions, the ones a plural rule can count.
    public var isInteger: Bool {
        guard let c = type.last else { return false }
        return "diuxXoc".contains(c) && c != "c"
    }
}

public enum FormatSpecifiers {
    // %[position$][flags][width][.precision][length]conversion, and %#@name@ for stringsdict variables.
    // The space and apostrophe flags are left out: in UI text "50% din" is prose, never "% d".
    static let pattern = #/%(?:(\d+)\$)?(#@[^@]+@|[-+0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA]))/#

    public static func parse(_ s: String) -> [FormatSpecifier] {
        var out: [FormatSpecifier] = []
        var index = s.startIndex
        while index < s.endIndex {
            guard let percent = s[index...].firstIndex(of: "%") else { break }
            let next = s.index(after: percent)
            if next < s.endIndex, s[next] == "%" {
                index = s.index(after: next)
                continue
            }
            if let m = s[percent...].prefixMatch(of: pattern) {
                let raw = String(m.0)
                let position = m.1.flatMap { Int($0) }
                let type: String
                if m.2.hasPrefix("#@") {
                    type = String(m.2)
                } else {
                    type = (m.3.map(String.init) ?? "") + (m.4.map(String.init) ?? "")
                }
                out.append(FormatSpecifier(raw: raw, position: position, type: type, range: m.range))
                index = m.range.upperBound
            } else {
                index = next
            }
        }
        return out
    }

    /// Placeholder types sorted, ignoring order and position. Two strings that format the same
    /// arguments have equal signatures.
    public static func signature(_ s: String) -> [String] {
        parse(s).map { normalize($0.type) }.sorted()
    }

    /// Treats `d`, `i`, `ld`, `lld`, `qd` as one integer kind, and the same for unsigned and floats,
    /// since translators and models swap them freely and Foundation formats them alike on 64-bit.
    static func normalize(_ type: String) -> String {
        guard let c = type.last else { return type }
        switch c {
        case "d", "i", "D": return "int"
        case "u", "U": return "uint"
        case "x", "X", "o", "O": return "hex\(c)"
        case "f", "F", "e", "E", "g", "G", "a", "A": return "float"
        default: return type
        }
    }

    /// The type that each argument is read as, by position from 1, or nil when two placeholders read
    /// the same argument as different types. A `%#@name@` variable counts as an integer.
    public static func arguments(_ s: String) -> [Int: String]? {
        var out: [Int: String] = [:]
        for (i, spec) in parse(s).enumerated() {
            // A `*` width or precision reads an extra argument; only an identical string is safe then.
            if spec.raw.contains("*") { return nil }
            let type = spec.type.hasPrefix("#@") ? "int" : normalize(spec.type)
            let position = spec.position ?? (i + 1)
            if let known = out[position], known != type { return nil }
            out[position] = type
        }
        return out
    }

    /// True when `translation` reads only arguments that `source` passes, each as the same type, so
    /// formatting it with the source's arguments can't read past them or misread one. A translation may
    /// leave arguments out and reorder them with `%2$@`.
    public static func compatible(_ translation: String, with source: String) -> Bool {
        if translation == source { return true }
        let wanted = parse(translation)
        if wanted.isEmpty { return true }
        if wanted.contains(where: { $0.raw.contains("*") }) { return signature(translation) == signature(source) }
        guard let reads = arguments(translation), let passed = arguments(source) else { return false }
        return reads.allSatisfy { position, type in
            guard let given = passed[position] else { return false }
            return given == type || (isWholeNumber(given) && isWholeNumber(type))
        }
    }

    private static func isWholeNumber(_ type: String) -> Bool { type == "int" || type == "uint" }

    /// The argument that the first integer placeholder reads, from 1: its `%2$` position when it has one,
    /// otherwise its place among the placeholders. A plural rule has to count that argument.
    public static func pluralArgument(_ s: String) -> Int? {
        let specifiers = parse(s)
        guard let index = specifiers.firstIndex(where: \.isInteger) else { return nil }
        return specifiers[index].position ?? (index + 1)
    }

    /// The first integer placeholder's type, used as the plural value type in a `.stringsdict`.
    public static func pluralValueType(_ s: String) -> String? {
        parse(s).first(where: \.isInteger).map { $0.type.hasPrefix("#@") ? "lld" : $0.type }
    }
}
