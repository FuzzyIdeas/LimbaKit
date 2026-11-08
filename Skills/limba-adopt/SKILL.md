---
name: limba-adopt
description: Make a macOS app translatable by the people who use it, with Limba. Routes every user-facing string through the String Catalog, adds LimbaKit, ships the catalog in the bundle, and proves with the limba CLI that no text on any screen skips the catalog. Use when asked to "add Limba", "make this app translatable", "prepare the app for Limba translations", or to check an app's Limba support.
---

# Make a Mac app translatable with Limba

Limba lets people translate an app into their own language with any AI model, while the app runs.
The developer's part is small but has to be complete: every string a person reads must come from the
app's String Catalog, or no translator can reach it.

**Done means all four:**

1. Every string a person reads comes from the String Catalog.
2. LimbaKit loads the chosen translation at launch and applies edits live.
3. `limba audit <app>` lists no app text on any registered screen.
4. A translation into one language reads right on every screen, with nothing cut off.

Read `PROTOCOL.md` in the Limba repository once before starting. It is short.

## 0. Tools

- Xcode 16 or later, and `python3` for `Scripts/limba-adopt.py`.
- The `limba` command line tool: in the Limba app, choose Limba > Install Command Line Tool…, which links it
  into `~/.local/bin`.
- An OpenAI-compatible endpoint for the smoke test. A small cheap model is the right test: if the
  translation reads well with it, it reads well with anything.
- A Mac to run the app on, where the shell that runs `limba audit` has Accessibility access.

Work on a branch. When you use a git worktree, copy the generated, git-ignored source files from the
main checkout into it first (`git status --ignored` lists them): a build that includes a generated
header fails without it.

## 1. Survey the app

Find, before changing anything:

- **The app target.** Leave CLI tools, helpers and extensions alone; they print text for scripts.
- **The deployment target.** LimbaKit needs macOS 13.
- **The entry point.** The `App` struct, `main.swift`, or the app delegate.
- **Every SwiftUI root.** Each `WindowGroup`, `Window`, `Settings` and `MenuBarExtra`, plus every
  `NSHostingView` and `NSHostingController` that AppKit code creates.
- **The Settings window,** its General pane, and how a pane gets selected (an `@AppStorage` key, a
  tab selection). Each pane becomes a screen that translators can open.
- **Candidate sites.** These patterns find almost all text that skips the catalog. They are plain
  regular expressions for `rg -n`, without lookarounds, so they work without PCRE2:

```
Text\([a-zA-Z_(]                      Text(someString), Text(cond ? a : "B"); skip Text(verbatim:
\\\([^)]*\? *"                         a ternary of literals inside an interpolation
(let|var) (title|label|subtitle|text|caption|message|name|displayName): String
init\(_ \w+: String                   custom views that take their copy as String
case \.\w+: "[A-Z]                    enum display names
\.(title|stringValue|toolTip|placeholderString|messageText|informativeText) = "
NSMenuItem\(title: "|addItem\(withTitle: "|addButton\(withTitle: "
content\.(title|body|subtitle) =      user notifications
var errorDescription: String?         error messages shown to people
```

## 2. Add Limba

1. Run the adoption script from the folder of the `.xcodeproj`:

   ```sh
   python3 <Limba>/Scripts/limba-adopt.py App.xcodeproj --target App \
     --package https://github.com/<org>/Limba \
     --catalog App/Localizable.xcstrings --manifest Limba/app.json
   ```

   It links LimbaKit and adds a Run Script phase, "Ship strings for Limba", that copies the catalog
   and the manifest to `Contents/Resources/Limba/` unprocessed. Xcode compiles catalogs listed under
   Copy Bundle Resources, which is why a plain resource does not work. `--package` also takes a local
   path relative to the project folder. It only adds lines to `project.pbxproj`, so the diff stays
   small next to other work in progress, and running it twice changes nothing.

2. If the app has no catalog, create `App/Localizable.xcstrings` containing
   `{"sourceLanguage":"en","strings":{},"version":"1.0"}` inside the app's source folder. With
   synchronized folders, Xcode adds it to the target; otherwise add it to Copy Bundle Resources.

3. Write `Limba/app.json` outside the synchronized source folders, so Xcode does not bundle it twice:

   ```json
   {
     "protocol": 1,
     "description": "What the app does, in one or two sentences.",
     "context": "Who uses it, the domain, what the words on screen refer to.",
     "glossary": [
       { "term": "AppName", "translate": false },
       { "term": "Feature name", "note": "what it means, so a model picks the right word" }
     ]
   }
   ```

   The glossary is where translation quality is won. List product and feature names that stay as
   they are (`"translate": false`), and every term whose plain-English meaning is not the app's
   meaning. Invented feature names are names: give them `"translate": false` and a note, or a small
   model turns a name like "Sub-zero" into a plain word for darkness:
   `{"term": "Sub-zero", "translate": false, "note": "dimming below 0% brightness"}`.
   Abbreviations in capitals (OSD, DDC) stay as written without an entry. Write one entry per term:
   an entry for "Spaces, Mission Control" matches no string.

