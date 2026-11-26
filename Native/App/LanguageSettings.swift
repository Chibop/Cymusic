import SwiftUI

enum AppLanguage: String, CaseIterable {
    case system, chinese = "zh-Hans", english = "en"

    static let storageKey = "app.language"

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        default: return Locale(identifier: rawValue)
        }
    }

    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }
}

/// Place inside the existing settings Form; selection survives relaunches.
struct LanguagePicker: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system

    var body: some View {
        Picker("语言", selection: $language) {
            Text("跟随系统").tag(AppLanguage.system)
            Text(verbatim: "简体中文").tag(AppLanguage.chinese)
            Text(verbatim: "English").tag(AppLanguage.english)
        }
    }
}

/// For app-owned messages composed outside SwiftUI. Do not pass user metadata,
/// OS errors, or provider responses as keys. SwiftUI literals localize directly.
enum L10n {
    static func text(_ key: String) -> String {
        let language = AppLanguage.selected
        let bundle: Bundle
        if language != .system, let url = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj") {
            bundle = Bundle(url: url) ?? .main
        } else {
            bundle = .main
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: AppLanguage.selected.locale, arguments: arguments)
    }
}
