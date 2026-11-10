# LimbaKit

LimbaKit is a Swift package that allows you to give your users the ability to translate your Mac
app on their own Mac. You won't have to include localizations in your app anymore.

Your users will be able to use the free [Limba app](https://lowtechguys.com/limba) with an AI model
of their choice to translate every text. The app updates in real time while they edit translations.

> *Other tools can be created to translate apps in the same way through LimbaKit, based on the
> protocol described in [PROTOCOL.md](PROTOCOL.md).*

*LimbaKit needs macOS 13 or later.*

## Adopt it with a coding agent

Implement LimbaKit by giving your coding agent this prompt:

```text
Make this Mac app translatable with Limba.

1. Clone https://github.com/FuzzyIdeas/LimbaKit to /tmp/LimbaKit and copy its Skills/limba-adopt
   folder into your skills folder (.claude/skills/ for Claude Code). It doesn't need a commit.
2. On a new branch, follow that skill from section 0 to section 7, in order. Skip nothing: if the
   app has no String Catalog, create one and route every string a person reads through it.
3. Never change the app's English wording.
4. Build after every step that changes code, and fix every error before going on.
5. End with the report from section 7.
```

The agent uses the free [Limba app](https://lowtechguys.com/limba) and its `limba` command line
tool for its checks, and installs both when they are missing. The one thing it can't do for you is
give your terminal app Accessibility access, which `limba audit` needs.

## Implement it yourself

```swift
.package(url: "https://github.com/FuzzyIdeas/LimbaKit", from: "0.2.3")
```

In this repository:

- **LimbaKit**: the package an app adds.
- **LimbaCore**: the file formats and types of the protocol, for tools that read or write translations.
- [PROTOCOL.md](PROTOCOL.md): how an app and a translator find each other's files.
- [Skills/limba-adopt](Skills/limba-adopt/SKILL.md): the steps below, written for a coding agent to
  follow, with `Scripts/limba-adopt.py` for the Xcode project.
- **Examples/Demo**: a small SwiftUI app that adopts every step below.

## Making an app translatable

### 1. Extract your strings into the standard *Xcode Strings Catalog*

Strings must go through a String Catalog to become dynamic. SwiftUI literals already do: `Text("Brightness")`,
`Button("Reset")`, `Toggle("Sub-zero dimming", isOn:)`.

The ones below though need manual extraction:

| Static | Dynamic |
|---|---|
| `Text(verbatim: "Ready")` for prose | `Text("Ready")` |
| `Text(title)` where `title: String` | make `title` a `LocalizedStringKey` or `LocalizedStringResource` |
| a custom row view with `init(_ label: String)` | `init(_ label: LocalizedStringKey)` |
| `item.title = "Quit"` in AppKit | `item.title = String(localized: "Quit")` |
| `String(localized: "\(n) windows")` for variable interpolation | `String(limba: "\(n) windows")`, so the variable gets the plural rules of the translation |
| `enum Mode: String { case sync = "Sync" }` shown with `rawValue` | a `title: LocalizedStringResource` property |

Then:

1. Add `Localizable.xcstrings` to the target. Xcode fills it at every build
   - you can also do it manually with `xcodebuild -exportLocalizations -project App.xcodeproj -localizationPath /tmp/x -exportLanguage en`
2. In the catalog editor, untick *Translate* for strings that you want to keep static *(e.g. company names, app names, trademarked features)*
3. Add a *Copy Files* build phase for the catalog
   - Destination *Resources*
   - Subpath `Limba`
   - important because otherwise Xcode compiles catalogs listed under *Copy Bundle Resources*. A *Copy Files* phase ships the file uncompiled which we need

### 2. Load translations

Add the package and the product `LimbaKit`, then call `Limba.start()` before any UI exists:

```swift
import LimbaKit

@main
struct MyApp: App {
    init() { Limba.start() }
    ...
}
```

In an AppKit app, call it in `applicationWillFinishLaunching(_:)`.

Add the Limba button and the language menu in your app Settings.

The button opens Limba, focused on this app, or Limba's web page when it is not installed:

```swift
Section {
    LabeledContent("Language") {
        LimbaTranslateButton()
        LimbaLanguagePicker("Language").labelsHidden()
    }
}
```

*LimbaKit's button title "Translate with Limba" is already localized in more than 60 languages.*

### 3. Live updates (optional)

You can give the app the ability to hot reload translations on the fly as they are generated or edited.

Put `.limba()` on the root view of every window, `Settings` scene, popover and `MenuBarExtra`:

```swift
WindowGroup { ContentView().limba() }
Settings { SettingsView().limba() }
```

### 4. Context for the model (optional)

The model translates better when it knows what the app does. Add `Limba/app.json` to the same
*Copy Files* phase from above:

```json
{
  "protocol": 1,
  "description": "Lunar controls the brightness, contrast and volume of external monitors.",
  "context": "Users have one or more external monitors. Brightness is a percentage. Lid refers to a laptop lid.",
  "glossary": [
    { "term": "Sub-zero", "note": "Dimming below 0% by darkening the picture in software", "translate": false }
  ]
}
```

### 5. Deep links (optional)

Add a deep link for specific views of the app, so a translator can open them from Limba and review how the translated strings appear in the app.

```swift
Limba.addDeepLink("settings.general", title: "Settings > General") {
    openSettings(tab: .general)
}
```

## How it works

```
 Limba app                        Translation folder                        Your app with LimbaKit
                                  Application Support/Limba/<bundle id>/

 reads the String Catalogs  ◀─────────────────────────────────────────────  Contents/Resources/Limba/
 translates them with AI

 writes the translations    ───▶  ro.lproj/Localizable.strings    ───▶     Limba.start() looks up every
                                  ro.lproj/Localizable.stringsdict          string here first, then in
                                                                            the text built into the app

 sends commands             ───────── distributed notification  ───▶     switches language, shows
 (select, probe, show)                                                      markers, opens a deep link

 reads the app's state      ◀───  state.json                      ◀───    writes it after every change
```

1. **Lookups.** `Limba.start()` subclasses the class of the app's main bundle at runtime. The
   subclass overrides the methods that Foundation, SwiftUI and AppKit use to look up localized
   strings. A lookup checks the translation first and falls back to the text built into the app.
2. **Live updates.** LimbaKit watches the translation folder. When a file changes, LimbaKit loads
   the files again and sets a new `Locale` in the SwiftUI environment. The new `Locale` differs only
   by a private keyword, so every `Text` resolves again and views keep their state. AppKit windows
   and menus get their text set again.
3. **Commands.** Limba sends commands to the running app as distributed notifications, and the app
   answers by writing `state.json`. [PROTOCOL.md](PROTOCOL.md) lists the commands and the files.

*LimbaKit overrides a private method only when its type signature matches what LimbaKit expects. On
a system where one of them changed, that path falls back to the built-in text instead of crashing.*

## Limits

- Text that macOS provides stays in the system language: the items that every app menu has (About,
  Hide, Quit), system alerts, open and save panels.
- A sandboxed app keeps its translations inside a restricted filesystem container. macOS may ask for permission when Limba tries to write the translation files there.
