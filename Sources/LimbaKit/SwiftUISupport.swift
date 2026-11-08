import SwiftUI
import LimbaCore

public extension View {
    /// Updates the text under this view when the language or a translation changes, without
    /// rebuilding it. Add it to the root view of every window, `Settings` scene, popover and
    /// `MenuBarExtra`.
    func limba() -> some View {
        modifier(LimbaModifier())
    }
}

struct LimbaModifier: ViewModifier {
    @ObservedObject private var runtime = LimbaRuntime.shared

    func body(content: Content) -> some View {
        content
            .environment(\.locale, runtime.locale)
            .id(runtime.rebuildToken)
    }
}

/// The language menu for an app's settings: the built-in language and every translation on this Mac,
/// each in its own name. Put it in the app's own settings row, with `.labelsHidden()`, next to a
/// `LimbaTranslateButton`.
public struct LimbaLanguagePicker: View {
    @ObservedObject private var runtime = LimbaRuntime.shared
    private let label: LocalizedStringKey

    /// `label` is read by VoiceOver, and shown when the picker is not given `.labelsHidden()`.
    public init(_ label: LocalizedStringKey = "Language") {
        self.label = label
    }

    public var body: some View {
        Picker(label, selection: selection) {
            Text(verbatim: runtime.builtInLanguageName).tag("")
            ForEach(runtime.languages, id: \.self) { language in
                Text(verbatim: Languages.nativeName(language)).tag(language)
            }
        }
        .fixedSize()
    }

    private var selection: Binding<String> {
        Binding(
            get: { runtime.language ?? "" },
            set: { value in
                Task { @MainActor in Limba.select(value.isEmpty ? nil : value) }
            }
        )
    }
}
