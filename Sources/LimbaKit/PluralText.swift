import Foundation

public extension String {
    /// A string from the catalog, resolved with the plural rules of the language on screen.
    ///
    /// `String(localized:)` formats with `Locale.current`, whose language is the app's built-in one, so a
    /// Romanian translation of "\(n) files" gets the English rules and shows «3 de fișiere» for «3 fișiere».
    /// SwiftUI text under `.limba()` already has the right locale; use this for every counted string built in
    /// code: AppKit titles, menu items, alerts, notifications, and strings handed to `Text(verbatim:)`.
    ///
    ///     menuItem.title = String(limba: "\(count) windows")
    init(limba resource: LocalizedStringResource) {
        var resource = resource
        resource.locale = LimbaRuntime.shared.locale
        self.init(localized: resource)
    }

    /// `String(format:)` for a format string from `NSLocalizedString`, with the plural rules of the language
    /// on screen.
    init(limbaFormat format: String, _ arguments: CVarArg...) {
        self.init(format: format, locale: LimbaRuntime.shared.locale, arguments: arguments)
    }
}
