import Foundation

/// The user's dictation languages, persisted in the App Group defaults so
/// the container app (the owner of recognition) and the keyboard share them.
///
/// There is no API to enumerate the locales Apple's on-device recognizer
/// supports, so this offers a curated list of the most common ones. Each is
/// verified at runtime via `SFSpeechRecognizer.supportsOnDeviceRecognition`
/// (the app's `SpeechRecognitionService` recomputes `supportsOnDevice` for
/// the chosen locale).
///
/// # Model
/// - `localeIdentifier` is the ACTIVE language — the one the next dictation
///   uses, whether started from the app or from the keyboard.
/// - `selectedLocales` holds up to `maxLanguages` (5) languages, the active
///   one first. The keyboard's globe key CYCLES through these.
///
/// The app's language sheet (`LanguagesSheetView`) edits the set:
/// `activate(_:)` picks the ACTIVE one, `add(_:)` / `deselect(_:)` toggle
/// membership. The keyboard only cycles through the persisted list.
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

    /// The most languages the keyboard's globe key can cycle through (and
    /// the most the app's language sheet lets you select).
    static let maxLanguages = 5

    private enum Key {
        static let locale = "dictation.locale"
        /// Storage key for the selected list — deliberately kept under the
        /// older "enabledLocales" name so existing installs keep their
        /// choice. Saved as `[active, …]`.
        static let selectedLocales = "dictation.enabledLocales"
    }

    private(set) var localeIdentifier: String
    /// Up to `maxLanguages` selected languages, ACTIVE first. This is the
    /// keyboard's globe-key cycle. Persisted for the keyboard; edited from
    /// the app's language sheet.
    private(set) var selectedLocales: [String]

    var locale: Locale { Locale(identifier: localeIdentifier) }

    var localeName: String { Self.name(for: localeIdentifier) }

    /// Display name for a supported locale id.
    static func name(for identifier: String) -> String {
        supportedLocales.first { $0.id == identifier }?.name ?? identifier
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
        selectedLocales = Self.normalized(
            AppGroup.defaults.stringArray(forKey: Key.selectedLocales) ?? [],
            current: current
        )
    }

    // MARK: - Persistence

    /// Writes both keys together so the two processes never observe a torn
    /// state (e.g. an active language missing from the cycle list).
    private func persist() {
        let defaults = AppGroup.defaults
        defaults.set(localeIdentifier, forKey: Key.locale)
        defaults.set(selectedLocales, forKey: Key.selectedLocales)
    }

    /// Builds a valid selected list from raw persisted ids: only supported
    /// languages, `current` first (so capping can never drop the active
    /// language), at most `maxLanguages` long. Falls back to the defaults
    /// when nothing usable was saved.
    private static func normalized(_ raw: [String], current: String) -> [String] {
        var list = raw.filter { id in supportedLocales.contains(where: { $0.id == id }) }
        if list.isEmpty {
            list = ["en-US", "zh-CN"]
        }
        list.removeAll { $0 == current }
        list.insert(current, at: 0)
        if list.count > Self.maxLanguages {
            list = Array(list.prefix(Self.maxLanguages))
        }
        return list
    }

    // MARK: - Selection (the app's language sheet)

    /// Makes a SELECTED language the ACTIVE one — used by the sheet's
    /// "Your languages" group, where tapping a row activates it.
    /// Membership is unchanged; the list stays active-first. No-op if
    /// `identifier` isn't selected (or is already active).
    func activate(_ identifier: String) {
        guard identifier != localeIdentifier,
              selectedLocales.contains(identifier),
              Self.supportedLocales.contains(where: { $0.id == identifier }) else { return }
        var list = selectedLocales
        list.removeAll { $0 == identifier }
        list.insert(identifier, at: 0)
        localeIdentifier = identifier
        selectedLocales = list
        persist()
    }

    /// Adds a language to the selection WITHOUT touching the ACTIVE one —
    /// used by the sheet's "All languages" group, where a tap adds a
    /// language to "Your languages". When `maxLanguages` are already
    /// selected the LAST one (never the active, which stays first) is
    /// dropped to make room. No-op if already selected or unsupported.
    func add(_ identifier: String) {
        guard !selectedLocales.contains(identifier),
              Self.supportedLocales.contains(where: { $0.id == identifier }) else { return }
        var list = selectedLocales
        if list.count >= Self.maxLanguages {
            list.removeLast() // drop the trailing (non-active) one
        }
        list.append(identifier)
        selectedLocales = list
        persist()
    }

    /// Removes a language from the selection. If it was the active language,
    /// the remaining one becomes active. The last remaining language cannot
    /// be removed (dictation needs at least one). Returns whether it was
    /// removed.
    @discardableResult
    func deselect(_ identifier: String) -> Bool {
        guard selectedLocales.contains(identifier),
              selectedLocales.count > 1 else { return false }
        var list = selectedLocales
        list.removeAll { $0 == identifier }
        if identifier == localeIdentifier {
            localeIdentifier = list[0]
        }
        selectedLocales = list
        persist()
        return true
    }

    // MARK: - Keyboard globe cycle

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

    /// Moves to the next language in the SELECTED cycle (the keyboard's
    /// globe key). The list is a ring ordered active-first; each tap rotates
    /// the ring so the next language takes the lead — with several selected,
    /// repeated taps walk through ALL of them and wrap around. With one
    /// selected it stays put.
    func cycleToNextLocale() {
        guard selectedLocales.count > 1,
              let idx = selectedLocales.firstIndex(of: localeIdentifier) else { return }
        let count = selectedLocales.count
        // Ring rotation: the successor of the current active leads the new
        // list and the relative order is preserved (the list always ends
        // active-first again).
        let rotate = (idx + 1) % count
        let next = selectedLocales[rotate]
        localeIdentifier = next
        if rotate != 0 {
            selectedLocales = Array(selectedLocales[rotate...]) + Array(selectedLocales[..<rotate])
        }
        persist()
    }

    // MARK: - Cross-process sync

    /// Re-reads the persisted values — e.g. after the keyboard extension
    /// changed them in another process. Normalizes (caps the list, keeps the
    /// active language first) and no-ops when nothing changed.
    func reloadFromDefaults() {
        let defaults = AppGroup.defaults
        var changed = false

        if let saved = defaults.string(forKey: Key.locale),
           saved != localeIdentifier,
           Self.supportedLocales.contains(where: { $0.id == saved }) {
            localeIdentifier = saved
            changed = true
        }

        if let saved = defaults.stringArray(forKey: Key.selectedLocales) {
            let fixed = Self.normalized(saved, current: localeIdentifier)
            if fixed != selectedLocales {
                selectedLocales = fixed
                changed = true
            }
        }

        if changed {
            // Self-heal: write the canonical form back (e.g. an oversized
            // list left over from an older build with many enabled
            // languages).
            persist()
        }
    }
}
