import Foundation

/// Cleans translation files before an app loads them. CFBundle trusts the shape of a strings table: a
/// value that is a dictionary or a number where it expects text is sent string methods, and the app
/// crashes inside its own string lookup. Files come from a translator tool, or from a person editing
/// them by hand, so only entries with the right shape are kept.
public enum SafeTables {
    /// A `.strings` file as a dictionary of text, or nil when it can't be read at all.
    ///
    /// A value whose placeholders don't fit its source text is left out too: `String(format:)` with
    /// "%@ fișiere" for "%lld files" reads the count as an object pointer and crashes. `sources` maps a
    /// key to its source text, and a key that it doesn't list is its own source text.
    public static func strings(from data: Data, sources: [String: String] = [:]) -> [String: String]? {
        guard let object = plist(data) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, value) in object {
            guard let text = value as? String else { continue }
            guard FormatSpecifiers.compatible(text, with: sources[key] ?? key) else { continue }
            out[key] = text
        }
        return out
    }

    /// A `.stringsdict` file with only the plural rules that Foundation can read, or nil when it can't
    /// be read at all.
    public static func stringsdict(from data: Data, sources: [String: String] = [:]) -> [String: Any]? {
        guard let object = plist(data) as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for (key, value) in object {
            if let rule = rule(value, source: sources[key] ?? key) { out[key] = rule }
        }
        return out
    }

    /// The bytes of the clean file, as a binary property list that CFBundle reads like a text one.
    /// Nil for a file that is not a strings table.
    public static func cleaned(_ data: Data, name: String, sources: [String: String] = [:]) -> Data? {
        let object: Any?
        if name.hasSuffix(".strings") {
            object = strings(from: data, sources: sources)
        } else if name.hasSuffix(".stringsdict") {
            object = stringsdict(from: data, sources: sources)
        } else {
            return nil
        }
        guard let object else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    private static func plist(_ data: Data) -> Any? {
        guard !data.isEmpty else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    /// One plural entry: a format key that is text, and variables whose fields are all text. The format
    /// and every form have to read the source's arguments as the source passes them.
    private static func rule(_ value: Any, source: String) -> [String: Any]? {
        guard let entry = value as? [String: Any], let format = entry["NSStringLocalizedFormatKey"] as? String else { return nil }
        guard FormatSpecifiers.compatible(format, with: source) else { return nil }
        var out: [String: Any] = ["NSStringLocalizedFormatKey": format]
        for (name, variable) in entry where name != "NSStringLocalizedFormatKey" {
            guard let fields = variable as? [String: Any] else { continue }
            var clean: [String: String] = [:]
            for (field, text) in fields {
                if let text = text as? String { clean[field] = text }
            }
            guard clean["NSStringFormatSpecTypeKey"] != nil, clean["other"] != nil else { continue }
            if !formsFit(clean, variable: name, format: format, source: source) { continue }
            out[name] = clean
        }
        // Every variable named in the format must still be there, or Foundation fails on the entry.
        let named = format.ranges(of: #"%(?:\d+\$)?#@([^@]+)@"#)
        for name in named where out[name] == nil { return nil }
        return out
    }
}

private extension SafeTables {
    /// A plural form reads the counted number through its plain placeholders, and other arguments
    /// through `%2$@` placeholders. Each has to match what the source passes in that place.
    static func formsFit(_ fields: [String: String], variable: String, format: String, source: String) -> Bool {
        let valueType = fields["NSStringFormatValueTypeKey"].map { "%" + $0 } ?? "%lld"
        // The argument that the variable counts, from where `%#@name@` sits in the format.
        let specs = FormatSpecifiers.parse(format)
        guard let index = specs.firstIndex(where: { $0.type == "#@\(variable)@" }) else { return true }
        let counted = specs[index].position ?? (index + 1)
        let passed = FormatSpecifiers.arguments(source) ?? [:]
        for (field, text) in fields where field != "NSStringFormatSpecTypeKey" && field != "NSStringFormatValueTypeKey" {
            for spec in FormatSpecifiers.parse(text) {
                if let position = spec.position, position != counted {
                    guard let given = passed[position], FormatSpecifiers.compatible("%\(position)$" + spec.type, with: source), !given.isEmpty else { return false }
                } else if !FormatSpecifiers.compatible(spec.raw.replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression), with: valueType) {
                    return false
                }
            }
        }
        return true
    }
}

private extension String {
    /// The first capture of each match.
    func ranges(of pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { m in
            Range(m.range(at: 1), in: self).map { String(self[$0]) }
        }
    }
}
