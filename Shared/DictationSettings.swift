import Foundation

/// The user's dictation language, persisted in the App Group defaults so
/// the container app (the owner of recognition) and the keyboard share it.
///
/// There is no API to enumerate the locales Apple's on-device recognizer
/// supports, so this offers a curated list of the most common ones. Each is
/// verified at runtime via `SFSpeechRecognizer.supportsOnDeviceRecognition`
/// (the app's `SpeechRecognitionService` recomputes `supportsOnDevice` for
/// the chosen locale).
@MainActor
@Observable
final class DictationSettings {
    static let shared = DictationSettings()

    /// Curated on-device-dictation locales. Ordered for quick reachability.
    static let supportedLocales: [(id: String, name: String)] = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("zh-CN", "中文（简体）"),
        ("zh-TW", "中文（繁體）"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("es-ES", "Español"),
        ("it-IT", "Italiano"),
        ("pt-BR", "Português (Brasil)"),
        ("ru-RU", "Русский"),
        ("ar-SA", "العربية"),
        ("hi-IN", "हिन्दी"),
        ("vi-VN", "Tiếng Việt"),
        ("th-TH", "ไทย"),
    ]

    private enum Key {
        static let locale = "dictation.locale"
        /// The languages the keyboard's globe key cycles through.
        static let enabledLocales = "dictation.enabledLocales"
    }

    private(set) var localeIdentifier: String
    /// The languages the keyboard's globe key cycles through, in the curated
    /// order. Kept at exactly two — the current locale and the previously
    /// used one — so the globe key simply toggles between them. Managed by
    /// `selectLocale(_:)` from the app's language menu; persisted for the
    /// keyboard.
    private(set) var enabledLocales: [String]

    var locale: Locale { Locale(identifier: localeIdentifier) }

    var localeName: String {
        Self.supportedLocales.first { $0.id == localeIdentifier }?.name ?? localeIdentifier
    }

    private init() {
        let saved = AppGroup.defaults.string(forKey: Key.locale)
        let current: String
        if let saved, Self.supportedLocales.contains(where: { $0.id == saved }) {
            current = saved
        } else {
            current = "en-US"
        }
        localeIdentifier = current
        enabledLocales = Self.loadEnabledLocales(current: current)
    }

    /// Loads the persisted globe-cycle list, validating against the curated
    /// list. Falls back to [en-US, zh-CN] and always includes the current
    /// locale.
    private static func loadEnabledLocales(current: String) -> [String] {
        let saved = AppGroup.defaults.stringArray(forKey: Key.enabledLocales) ?? []
        var list = saved.filter { id in supportedLocales.contains(where: { $0.id == id }) }
        if list.isEmpty {
            list = ["en-US", "zh-CN"]
        }
        if !list.contains(current) {
            list.insert(current, at: 0)
        }
        return list
    }

    func setLocale(_ identifier: String) {
        guard identifier != localeIdentifier,
              Self.supportedLocales.contains(where: { $0.id == identifier }) else { return }
        localeIdentifier = identifier
        AppGroup.defaults.set(identifier, forKey: Key.locale)
    }

    /// Compact label for the keyboard's globe key (e.g. "EN", "中", "日",
    /// "한").
    var shortCode: String {
        switch localeIdentifier {
        case "zh-CN", "zh-TW": return "中"
        case "ja-JP": return "日"
        case "ko-KR": return "한"
        default:
            let lang = localeIdentifier.split(separator: "-").first.map(String.init) ?? "EN"
            return lang.prefix(2).uppercased()
        }
    }

    /// Moves to the next locale in the ENABLED set (the globe-key cycle),
    /// wrapping around. With two enabled languages this simply toggles
    /// between them.
    func cycleToNextLocale() {
        guard let idx = enabledLocales.firstIndex(of: localeIdentifier) else {
            setLocale(enabledLocales.first ?? "en-US")
            return
        }
        let next = enabledLocales[(idx + 1) % enabledLocales.count]
        setLocale(next)
    }

    /// The app's language picker calls this. Makes `identifier` the current
    /// locale (the latest clicked language becomes the current one) and
    /// ensures it's in the globe-key cycle (checked in the picker).
    func selectLocale(_ identifier: String) {
        guard Self.supportedLocales.contains(where: { $0.id == identifier }) else { return }
        localeIdentifier = identifier
        AppGroup.defaults.set(identifier, forKey: Key.locale)
        if !enabledLocales.contains(identifier) {
            enabledLocales.append(identifier)
            AppGroup.defaults.set(enabledLocales, forKey: Key.enabledLocales)
        }
    }

    /// Adds/removes a language to/from the globe-key cycle (the checked set
    /// in the app's language picker). The current locale can't be removed
    /// while another enabled language exists — the current locale switches
    /// to that other one first.
    func setEnabled(_ identifier: String, enabled: Bool) {
        guard Self.supportedLocales.contains(where: { $0.id == identifier }) else { return }
        var list = enabledLocales
        if enabled {
            if !list.contains(identifier) {
                list.append(identifier)
            }
        } else {
            if identifier == localeIdentifier {
                guard let fallback = list.first(where: { $0 != identifier }) else { return }
                setLocale(fallback)
            }
            list.removeAll { $0 == identifier }
        }
        enabledLocales = list
        AppGroup.defaults.set(list, forKey: Key.enabledLocales)
    }

    /// Re-reads the persisted values — e.g. after the keyboard extension
    /// changed them in another process. No-op when unchanged.
    func reloadFromDefaults() {
        let saved = AppGroup.defaults.string(forKey: Key.locale)
        if let saved, saved != localeIdentifier,
           Self.supportedLocales.contains(where: { $0.id == saved }) {
            localeIdentifier = saved
        }
        if let saved = AppGroup.defaults.stringArray(forKey: Key.enabledLocales),
           !saved.isEmpty {
            let valid = saved.filter { id in Self.supportedLocales.contains(where: { $0.id == id }) }
            if !valid.isEmpty {
                enabledLocales = valid
                if !enabledLocales.contains(localeIdentifier) {
                    enabledLocales.insert(localeIdentifier, at: 0)
                }
            }
        }
    }
}
