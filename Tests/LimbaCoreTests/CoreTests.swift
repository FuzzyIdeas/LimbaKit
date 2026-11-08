import Foundation
@testable import LimbaCore
import XCTest

final class MarkerTests: XCTestCase {
    func testRoundTrip() {
        for id in [0, 1, 7, 239, 240, 241, 57_599, 57_600, 1_000_000] {
            let marked = "Enable MCP" + Markers.encode(id)
            let (text, ids) = Markers.decode(marked)
            XCTAssertEqual(text, "Enable MCP")
            XCTAssertEqual(ids, [id])
        }
    }

    func testSeveralMarkersAndPlainText() {
        let s = "A" + Markers.encode(3) + " and B" + Markers.encode(500)
        let (text, ids) = Markers.decode(s)
        XCTAssertEqual(text, "A and B")
        XCTAssertEqual(ids, [3, 500])
        XCTAssertEqual(Markers.decode("plain").ids, [])
        // A lone word joiner is not a marker and stays.
        XCTAssertEqual(Markers.decode("a\u{2060}b").text, "a\u{2060}b")
    }
}

final class FormatSpecifierTests: XCTestCase {
    func testParse() {
        let specs = FormatSpecifiers.parse("%1$@ has %2$lld files, %.1f%% done, %#@count@")
        XCTAssertEqual(specs.map(\.raw), ["%1$@", "%2$lld", "%.1f", "%#@count@"])
        XCTAssertEqual(specs.map(\.position), [1, 2, nil, nil])
        XCTAssertEqual(specs.map(\.type), ["@", "lld", "f", "#@count@"])
    }

    func testSignatureIgnoresOrderAndIntegerWidth() {
        XCTAssertEqual(FormatSpecifiers.signature("%@ copied %lld files"), FormatSpecifiers.signature("%2$d fișiere copiate de %1$@"))
        XCTAssertNotEqual(FormatSpecifiers.signature("%@ %@"), FormatSpecifiers.signature("%@"))
        XCTAssertEqual(FormatSpecifiers.signature("100%% done"), [])
    }

    func testPluralValueType() {
        XCTAssertEqual(FormatSpecifiers.pluralValueType("%lld files"), "lld")
        XCTAssertEqual(FormatSpecifiers.pluralValueType("%@ in %d folders"), "d")
        XCTAssertNil(FormatSpecifiers.pluralValueType("%@ only"))
    }
}