4. Start Limba before any UI exists, on the main actor:

   ```swift
   import LimbaKit

   struct MyApp: App {
       init() { Limba.start() }
   ```

   In an AppKit app, call it in `main.swift` before `NSApplicationMain`, or in
   `applicationWillFinishLaunching(_:)`. The `Limba` functions can be called from any context,
   including code that strict concurrency checking treats as nonisolated.

5. Add `.limba()` to every SwiftUI root, and to the root view of every hosting view that stays on
   screen. Views that are rebuilt each time they appear (a HUD, an overlay) do not need it.

6. Put `LimbaLanguagePicker("Language").labelsHidden()` and `LimbaTranslateButton("Translate with Limba")`
   in one row of the General pane of Settings, built the way the app builds the rows around it.

7. Register a screen for each Settings pane and main window:

   ```swift
   for pane in SettingsPane.allCases {
       Limba.registerScreen("settings.\(pane.rawValue)", title: "Settings > \(pane.title.key)") {
           selectedPane = pane          // whatever selects the pane
           NSApp.activate(ignoringOtherApps: true)
           openSettings()               // SwiftUI: the openSettings environment action
       }
   }
   ```

   Since macOS 14, SwiftUI ignores `showSettingsWindow:`; keep the `openSettings` environment action
   somewhere the closure can call it.

## 3. Route every string through the catalog

Change types and call sites. **Never change the wording**: the developer's words are the source text.

| Found | Change it to |
|---|---|
| `Text(title)` where `title: String` holds copy | make the property `LocalizedStringKey` or `LocalizedStringResource` |
| `Text("License: \(on ? "Active" : "Off")")` | `on ? Text("License: Active") : Text("License: Off")`. Literals inside an interpolation are plain `String`s, so they are never extracted. `Text(on ? "On" : "Off")` is fine as it is: both literals become keys |
| a ternary that mixes a literal with a `String`, or a ternary inside `String(localized:)` | one `Text` or `String(localized:)` per branch. Neither form is extracted |
| a custom view with `init(_ text: String)` used for copy | take `LocalizedStringKey`. If the view needs a `String` too (an id, a seed), take `LocalizedStringResource` and use `.key` |
| an enum's `var displayName: String { switch … "Top Left" }` | return `LocalizedStringResource`. `Text(x.displayName)` works as is; where a `String` is needed, write `String(localized: x.displayName)` |
| `status = "Checking…"` for text shown later | `status = String(localized: "Checking…")` |
| AppKit titles, alerts, menu items, tooltips, window titles | `String(localized: "…")` |
| notification titles and bodies | `String(localized: "…")` where they are built |
| `errorDescription` returning literals | `String(localized: "…")` in every case |
| an `Error` interpolated into `String(localized:)` | `String(describing: error)` inside it, which shows the same text without the compiler warning |
| plurals built by hand: `"\(n) day\(n == 1 ? "" : "s")"` | `String(limba: "\(n) days remaining")`, then add English plural forms to the catalog (step 4) |
| any counted string built in code: `String(localized: "\(n) windows")`, `String(format: NSLocalizedString(…), n)` | `String(limba: "\(n) windows")` or `String(limbaFormat: format, n)`. `String(localized:)` takes plural rules from the app's built-in language, so a translation never gets its forms for 2 to 19 or 0. SwiftUI `Text` under `.limba()` is already right |
| a package view that takes a title (`LaunchAtLogin.Toggle("Launch at login")`) | its label closure: `LaunchAtLogin.Toggle { Text("Launch at login") }`. A package resolves its title in its own bundle, where translations cannot reach it |
| a placeholder whose meaning is not obvious: `"Print all %@ layers…"` | add `comment: "%@ is the app name"`. The comment reaches the model with the string |
| text that the screen shows and the CLI, MCP or an API also returns | two properties: the English one for the API (`displayName`), and `localizedDisplayName` (`String(localized:)`) for the screen. Scripts and agents parse the English |
| names, numbers, paths, versions, user input, key symbols | leave as `Text(verbatim:)`. They are data |
| logs, CLI and MCP output, defaults keys, identifiers | never localize |

