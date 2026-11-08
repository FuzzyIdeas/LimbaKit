# LimbaKit

LimbaKit is a Swift package that allows you to give your users the ability to translate your Mac
app on their own Mac. You won't have to include localizations in your app anymore.

Your users will be able to use the free [Limba app](https://lowtechguys.com/limba) with an AI model
of their choice to translate every text. The app updates in real time while they edit translations.

> *Other tools can be created to translate apps in the same way through LimbaKit, based on the
> protocol described in [PROTOCOL.md](PROTOCOL.md).*

LimbaKit needs macOS 13 or later.

## Adopt it with a coding agent

Give your coding agent this prompt, in the folder of your app:

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

The agent needs the free [Limba app](https://lowtechguys.com/limba) on the Mac for its checks, with
the `limba` command line tool installed from the Limba menu.

```swift
.package(url: "https://github.com/FuzzyIdeas/LimbaKit", from: "0.1.0")
```

In this repository:

- **LimbaKit**: the package an app adds.
- **LimbaCore**: the file formats and types of the protocol, for tools that read or write translations.
- [PROTOCOL.md](PROTOCOL.md): how an app and a translator find each other's files.
- [Skills/limba-adopt](Skills/limba-adopt/SKILL.md): the steps below, written for a coding agent to
  follow, with `Scripts/limba-adopt.py` for the Xcode project.
- **Examples/Demo**: a small SwiftUI app that adopts every step below.

## Making an app translatable

Each step works without the ones after it.

### 1. Ship the strings

Strings must go through a String Catalog. SwiftUI literals already do: `Text("Brightness")`,
`Button("Reset")`, `Toggle("Sub-zero dimming", isOn:)`. These do not, and need a change:

| Instead of | Write |
|---|---|
| `Text(verbatim: "Ready")` for prose | `Text("Ready")` |
| `Text(title)` where `title: String` | make `title` a `LocalizedStringKey` or `LocalizedStringResource` |
| a custom row view with `init(_ label: String)` | `init(_ label: LocalizedStringKey)` |
| `item.title = "Quit"` in AppKit | `item.title = String(localized: "Quit")` |
| `String(localized: "\(n) windows")` for a count built in code | `String(limba: "\(n) windows")`, so the count gets the plural rules of the translation |
| `enum Mode: String { case sync = "Sync" }` shown with `rawValue` | a `title: LocalizedStringResource` property |

Then:

1. Add `Localizable.xcstrings` to the target, if there is none. Xcode fills it at every build.
   `xcodebuild -exportLocalizations -project App.xcodeproj -localizationPath /tmp/x -exportLanguage en`
   does the same from the command line.
2. In the catalog editor, untick *Translate* for names that stay as they are.
3. Add a *Copy Files* build phase: Destination *Resources*, Subpath `Limba`, with the catalog in it.
   Xcode compiles catalogs listed under *Copy Bundle Resources*. This phase ships the file as it is.

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

Add the Limba button and the language menu to the General pane of Settings, in a row that looks
like the rows around it. Put the row at the bottom of the General settings, in a group of its own.
The button opens Limba on this app, or Limba's web page when Limba is not installed:

```swift
Section {
    LabeledContent("Language") {
        LimbaTranslateButton("Translate with Limba")
        LimbaLanguagePicker("Language").labelsHidden()
    }
}
```

At this point a translation applies when the app opens.

### 3. Live updates

Put `.limba()` on the root view of every window, `Settings` scene, popover and `MenuBarExtra`:

```swift
WindowGroup { ContentView().limba() }
Settings { SettingsView().limba() }
```

SwiftUI text under it updates in place when the language or a translation changes, and views keep
their state. The runtime updates AppKit windows, toolbars and menus. Text that the app builds
once and keeps, such as a string stored in a model, updates when its view renders again. To rebuild
it sooner, listen for the `.limbaDidChange` notification.

### 4. Context for the model

The model translates better when it knows what the app does. Add `Limba/app.json` to the same
*Copy Files* phase:

```json
{
  "protocol": 1,
  "description": "Lunar controls the brightness, contrast and volume of external monitors.",
  "context": "Users have one or more external monitors. Brightness is a percentage.",
  "glossary": [
    { "term": "Sub-zero", "note": "Dimming below 0% by darkening the picture in software", "translate": false }
  ]
}
```

Comments on catalog entries reach the model too.

### 5. Screens

Register each screen of the app, so a translator can open it, find where every string appears and
see the translation in place:

```swift
Limba.registerScreen("settings.general", title: "Settings > General") {
    openSettings(tab: .general)
}
```

## How it works

`Limba.start()` subclasses the class of the app's main bundle at runtime and overrides the
methods that Foundation, SwiftUI and AppKit use to look up localized strings. A lookup checks the
translation first and falls back to the text built into the app. The translation folder is watched.
On a change, the files are loaded again and the runtime sets a new `Locale` in the SwiftUI
environment. It differs only by a private keyword, so every `Text` resolves again while views
keep their state.

The private methods are only overridden when their type signature matches what the code expects. On
a system where one of them changed, that path falls back to the built-in text instead of crashing.

## Limits

- Checked on macOS 27. The public lookup paths work on older systems, but some private ones may not.
- Text that macOS provides stays in the system language: the items that every app menu has (About,
  Hide, Quit), system alerts, open and save panels.
- `String(localized:)` with a count uses the plural rules of the app's built-in language. SwiftUI
  `Text` under `.limba()` and `String(limba:)` use those of the translation.
- A sandboxed app keeps its translations inside its container. macOS asks the user once before a
  translator may write there.