final class StringsFileTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testStringsRoundTrip() throws {
        let pairs = ["Hello": "Salut", "Quote \"x\"": "Citat „x\"", "Two\nlines": "Două\nrânduri", "Tab\there": "Tab\taici", "Back\\slash": "Bară\\inversă"]
        let url = dir.appendingPathComponent("Localizable.strings")
        try StringsFiles.writeStrings(pairs, to: url)
        XCTAssertEqual(StringsFiles.readStrings(url), pairs)
    }

    func testStringsdictRoundTrip() throws {
        let entries = ["%lld files": StringsFiles.PluralEntry(forms: ["one": "%lld fișier", "few": "%lld fișiere", "other": "%lld de fișiere"], valueType: "lld")]
        let url = dir.appendingPathComponent("Localizable.stringsdict")
        try StringsFiles.writeStringsdict(entries, to: url)
        XCTAssertEqual(StringsFiles.readStringsdict(url), entries)
    }

    func testBundleLoadsWrittenFilesWithRomanianPlurals() throws {
        let lproj = dir.appendingPathComponent("ro.lproj")
        try StringsFiles.writeStrings(["Hello": "Salut"], to: lproj.appendingPathComponent("Localizable.strings"))
        try StringsFiles.writeStringsdict(
            ["%lld files": .init(forms: ["one": "%lld fișier", "few": "%lld fișiere", "other": "%lld de fișiere"], valueType: "lld")],
            to: lproj.appendingPathComponent("Localizable.stringsdict")
        )
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        XCTAssertEqual(bundle.localizedString(forKey: "Hello", value: "x", table: nil), "Salut")
        let format = bundle.localizedString(forKey: "%lld files", value: nil, table: nil)
        let ro = Locale(identifier: "ro")
        XCTAssertEqual(String(format: format, locale: ro, 1), "1 fișier")
        XCTAssertEqual(String(format: format, locale: ro, 3), "3 fișiere")
        XCTAssertEqual(String(format: format, locale: ro, 20), "20 de fișiere")
    }

    func testPluralCountsTheNumberWhenItIsNotTheFirstArgument() throws {
        let key = "Delete %@ with %lld rules?"
        XCTAssertEqual(FormatSpecifiers.pluralArgument(key), 2)
        XCTAssertEqual(FormatSpecifiers.pluralArgument("%2$lld of %1$@"), 2)
        let lproj = dir.appendingPathComponent("ro.lproj")
        let entry = StringsFiles.PluralEntry(forms: ["one": "Ștergi %1$@ cu o regulă?", "few": "Ștergi %1$@ cu %2$lld reguli?", "other": "Ștergi %1$@ cu %2$lld de reguli?"], valueType: "lld", argument: 2)
        try StringsFiles.writeStringsdict([key: entry], to: lproj.appendingPathComponent("Localizable.stringsdict"))
        XCTAssertEqual(StringsFiles.readStringsdict(lproj.appendingPathComponent("Localizable.stringsdict"))[key], entry)
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        let ro = Locale(identifier: "ro")
        XCTAssertEqual(String(format: format, locale: ro, "Grupul", 1), "Ștergi Grupul cu o regulă?")
        XCTAssertEqual(String(format: format, locale: ro, "Grupul", 3), "Ștergi Grupul cu 3 reguli?")
        XCTAssertEqual(String(format: format, locale: ro, "Grupul", 25), "Ștergi Grupul cu 25 de reguli?")
    }
}

final class CatalogTests: XCTestCase {
    func testSourceStrings() throws {
        let json = """
        {
          "sourceLanguage": "en",
          "version": "1.0",
          "strings": {
            "": {},
            "Enable MCP": { "comment": "Toggle in Settings" },
            "Lunar": { "shouldTranslate": false },
            "old": { "extractionState": "stale" },
            "greeting_key": { "localizations": { "en": { "stringUnit": { "state": "translated", "value": "Hello there" } } } },
            "%lld files": { "localizations": { "en": { "variations": { "plural": {
              "one": { "stringUnit": { "state": "translated", "value": "%lld file" } },
              "other": { "stringUnit": { "state": "translated", "value": "%lld files" } }
            } } } } }
          }
        }
        """
        let catalog = try JSONDecoder().decode(StringCatalog.self, from: Data(json.utf8))
        let strings = catalog.sourceStrings(table: "Localizable")
        XCTAssertEqual(strings.map(\.key), ["%lld files", "Enable MCP", "greeting_key", "Lunar"])
        let byKey = Dictionary(uniqueKeysWithValues: strings.map { ($0.key, $0) })
        XCTAssertEqual(byKey["greeting_key"]?.text, "Hello there")
        XCTAssertEqual(byKey["Enable MCP"]?.comment, "Toggle in Settings")
        XCTAssertEqual(byKey["Lunar"]?.translate, false)
        XCTAssertEqual(byKey["%lld files"]?.plural, ["one": "%lld file", "other": "%lld files"])
        XCTAssertEqual(byKey["%lld files"]?.text, "%lld files")
    }
}

final class PluralRuleTests: XCTestCase {
    func testCategories() {
        XCTAssertEqual(PluralRules.categories(for: "ro"), ["one", "few", "other"])
        XCTAssertEqual(PluralRules.categories(for: "pt-BR"), ["one", "many", "other"])
        XCTAssertEqual(PluralRules.categories(for: "zh-Hans"), ["other"])
        XCTAssertEqual(PluralRules.categories(for: "de"), ["one", "other"])
    }
}
