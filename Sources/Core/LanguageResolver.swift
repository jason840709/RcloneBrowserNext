import Foundation

/// One resolver for the native host and the WebView bootstrap. Choosing System
/// follows the user's primary language, including macOS per-app preferences.
enum RBNLanguageResolver {
    static func resolve(_ selection: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if ["zh-TW", "en", "ja"].contains(selection) { return selection }
        guard selection == "system", let primary = preferredLanguages.first else { return "en" }
        let language = primary.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
        switch language {
        case "zh": return "zh-TW"
        case "ja": return "ja"
        default: return "en"
        }
    }
}
