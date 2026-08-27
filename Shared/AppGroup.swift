import Foundation

/// Shared container between the container app and the keyboard extension.
///
/// Both targets must carry the `com.apple.security.application-groups`
/// entitlement with this identifier. When the group is unavailable (an
/// unsigned build, a simulator build without entitlements, or Full Access
/// disabled for the keyboard), all access falls back to an isolated,
/// non-shared suite so nothing crashes — the feature simply degrades to
/// "not connected".
enum AppGroup {
    static let identifier = "group.com.example.AudioToTextOnMobile"

    /// Whether the shared container actually exists for this process.
    /// `false` on unsigned builds and on simulator builds where entitlements
    /// were not applied.
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }

    /// Suite-scoped defaults shared by both processes.
    ///
    /// IMPORTANT: never touch `UserDefaults(suiteName: identifier)` while the
    /// group is missing. cfprefsd then logs
    /// "Couldn't read values in CFPrefsPlistSource … Using kCFPreferencesAnyUser
    /// with a container is only allowed for System Containers, detaching from
    /// cfprefsd" and the process can be killed.
    ///
    /// Also do NOT use a `group.`-prefixed fallback suite name: cfprefsd treats
    /// any suite whose name starts with `group.` as an App Group container, so
    /// the fallback would hit the same fatal lookup. Use an ordinary,
    /// process-local suite name instead.
    static var defaults: UserDefaults {
        if isAvailable, let suite = UserDefaults(suiteName: identifier) {
            return suite
        }
        // Local-only suite in this process's own container: fully functional,
        // just not shared with the other process.
        if let fallback = UserDefaults(suiteName: "com.example.AudioToTextOnMobile.local") {
            return fallback
        }
        return .standard
    }

    /// The shared container directory (reserved for larger payloads later).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