**Trap:** after changing a property from `String` to `LocalizedStringResource`, search for every
string interpolation of it: `"\(x.displayName) - P"` still compiles, and shows
`LocalizedStringResource(key: …)` on screen. Wrap it: `"\(String(localized: x.displayName)) - P"`.
The audit in step 5 catches the ones you miss. To list every such site at build time, add this
overload for one build and read the warnings, then delete it, since it prints nothing:

```swift
extension String.StringInterpolation {
    @available(*, deprecated, message: "wrap in String(localized:)")
    mutating func appendInterpolation(_ r: LocalizedStringResource) {}
}
```

An `unavailable` overload does not work for this: the compiler skips it and picks another.

## 4. Fill and tidy the catalog

```sh
xcodebuild -exportLocalizations -project App.xcodeproj -scheme App -localizationPath /tmp/limba-export -exportLanguage en
```

That syncs the catalog with the code from the command line, the same as building in Xcode. A plain
`xcodebuild build` does not update the catalog, but it writes the extracted keys to `.stringsdata`
files in DerivedData, which show whether a call site is extracted. With `-derivedDataPath`, the export also needs
`-scheme`. A project that builds more than one architecture may need
`ONLY_ACTIVE_ARCH=YES ARCHS=arm64` for the export to finish.

When the export fails on another target (a CLI target without an Info.plist, for example),
`xcrun xcstringstool sync` updates the catalog from the `.stringsdata` files of a build instead.

The export builds without `DEBUG`, so it drops keys that only `#if DEBUG` code uses. Debug-only text
doesn't need a translation, but look at `git diff` on the catalog before committing, and keep those
removals out of the commit when the developer wants the keys.

- Add English plural forms wherever the code used to pluralize by hand. A plural applies to a string
  with one number in it: split a sentence that counts two things into two strings. In the catalog JSON:
  `"localizations": {"en": {"variations": {"plural": {"one": {"stringUnit": {"state": "translated", "value": "%lld day remaining"}}, "other": {…}}}}}`.
- Set `"shouldTranslate": false` on the app's name and names like key labels ("fn").
- Translators skip keys without letters ("-", "%@").

## 5. Verify on a Mac

Unlock the screen first. A locked screen makes the Accessibility API return no windows, and every
check below quietly passes or fails for the wrong reason.

1. Build Debug, quit any installed copy of the app, launch the build.
2. `limba apps`: the app is listed with its string count.
3. `limba audit <app>`: opens every registered screen with markers on and lists each text that skips
   the catalog. Fix and repeat until only text that macOS itself draws remains ("Sidebar", standard
   window buttons). It also lists keys the app looked up at runtime that the shipped catalog lacks.
4. The audit reads the main menu bar, but it cannot open a status item's menu, alerts, notifications,
   HUDs or context menus. Check those in code against the table in step 3, and look at them in the
   smoke test, since their strings are translated without knowing where they appear.
5. Quit and relaunch the app after an audit. Text that the app kept while markers were on (a window
   title, a cached label) keeps the invisible markers until the app restarts.
6. `limba pseudo <app>` then `limba use <app> en-XA`: every string becomes accented, 30% longer and
   wrapped in ⟦ ⟧. On each screen (`limba show <app> <screen>`), text without brackets is hardcoded,
   and a cut-off ⟦… shows a layout that a longer language will break.
7. Smoke test with a cheap model, then `limba use <app> ro` (or any language you can read) and look at
   every screen: no English left except names, plurals right, nothing cut off, menus translated.

   ```sh
   limba capture <app>          # where each string appears, for better translations
   limba translate <app> ro --endpoint … --model …
   ```

8. `limba use <app> none` to go back to the built-in language.

## 6. Caveats

- Text that macOS provides stays in the system language: About, Hide and Quit in the app menu,
  system alerts, open and save panels, `NSSearchField` placeholders from AppKit.
- App Intents text (Shortcuts actions and their parameters) is read by the system from the app's
  compiled strings, so a Limba translation cannot reach it. It stays in the catalog for the
  localizations that ship inside the app.
- `String(localized:)` with a count uses the plural rules of the user's region; SwiftUI `Text` uses
  those of the translation. Prefer SwiftUI for counted strings.
- Text that the app computes once and keeps updates when its view renders again. Post-change code can
  listen for `.limbaDidChange`.
- Free model tiers limit requests per minute. The CLI waits as long as the server asks and saves each
  batch, so a rerun only translates what is missing.
- Some local servers reject `response_format`; pass `--no-json-mode`.
- Do not copy wording from the localizations that ship with macOS. They are often literal: macOS calls
  a display «Afișaj» in Romanian, a word nobody says.

## 7. Report

Say which screens were audited and what the audit printed, which places were checked in code only,
the language used for the smoke test, and any string left hardcoded on purpose, with the reason.
