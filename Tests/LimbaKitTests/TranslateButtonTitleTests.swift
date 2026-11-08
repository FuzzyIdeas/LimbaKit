@testable import LimbaKit
import XCTest

final class TranslateButtonTitleTests: XCTestCase {
    func testRegionFallsBackToLanguage() {
        XCTAssertEqual(TranslateButtonTitles.title(forLanguage: "ro-RO"), "Tradu prin Limba")
        XCTAssertEqual(TranslateButtonTitles.title(forLanguage: "pt-BR"), "Traduzir com o Limba")
    }

    func testChineseScripts() {
        XCTAssertEqual(TranslateButtonTitles.title(forLanguage: "zh-Hans-CN"), "使用 Limba 翻译")
        XCTAssertEqual(TranslateButtonTitles.title(forLanguage: "zh-Hant-TW"), "使用 Limba 翻譯")
        XCTAssertEqual(TranslateButtonTitles.title(forLanguage: "zh-TW"), "使用 Limba 翻譯")
        XCTAssertEqual(TranslateButtonTitles.title(forLanguage: "zh-CN"), "使用 Limba 翻译")
    }

    func testSerbianLatin() {
        XCTAssertEqual(TranslateButtonTitles.title(forLanguage: "sr-Latn-RS"), "Prevedi pomoću aplikacije Limba")
        XCTAssertEqual(TranslateButtonTitles.title(forLanguage: "sr"), "Преведи помоћу апликације Limba")
    }

    func testFirstKnownLanguageWins() {
        XCTAssertEqual(TranslateButtonTitles.title(for: ["xx", "ja-JP", "en"]), "Limbaで翻訳")
        XCTAssertEqual(TranslateButtonTitles.title(for: ["xx"]), "Translate with Limba")
    }

    func testEveryTitleNamesLimba() {
        for (language, title) in TranslateButtonTitles.titles {
            XCTAssertTrue(title.contains("Limba"), language)
        }
    }
}
