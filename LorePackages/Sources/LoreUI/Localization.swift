import Foundation

/// UI language selection and string lookup.
///
/// Strings live in the app bundle's `<lang>.lproj/Localizable.strings`. When the
/// user picks an explicit language we load that `.lproj` directly, so switching
/// takes effect immediately (no relaunch). "System" (empty) follows the OS.
enum AppLanguage {
    static let key = "appLanguage"

    /// Languages Lore ships UI translations for. `code` is the `.lproj` name;
    /// `name` is the endonym (shown in its own language, as is conventional).
    static let supported: [(code: String, name: String)] = [
        ("en", "English"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("fr", "Français"),
        ("sv", "Svenska"),
    ]

    /// The current selection ("" / "system" = follow the OS).
    static var current: String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    /// Bundle to read strings from: the chosen language's `.lproj`, or the main
    /// bundle (system language) when no explicit choice is set. Foundation caches
    /// `Bundle(path:)`, so repeated lookups are cheap.
    static var bundle: Bundle {
        let code = current
        guard !code.isEmpty, code != "system",
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    /// Locale for SwiftUI's environment, so dates and numbers follow the choice.
    static func locale(for code: String) -> Locale {
        (code.isEmpty || code == "system") ? .autoupdatingCurrent : Locale(identifier: code)
    }
}

/// Localized UI string from the selected language's Localizable.strings. Using
/// the English text as the key, so a missing translation falls back to readable
/// English. UI only — user content is never translated. `public` so the app
/// target can localize its menu commands too.
public func L(_ key: String) -> String {
    AppLanguage.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// Localized string with `%@`-style arguments.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
