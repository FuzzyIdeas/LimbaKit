# Limba protocol, version 1

Limba lets the users of a Mac app translate it into their own language with the AI model or service
they choose. You as the developer keep the app in a single language and the users can run the Limba app
to translate it into their own language.

The protocol has three parts, and each uses formats that Xcode already produces:

1. The app ships its **source strings**: the String Catalogs, copied into the bundle unprocessed.
2. Translators write **translation files** to a known folder outside the app bundle, in the standard
   `.lproj` layout (`.strings` and `.stringsdict`). The app's code signature is never touched.
3. A running app can take **commands** from a translator: switch language, reveal which string is
   which on screen, open a screen. This part is optional.

An app can adopt these in steps. Step 1 alone already lets a translator produce a language that the
app uses after a relaunch.

The reference runtime for apps is `LimbaKit` (Swift, macOS 13+). The reference translator is the
Limba app and its `limba` command line tool. Any other implementation that
follows this document works with both.

## 1. Source strings, inside the app bundle

The app copies its String Catalogs (`.xcstrings`) into `Contents/Resources/Limba/`, byte for byte.
The copy is a separate *Copy Files* build phase with destination *Resources* and subpath `Limba`,
because Xcode compiles catalogs listed under *Copy Bundle Resources*. One catalog per table:
`Localizable.xcstrings` is the table named `Localizable`, `InfoPlist.xcstrings` is `InfoPlist`, and so on.

The catalog format is Xcode's String Catalog JSON. Translators read these fields:

| Field | Use |
|---|---|
| `sourceLanguage` | the language the app is written in |
| `strings.<key>` | the key that the code looks up |
| `strings.<key>.localizations.<source>.stringUnit.value` | the source text, when it differs from the key |
| `strings.<key>.localizations.<source>.variations.plural` | plural forms of the source text |
| `strings.<key>.comment` | the developer's note for translators |
| `strings.<key>.shouldTranslate` | `false` for strings that stay as they are (names, codes) |
| `strings.<key>.extractionState` | `stale` strings are no longer used and are skipped |

When a key has no source value, the key itself is the source text, which is how SwiftUI literals work.

### The manifest, optional

`Contents/Resources/Limba/app.json` describes the app for translators:

```json
{
  "protocol": 1,
  "description": "Lunar controls the brightness, contrast and volume of external monitors.",
  "context": "Users are people with one or more external monitors. Brightness is a percentage.",
  "glossary": [
    { "term": "Sub-zero", "note": "Dimming below 0% brightness by darkening the picture in software", "translate": false },
    { "term": "Sync Mode", "note": "Copies the built-in display's brightness to external monitors" }
  ]
}
```

`description` and `context` are prose for the translation model. A glossary entry with `"translate":
false` stays in the source language. Other entries explain a term so that the model picks the right
meaning. The person translating can add their own notes on top. Those notes stay with their translator.

A longer text can go in `Contents/Resources/Limba/context.md`, which translators append to
`context`.

## 2. Translation files, outside the app bundle

Translations live in the app's Application Support folder, as the app itself resolves it:

    <Application Support>/Limba/<bundle identifier>/<language>.lproj/<Table>.strings
    <Application Support>/Limba/<bundle identifier>/<language>.lproj/<Table>.stringsdict

- `<Application Support>` is `~/Library/Application Support` for an app without App Sandbox, and
  `~/Library/Containers/<bundle identifier>/Data/Library/Application Support` for a sandboxed app.
- `<language>` is the language identifier that Apple uses for `.lproj` folders: `ro`, `de`, `pt-BR`,
  `zh-Hans`.
- `<Table>` matches the name of a source catalog.
- `.strings` holds `"key" = "translation";` pairs, UTF-8 or UTF-16. `.stringsdict` holds plural
  variations in Apple's property list format, keyed by the same key.
- Keys that are missing fall back to the app's built-in text.
- Writers replace a file in one step, by writing a temporary file next to it and renaming it, to keep
  the app from reading half a file.

