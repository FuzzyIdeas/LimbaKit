import AppKit
import SwiftUI
import LimbaCore

/// The button that sits next to the language menu in an app's settings. It opens Limba on this app,
/// or Limba's web page when Limba is not installed.
///
/// LimbaKit has the title "Translate with Limba" in many languages. By default the button shows it
/// in the first language of the Mac, so that a person who can't read the app's language can still
/// find the button:
///
///     LimbaTranslateButton()                       // the Mac's language
///     LimbaTranslateButton(titleLanguage: .app)    // the language the app shows
///     LimbaTranslateButton(titleLanguage: .english)
///
/// An app that wants its own wording passes a title, which goes into the app's String Catalog:
///
///     LimbaTranslateButton("Translate with Limba")
public struct LimbaTranslateButton: View {
    /// The language of the button's title.
    public enum TitleLanguage: Sendable {
        /// The first language of the Mac that LimbaKit has a title for.
        case system
        /// The language the app shows: its Limba translation, or the language it is written in.
        case app
        /// Always English.
        case english
    }

    private let title: LocalizedStringKey?
    private let titleLanguage: TitleLanguage
    @ObservedObject private var runtime = LimbaRuntime.shared

    public init(titleLanguage: TitleLanguage = .system) {
        title = nil
        self.titleLanguage = titleLanguage
    }

    public init(_ title: LocalizedStringKey) {
        self.title = title
        titleLanguage = .app
    }

    public var body: some View {
        Button(action: Limba.openTranslator) {
            Label {
                if let title {
                    Text(title)
                } else {
                    Text(verbatim: TranslateButtonTitles.title(for: languages))
                }
            } icon: {
                Image(nsImage: Limba.translatorIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            }
            .labelStyle(.titleAndIcon)
        }
    }

    /// The languages to try, best first.
    private var languages: [String] {
        switch titleLanguage {
        case .system:
            return Locale.preferredLanguages
        case .app:
            return [runtime.language ?? runtime.bundle.developmentLocalization ?? "en"]
        case .english:
            return ["en"]
        }
    }
}

public extension Limba {
    /// The bundle identifier of the Limba app.
    static let translatorBundleIdentifier = "com.lowtechguys.Limba"
    /// Where Limba can be downloaded.
    static let translatorPage = URL(string: "https://lowtechguys.com/limba")!

    /// True when Limba is installed on this Mac.
    @MainActor static var translatorInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: translatorBundleIdentifier) != nil
    }

    /// Opens Limba with this app selected, in the language the app shows now, or in the first language
    /// of the Mac that the app is not written in. Opens Limba's web page when Limba is not installed.
    ///
    /// The link is `limba://translate?app=<bundle identifier>&language=<code>`; PROTOCOL.md describes it.
    @MainActor static func openTranslator() {
        let workspace = NSWorkspace.shared
        guard let translator = workspace.urlForApplication(withBundleIdentifier: translatorBundleIdentifier) else {
            workspace.open(translatorPage)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([translateLink], withApplicationAt: translator, configuration: configuration)
    }

    /// `limba://translate?app=<bundle identifier>&language=<code>`
    @MainActor static var translateLink: URL {
        let runtime = LimbaRuntime.shared
        var components = URLComponents()
        components.scheme = "limba"
        components.host = "translate"
        components.queryItems = [URLQueryItem(name: "app", value: runtime.bundleIdentifier)]
        if let language = runtime.language ?? preferredTranslationLanguage {
            components.queryItems?.append(URLQueryItem(name: "language", value: language))
        }
        return components.url!
    }

    /// The first language in the Mac's list of preferred languages that the app is not written in.
    @MainActor static var preferredTranslationLanguage: String? {
        let builtIn = Locale(identifier: LimbaRuntime.shared.bundle.developmentLocalization ?? "en").language.languageCode
        return Locale.preferredLanguages.first { Locale(identifier: $0).language.languageCode != builtIn }
    }

    /// Limba's icon: the installed app's, or a copy kept in this package when Limba is not installed.
    /// Looked up once: the button renders often, and each LaunchServices query can wait on lsd.
    @MainActor static var translatorIcon: NSImage {
        if let cachedIcon { return cachedIcon }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: translatorBundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = bundledIcon ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil) ?? NSImage()
        }
        cachedIcon = icon
        return icon
    }

    @MainActor private static var cachedIcon: NSImage?

    /// Read from the package's resource bundle without `Bundle.module`, which stops the process when
    /// the bundle is missing.
    private static let bundledIcon: NSImage? = {
        let name = "LimbaKit_LimbaKit.bundle"
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle(for: BundleMarker.self).resourceURL]
        for place in places.compactMap({ $0 }) {
            if let bundle = Bundle(url: place.appendingPathComponent(name)), let image = bundle.image(forResource: "Limba") {
                return image
            }
        }
        return nil
    }()

    private final class BundleMarker {}
}
