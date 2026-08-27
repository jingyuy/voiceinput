import Foundation

/// Cross-process storage for the dictation handoff (keyboard ↔ app).
///
/// The keyboard and the app share the `group.com.example.AudioToTextOnMobile`
/// container via `UserDefaults`. Because cfprefsd fatal-errors on ANY
/// "group."-prefixed suite name when the container isn't provisioned, always
/// check `isAvailable` first and fall back to a plain local suite.
enum AppGroup {
    static let suiteName = "group.com.example.AudioToTextOnMobile"
    private static let localSuiteName = "com.example.AudioToTextOnMobile.local"

    /// True when the App Group container actually exists on this device.
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil
    }

    /// The defaults instance to use. Prefers the shared group container;
    /// falls back to a local (non-group) suite so development builds still
    /// work without provisioning.
    static var defaults: UserDefaults {
        let name = isAvailable ? suiteName : localSuiteName
        return UserDefaults(suiteName: name) ?? .standard
    }
}
