import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    var localizedTitle: String {
        switch self {
        case .system:
            return L10n.t("Follow System")
        case .english:
            return L10n.t("English")
        case .simplifiedChinese:
            return L10n.t("Simplified Chinese")
        }
    }
}

enum L10n {
    static let languageDidChange = Notification.Name("L10nLanguageDidChange")

    static var currentLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static var currentLocale: Locale {
        if let localeIdentifier = currentLanguage.localeIdentifier {
            return Locale(identifier: localeIdentifier)
        }
        return Locale.current
    }

    private static var selectedBundle: Bundle {
        guard let identifier = currentLanguage.localeIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    static func t(_ key: String) -> String {
        selectedBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: currentLocale, arguments: args)
    }
}

struct LocalizedRootView<Content: View>: View {
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .environment(\.locale, L10n.currentLocale)
    }
}
