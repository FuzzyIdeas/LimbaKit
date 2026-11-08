import Foundation

public enum Languages {
    /// The language's own name with its first letter capitalized: `Română`, `Deutsch`, `日本語`.
    public static func nativeName(_ identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        let name = locale.localizedString(forIdentifier: identifier) ?? identifier
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The language's name in English: `Romanian`.
    public static func englishName(_ identifier: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Languages a person is likely to pick, by identifier. Any other valid identifier works too.
    public static let common: [String] = [
        "ar", "bg", "ca", "cs", "da", "de", "el", "es", "es-419", "et", "fa", "fi", "fr", "fr-CA", "he", "hi", "hr",
        "hu", "id", "it", "ja", "ko", "lt", "lv", "ms", "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk",
        "sl", "sr", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]
}
