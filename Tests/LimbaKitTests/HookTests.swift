import Foundation
import LimbaCore
import LimbaHook
@testable import LimbaKit
import XCTest

/// Exercises the hook on a throwaway bundle, the way an app's main bundle is hooked.
final class HookTests: XCTestCase {
    var root: URL!
    var appBundle: Bundle!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("limba-tests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Fake.bundle")
        try StringsFiles.writeStrings(["Hello": "Hello", "Only English": "Only English"], to: app.appendingPathComponent("en.lproj/Localizable.strings"))
        appBundle = try XCTUnwrap(Bundle(path: app.path))
        _ = LBHook.install(on: appBundle)
    }

    override func tearDownWithError() throws {
        LBHook.setOverlayBundle(nil, language: nil)
        LBHook.markersEnabled = false
        try? FileManager.default.removeItem(at: root)
    }

    func makeOverlay(_ strings: [String: String], plurals: [String: StringsFiles.PluralEntry] = [:], language: String = "ro") throws -> Bundle {
        let stage = root.appendingPathComponent("stage-\(UUID().uuidString)")
        try StringsFiles.writeStrings(strings, to: stage.appendingPathComponent("\(language).lproj/Localizable.strings"))
        if !plurals.isEmpty {
            try StringsFiles.writeStringsdict(plurals, to: stage.appendingPathComponent("\(language).lproj/Localizable.stringsdict"))
        }
        return try XCTUnwrap(Bundle(path: stage.path))
    }

    func testInstallHooksThePublicMethods() {
        let log = LBHook.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("localizedStringForKey:value:table:"), log)
        XCTAssertTrue(log.contains("localizedAttributedStringForKey:value:table:"), log)
    }

    func testOverlayWinsAndMissingKeysFallBack() throws {
        XCTAssertEqual(appBundle.localizedString(forKey: "Hello", value: nil, table: nil), "Hello")
        LBHook.setOverlayBundle(try makeOverlay(["Hello": "Salut"]), language: "ro")
        XCTAssertEqual(appBundle.localizedString(forKey: "Hello", value: nil, table: nil), "Salut")
        XCTAssertEqual(appBundle.localizedString(forKey: "Only English", value: nil, table: nil), "Only English")
        XCTAssertEqual(NSLocalizedString("Hello", bundle: appBundle, comment: ""), "Salut")
        XCTAssertEqual(String(localized: "Hello", bundle: appBundle), "Salut")
        LBHook.setOverlayBundle(nil, language: nil)
        XCTAssertEqual(appBundle.localizedString(forKey: "Hello", value: nil, table: nil), "Hello")
    }

    func testFoundationPluralsComeFromTheOverlay() throws {
        let entry = StringsFiles.PluralEntry(forms: ["one": "%lld fișier", "few": "%lld fișiere", "other": "%lld de fișiere"], valueType: "lld")
        LBHook.setOverlayBundle(try makeOverlay([:], plurals: ["%lld files": entry]), language: "ro")
        let ro = Locale(identifier: "ro")
        XCTAssertEqual(String(localized: "\(1) files", bundle: appBundle, locale: ro), "1 fișier")
        XCTAssertEqual(String(localized: "\(3) files", bundle: appBundle, locale: ro), "3 fișiere")
        XCTAssertEqual(String(localized: "\(20) files", bundle: appBundle, locale: ro), "20 de fișiere")
    }

    func testAttributedLookupUsesOverlay() throws {
        LBHook.setOverlayBundle(try makeOverlay(["**Bold** text": "Text **îngroșat**"]), language: "ro")
        let a = AttributedString(localized: "**Bold** text", bundle: appBundle)
        XCTAssertEqual(String(a.characters), "Text îngroșat")
    }

    func testMarkersNameTheKey() throws {
        LBHook.setOverlayBundle(try makeOverlay(["Hello": "Salut"]), language: "ro")
        LBHook.markersEnabled = true
        let marked = appBundle.localizedString(forKey: "Hello", value: nil, table: nil)
        let (text, ids) = Markers.decode(marked)
        XCTAssertEqual(text, "Salut")
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(LBHook.markerTable()[NSNumber(value: ids[0])], "Localizable\u{1F}Hello")
        XCTAssertEqual(LBHook.string(byRemovingMarkers: marked), "Salut")
    }

    func testReverseLookupAndSeenKeys() throws {
        LBHook.setOverlayBundle(try makeOverlay(["Hello": "Salut"]), language: "ro")
        _ = appBundle.localizedString(forKey: "Hello", value: nil, table: nil)
        _ = appBundle.localizedString(forKey: "Not in any catalog", value: nil, table: nil)
        XCTAssertEqual(LBHook.tableKey(forValue: "Salut"), "Localizable\u{1F}Hello")
        XCTAssertTrue(LBHook.seenTableKeys().contains("Localizable\u{1F}Not in any catalog"))
    }
}

final class FormatIndexTests: XCTestCase {
    func testMatchAndRefill() throws {
        let index = FormatIndex(["%lld files in %@": "Localizable\u{1F}%lld files in %@"])
        let (key, args) = try XCTUnwrap(index.match("3 files in Downloads"))
        XCTAssertEqual(key, "Localizable\u{1F}%lld files in %@")
        XCTAssertEqual(args, [1: "3", 2: "Downloads"])
        XCTAssertEqual(FormatIndex.fill("În %2$@ sunt %1$lld fișiere", with: args), "În Downloads sunt 3 fișiere")
        XCTAssertEqual(FormatIndex.fill("%lld fișiere în %@", with: args), "3 fișiere în Downloads")
    }
}
