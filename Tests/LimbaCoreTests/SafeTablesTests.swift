import Foundation
@testable import LimbaCore
import XCTest

final class SafeTablesTests: XCTestCase {
    func plist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func testTextStringsFileIsKept() {
        let data = Data(#""Quit" = "Ieșire";"Settings" = "Setări";"#.utf8)
        XCTAssertEqual(SafeTables.strings(from: data), ["Quit": "Ieșire", "Settings": "Setări"])
    }

    func testValuesThatAreNotTextAreDropped() {
        let data = plist(["Quit": ["nested": "x"], "Count": 5, "Settings": "Setări"] as [String: Any])
        XCTAssertEqual(SafeTables.strings(from: data), ["Settings": "Setări"])
    }

    func testUnreadableFilesAreRejected() {
        XCTAssertNil(SafeTables.cleaned(Data(), name: "Localizable.strings"))
        XCTAssertNil(SafeTables.cleaned(Data([0xFF, 0xFE, 0x00, 0xD8]), name: "Localizable.strings"))
        XCTAssertNil(SafeTables.cleaned(Data(#""Quit" = "Ieș"#.utf8), name: "Localizable.strings"))
        XCTAssertNil(SafeTables.cleaned(Data("(1, 2, 3)".utf8), name: "Localizable.strings"))
        XCTAssertNil(SafeTables.cleaned(Data(#""a" = "b";"#.utf8), name: "notes.txt"))
    }

    func testCleanedFileLoadsInABundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lproj = root.appendingPathComponent("ro.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        let dirty = plist(["Quit": ["nested": "x"], "Settings": "Setări"] as [String: Any])
        try XCTUnwrap(SafeTables.cleaned(dirty, name: "Localizable.strings")).write(to: lproj.appendingPathComponent("Localizable.strings"))
        let bundle = try XCTUnwrap(Bundle(path: root.path))
        XCTAssertEqual(bundle.localizedString(forKey: "Settings", value: nil, table: nil), "Setări")
        XCTAssertEqual(bundle.localizedString(forKey: "Quit", value: "Quit", table: nil), "Quit")
        try? FileManager.default.removeItem(at: root)
    }

    func testStringsdictRules() {
        let good: [String: Any] = [
            "NSStringLocalizedFormatKey": "%#@n@",
            "n": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld", "one": "%lld fișier", "other": "%lld fișiere"],
        ]
        let missingVariable: [String: Any] = ["NSStringLocalizedFormatKey": "%#@n@"]
        let wrongTypes: [String: Any] = ["NSStringLocalizedFormatKey": 5]
        let data = plist(["%lld files": good, "%lld windows": missingVariable, "%lld tabs": wrongTypes, "x": "text"] as [String: Any])
        let clean = SafeTables.stringsdict(from: data)
        XCTAssertEqual(clean?.keys.sorted(), ["%lld files"])
    }
}

final class DateCodingTests: XCTestCase {
    struct Box: Codable, Equatable { let d: Date }

    func testSameTextAsTheFormatter() throws {
        let date = Date(timeIntervalSinceReferenceDate: 815_000_000.125)
        let old = ISO8601DateFormatter()
        old.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let json = String(decoding: try JSONEncoder.limba.encode(Box(d: date)), as: UTF8.self)
        XCTAssertTrue(json.contains(old.string(from: date)), json)
    }

    func testReadsBothForms() throws {
        for text in ["2026-11-11T08:44:37.144Z", "2026-11-11T08:44:37Z", "2026-11-11T10:44:37+02:00"] {
            let box = try JSONDecoder.limba.decode(Box.self, from: Data(#"{"d":"\#(text)"}"#.utf8))
            XCTAssertEqual(box.d.timeIntervalSince1970, 1_794_386_677, accuracy: 1, text)
        }
        XCTAssertThrowsError(try JSONDecoder.limba.decode(Box.self, from: Data(#"{"d":"yesterday"}"#.utf8)))
    }
}

final class PlaceholderTests: XCTestCase {
    func plist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func testCompatibleTranslations() {
        XCTAssertTrue(FormatSpecifiers.compatible("%lld fișiere", with: "%lld files"))
        XCTAssertTrue(FormatSpecifiers.compatible("%d fișiere", with: "%lld files"))
        XCTAssertTrue(FormatSpecifiers.compatible("În %2$@ sunt %1$lld fișiere", with: "%lld files in %@"))
        XCTAssertTrue(FormatSpecifiers.compatible("Fișiere", with: "%lld files"))
        XCTAssertTrue(FormatSpecifiers.compatible("100% gata", with: "100% done"))
        XCTAssertTrue(FormatSpecifiers.compatible("%#@count@", with: "%lld files"))
    }

    func testTranslationsThatWouldCrash() {
        XCTAssertFalse(FormatSpecifiers.compatible("%@ fișiere", with: "%lld files"))
        XCTAssertFalse(FormatSpecifiers.compatible("%lld fișiere în %@", with: "%lld files"))
        XCTAssertFalse(FormatSpecifiers.compatible("%2$@", with: "%@"))
        XCTAssertFalse(FormatSpecifiers.compatible("%@", with: "Settings"))
        XCTAssertFalse(FormatSpecifiers.compatible("%1$@ %1$lld", with: "%@"))
    }

    func testStringsDropOnlyTheBadValues() {
        let data = plist(["%lld files": "%@ fișiere", "%lld items": "%lld elemente", "Open": "Deschide %@", "key.title": "Titlu %@"])
        let clean = SafeTables.strings(from: data, sources: ["key.title": "Title %@"])
        XCTAssertEqual(clean, ["%lld items": "%lld elemente", "key.title": "Titlu %@"])
    }

    func testStringsdictFormsMustReadTheCount() {
        func entry(_ one: String, _ other: String) -> [String: Any] {
            ["NSStringLocalizedFormatKey": "%#@count@",
             "count": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld", "one": one, "other": other]]
        }
        let data = plist([
            "%lld files": entry("un fișier", "%lld fișiere"),
            "%lld songs": entry("o melodie", "%@ melodii"),
            "%lld rows in %@": ["NSStringLocalizedFormatKey": "%#@count@",
                                "count": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                                          "one": "un rând în %2$@", "other": "%lld rânduri în %2$@"]],
        ])
        let clean = SafeTables.stringsdict(from: data) ?? [:]
        XCTAssertNotNil(clean["%lld files"])
        XCTAssertNil(clean["%lld songs"])
        XCTAssertNotNil(clean["%lld rows in %@"])
    }
}
