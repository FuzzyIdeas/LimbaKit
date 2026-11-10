import Foundation

/// Reads and writes `.strings` and `.stringsdict` files, the formats NSBundle loads.
public enum StringsFiles {
    // MARK: .strings

    public static func readStrings(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return plist
    }

    /// UTF-8 text, sorted by key, one `"key" = "value";` per line.
    public static func stringsText(_ pairs: [String: String]) -> String {
        var out = ""
        for key in pairs.keys.sorted() {
            out += "\"\(escape(key))\" = \"\(escape(pairs[key]!))\";\n"
        }
        return out
    }

    public static func writeStrings(_ pairs: [String: String], to url: URL) throws {
        try writeAtomically(Data(stringsText(pairs).utf8), to: url)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\U%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: .stringsdict

    /// A plural string: the forms by CLDR category, each a complete format string.
    public struct PluralEntry: Equatable, Sendable {
        public var forms: [String: String]
        /// The format of the counted value, such as `lld` or `d`.
        public var valueType: String
        /// Which argument the plural counts, from 1. In "Delete %@ with %lld rules?" it is the second.
        public var argument: Int

        public init(forms: [String: String], valueType: String, argument: Int = 1) {
            self.forms = forms
            self.valueType = valueType
            self.argument = argument
        }
    }

    public static func stringsdictObject(_ entries: [String: PluralEntry]) -> [String: Any] {
        var root: [String: Any] = [:]
        for (key, entry) in entries {
            var variable: [String: Any] = [
                "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                "NSStringFormatValueTypeKey": entry.valueType,
            ]
            for (category, text) in entry.forms { variable[category] = text }
            root[key] = [
                // Without a position the rule counts the first argument, which may be a name, not the number.
                "NSStringLocalizedFormatKey": entry.argument > 1 ? "%\(entry.argument)$#@count@" : "%#@count@",
                "count": variable,
            ]
        }
        return root
    }

    public static func writeStringsdict(_ entries: [String: PluralEntry], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: stringsdictObject(entries), format: .xml, options: 0)
        try writeAtomically(data, to: url)
    }

    /// Plural entries with a single plural variable, which is the shape `writeStringsdict` produces.
    public static func readStringsdict(_ url: URL) -> [String: PluralEntry] {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        var out: [String: PluralEntry] = [:]
        for (key, value) in root {
            guard let dict = value as? [String: Any], let format = dict["NSStringLocalizedFormatKey"] as? String else { continue }
            let match = format.firstMatch(of: #/%(?:(\d+)\$)?#@([^@]+)@/#)
            let variableName = match.map { String($0.2) } ?? "count"
            let argument = match?.1.flatMap { Int($0) } ?? 1
            guard let variable = dict[variableName] as? [String: Any] else { continue }
            var forms: [String: String] = [:]
            for category in PluralRules.allCategories {
                if let text = variable[category] as? String { forms[category] = text }
            }
            out[key] = PluralEntry(forms: forms, valueType: variable["NSStringFormatValueTypeKey"] as? String ?? "lld", argument: argument)
        }
        return out
    }

    // MARK: Atomic writes

    /// Writes next to the destination, then renames, so a reader never sees half a file.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        // rename(2) replaces the destination atomically on the same volume. replaceItemAt does
        // much more (it resolves both files by ID through fsgetpath) and was seen blocking for 30 s.
        guard rename(tmp.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }
}