A translator may also write `language.json` next to the tables:

```json
{ "protocol": 1, "language": "ro", "name": "Română", "translator": "Limba", "updated": "2026-11-07T10:00:00Z" }
```

## 3. Choosing the language

The app keeps the chosen language in its user defaults, under the key `LimbaLanguage`. A missing
or empty value means the app's built-in language. The app lists the languages it can offer by looking
for `.lproj` folders in its translation folder.

A translator can set the language for the next launch with
`defaults write <bundle identifier> LimbaLanguage ro`, or switch a running app with the `select`
command below.

## 4. Live updates

A running app watches its translation folder. When a file changes, the new text applies without a
relaunch. How much of the screen updates in place depends on the runtime. With LimbaKit, SwiftUI
text updates under any view that carries the `.limba()` modifier, and the runtime updates AppKit
windows and menus.

## 5. Commands, optional

A translator talks to a running app through distributed notifications. It posts the notification
`limba.command`, with the app's bundle identifier as the object and a `userInfo` dictionary:

| `command` | Other keys | Effect |
|---|---|---|
| `hello` | | the app writes its state |
| `select` | `language`: identifier, or empty for the built-in language | switches language and saves the choice |
| `probe` | `on`: true or false | turns markers on or off (below) |
| `show` | `screen`: a screen identifier | opens that screen |
| `refresh` | | rebuilds the app's windows, for text that only updates on a rebuild |

The app answers by writing `state.json` in its translation folder and posting `limba.state` with its
bundle identifier as the object:

```json
{
  "protocol": 1,
  "pid": 4242,
  "language": "ro",
  "revision": 12,
  "probe": true,
  "capabilities": ["live", "probe", "screens"],
  "screens": [{ "id": "settings.general", "title": "Settings > General" }],
  "markers": { "1": ["Localizable", "Ambient light threshold"] },
  "seen": [["Localizable", "Some key that is missing from the catalogs"]]
}
```

`seen` lists keys that the app looked up while running but that no shipped catalog contains, such as
strings from a Swift package that resolve against the main bundle. Translators treat them as source
strings too.

### Markers

While probe is on, every string that the app resolves ends with an invisible marker:

1. U+2060 WORD JOINER
2. the marker number in base 240, highest digit first, each digit written as the variation selector
   U+E0100 + digit (U+E0100 to U+E01EF)
3. U+2060 WORD JOINER

`markers` in `state.json` maps each number to its table and key. Text drawn with a marker looks the same
as text without one, in SwiftUI and AppKit. A translator reads the app's windows through the
Accessibility API, decodes the markers, and learns which key each element on screen shows, what kind of
control it is, and what sits next to it. Strings with plural variations that resolve through Foundation
may carry no marker, and translators match those by their text.

## 6. Context for the translation model

Translators combine these to know where a string appears:

- the catalog `comment` of each key,
- the manifest's description, context and glossary,
- what the probe reveals: the window and section a string sits in, the role of the element (button,
  toggle, menu item, label, tooltip, placeholder) and the other elements on the same row,
- the notes and glossary that the person translating adds.

## 7. Opening the translator from the app, optional

An app can open the translator on itself, usually from a button next to the language menu, with the link

    limba://translate?app=<bundle identifier>&language=<code>

`language` is optional, a BCP 47 code such as `ro`, `pt-BR` or `zh-Hans`, or a preferred language of
the Mac such as `ro-RO`, which the translator reduces to the language it writes. A translator that
registers the `limba` URL scheme selects the app and opens that language, or starts it when it has no
translation yet. When no translator is installed, the app opens https://lowtechguys.com/limba instead.

`LimbaTranslateButton` in LimbaKit does all of this. It sends the language the app shows, or the first
preferred language of the Mac that the app is not written in.

## Versioning

`protocol` is 1 for this document. A runtime ignores commands and fields that it does not know.
