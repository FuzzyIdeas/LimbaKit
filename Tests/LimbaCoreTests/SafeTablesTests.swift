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
