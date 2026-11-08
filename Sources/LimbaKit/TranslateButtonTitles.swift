import Foundation

/// "Translate with Limba" in the languages LimbaKit knows, so that the button can be found by someone
/// who can't read the language the app is written in.
enum TranslateButtonTitles {
    static let english = "Translate with Limba"

    /// Keyed by BCP 47 identifier. A script or region is only part of the key where the text differs.
    static let titles: [String: String] = [
        "af": "Vertaal met Limba",
        "ar": "ترجم باستخدام Limba",
        "az": "Limba ilə tərcümə et",
        "be": "Перакласці з дапамогай Limba",
        "bg": "Преведи с Limba",
        "bn": "Limba দিয়ে অনুবাদ করুন",
        "bs": "Prevedi pomoću aplikacije Limba",
        "ca": "Tradueix amb Limba",
        "cs": "Přeložit pomocí Limba",
        "cy": "Cyfieithu gyda Limba",
        "da": "Oversæt med Limba",
        "de": "Mit Limba übersetzen",
        "el": "Μετάφραση με το Limba",
        "en": english,
        "es": "Traducir con Limba",
        "et": "Tõlgi Limba abil",
        "fa": "ترجمه با Limba",
        "fi": "Käännä Limba-sovelluksella",
        "fil": "Isalin gamit ang Limba",
        "fr": "Traduire avec Limba",
        "gl": "Traducir con Limba",
        "gu": "Limba વડે અનુવાદ કરો",
        "he": "תרגום באמצעות Limba",
        "hi": "Limba से अनुवाद करें",
        "hr": "Prevedi pomoću aplikacije Limba",
        "hu": "Fordítás a Limba segítségével",
        "hy": "Թարգմանել Limba-ով",
        "id": "Terjemahkan dengan Limba",
        "is": "Þýða með Limba",
        "it": "Traduci con Limba",
        "ja": "Limbaで翻訳",
        "ka": "თარგმნა Limba-ით",
        "kk": "Limba арқылы аудару",
        "kn": "Limba ಮೂಲಕ ಅನುವಾದಿಸಿ",
        "ko": "Limba로 번역",
        "lt": "Versti su Limba",
        "lv": "Tulkot ar Limba",
        "mk": "Преведи со Limba",
        "ml": "Limba ഉപയോഗിച്ച് വിവർത്തനം ചെയ്യുക",
        "mr": "Limba ने भाषांतर करा",
        "ms": "Terjemah dengan Limba",
        "nb": "Oversett med Limba",
        "ne": "Limba मार्फत अनुवाद गर्नुहोस्",
        "nl": "Vertalen met Limba",
        "nn": "Omset med Limba",
        "pl": "Przetłumacz za pomocą Limba",
        "pt": "Traduzir com o Limba",
        "ro": "Tradu cu Limba",
        "ru": "Перевести с помощью Limba",
        "sk": "Preložiť pomocou Limba",
        "sl": "Prevedi z aplikacijo Limba",
        "sq": "Përkthe me Limba",
        "sr": "Преведи помоћу апликације Limba",
        "sr-Latn": "Prevedi pomoću aplikacije Limba",
        "sv": "Översätt med Limba",
        "sw": "Tafsiri kwa Limba",
        "ta": "Limba மூலம் மொழிபெயர்",
        "te": "Limba తో అనువదించండి",
        "th": "แปลด้วย Limba",
        "tr": "Limba ile çevir",
        "uk": "Перекласти за допомогою Limba",
        "ur": "Limba کے ساتھ ترجمہ کریں",
        "uz": "Limba bilan tarjima qilish",
        "vi": "Dịch bằng Limba",
        "zh-Hans": "使用 Limba 翻译",
        "zh-Hant": "使用 Limba 翻譯",
    ]

    /// The title in the first of `languages` that has one, or English.
    static func title(for languages: [String]) -> String {
        for identifier in languages {
            if let title = title(forLanguage: identifier) {
                return title
            }
        }
        return english
    }

    /// The title for one language identifier such as `pt-BR`, `zh-Hant-TW` or `sr-Latn-RS`.
    static func title(forLanguage identifier: String) -> String? {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else {
            return nil
        }
        if let script = language.script?.identifier, let title = titles["\(code)-\(script)"] {
            return title
        }
        if code == "zh" {
            // Chinese without a script: Taiwan, Hong Kong and Macau write Traditional.
            let region = language.region?.identifier
            let traditional = ["TW", "HK", "MO"].contains(region ?? "")
            return titles[traditional ? "zh-Hant" : "zh-Hans"]
        }
        if code == "no" {
            return titles["nb"]
        }
        return titles[code]
    }
}
