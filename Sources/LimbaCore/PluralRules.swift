import Foundation

/// CLDR cardinal plural categories that a translation must provide for whole numbers.
/// Foundation picks the category at runtime; a missing one falls back to `other`.
public enum PluralRules {
    public static let allCategories = ["zero", "one", "two", "few", "many", "other"]

    static let table: [String: [String]] = {
        var t: [String: [String]] = [:]
        for l in ["ja", "zh", "ko", "vi", "th", "id", "ms", "my", "km", "lo", "yue", "jv", "su", "bo", "dz", "to", "wo", "yo", "ig"] {
            t[l] = ["other"]
        }
        for l in ["ro", "mo", "hr", "sr", "bs", "cs", "sk", "lt"] { t[l] = ["one", "few", "other"] }
        for l in ["ru", "uk", "be", "pl"] { t[l] = ["one", "few", "many", "other"] }
        t["sl"] = ["one", "two", "few", "other"]
        t["lv"] = ["zero", "one", "other"]
        t["ar"] = ["zero", "one", "two", "few", "many", "other"]
        t["cy"] = ["zero", "one", "two", "few", "many", "other"]
        t["ga"] = ["one", "two", "few", "many", "other"]
        t["mt"] = ["one", "two", "few", "many", "other"]
        t["he"] = ["one", "two", "other"]
        t["fr"] = ["one", "many", "other"]
        t["es"] = ["one", "many", "other"]
        t["it"] = ["one", "many", "other"]
        t["pt"] = ["one", "many", "other"]
        t["ca"] = ["one", "many", "other"]
        return t
    }()

    /// Categories for a language identifier such as `ro`, `pt-BR` or `zh-Hans`.
    public static func categories(for language: String) -> [String] {
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? language
        return table[base] ?? ["one", "other"]
    }
}
