import Foundation
import SwiftUI

/// In-app language (Arabic default, French, English). Changing it re-renders the whole UI immediately
/// (the root view is keyed on the language) and also sets `AppleLanguages` so system-provided texts
/// (permission alerts) follow on next launch.
@Observable
final class LanguageManager {
    static let shared = LanguageManager()

    private static let key = "bayen.language"

    private(set) var language: AppLanguage

    init(defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: Self.key), let lang = AppLanguage(rawValue: raw) {
            language = lang
        } else if let preferred = Locale.preferredLanguages.first, preferred.hasPrefix("fr") {
            language = .fr
        } else if let preferred = Locale.preferredLanguages.first, preferred.hasPrefix("en") {
            language = .en
        } else {
            language = .ar
        }
        L10n.setLanguage(language)
    }

    func set(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        guard language != self.language else { return }
        defaults.set(language.rawValue, forKey: Self.key)
        defaults.set([language.rawValue], forKey: "AppleLanguages")
        L10n.setLanguage(language)
        self.language = language
    }

    var layoutDirection: LayoutDirection { language.isRTL ? .rightToLeft : .leftToRight }
    var locale: Locale { L10n.locale }
}

/// String lookup in the String Catalog (`Localizable.xcstrings`) for the *in-app* language,
/// independent from the device language.
enum L10n {
    private static let lock = NSLock()
    private static var bundle: Bundle = .main
    private static var currentLanguage: AppLanguage = .ar

    static func setLanguage(_ language: AppLanguage) {
        lock.lock(); defer { lock.unlock() }
        currentLanguage = language
        if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"), let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
    }

    static var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return currentLanguage
    }

    /// Arabic uses Western digits in Morocco ("ar-MA" formats numbers as 0-9).
    static var locale: Locale {
        switch language {
        case .ar: return Locale(identifier: "ar_MA")
        case .fr: return Locale(identifier: "fr_MA")
        case .en: return Locale(identifier: "en_MA")
        }
    }

    static func tr(_ key: String) -> String {
        lock.lock(); let b = bundle; lock.unlock()
        return b.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Format with arguments (`%@`, `%lld`). Plural rules from the catalog are applied.
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: locale, arguments: args)
    }
}
