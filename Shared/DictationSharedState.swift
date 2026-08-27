import Foundation

/// The shared dictation state machine, written by the container app and
/// read by the keyboard through the App Group defaults.
///
/// Ownership: the APP owns audio capture + recognition. The KEYBOARD only
/// requests sessions and observes. Handshake:
///
///   keyboard →  .requested + token        (then waits/polls)
///   app      →  .recording  + liveText    (streams partials + level)
///   app      →  .transcribing             (stop was requested, finalizing)
///   app      →  .ready      + finalText   (keyboard inserts once, then clears)
///   app      →  .failed     + errorMessage
///
/// The keyboard requests stop/cancel by setting `stopRequested` /
/// `cancelRequested` and pinging a Darwin notification.
enum DictationSharedState {

    enum Status: String {
        case idle
        case requested
        case recording
        case transcribing
        case ready
        case failed
    }

    enum Key {
        static let status = "dictation.status"
        static let sessionToken = "dictation.sessionToken"
        static let liveText = "dictation.liveText"
        static let finalText = "dictation.finalText"
        static let errorMessage = "dictation.errorMessage"
        static let audioLevel = "dictation.audioLevel"
        static let stopRequested = "dictation.stopRequested"
        static let cancelRequested = "dictation.cancelRequested"
        static let lastActivity = "dictation.lastActivity"
        static let isColdStart = "dictation.isColdStart"
    }

    // MARK: - Reads

    static func status(_ defaults: UserDefaults = AppGroup.defaults) -> Status {
        Status(rawValue: defaults.string(forKey: Key.status) ?? "") ?? .idle
    }

    static func sessionToken(_ defaults: UserDefaults = AppGroup.defaults) -> String {
        defaults.string(forKey: Key.sessionToken) ?? ""
    }

    static func liveText(_ defaults: UserDefaults = AppGroup.defaults) -> String {
        defaults.string(forKey: Key.liveText) ?? ""
    }

    static func finalText(_ defaults: UserDefaults = AppGroup.defaults) -> String {
        defaults.string(forKey: Key.finalText) ?? ""
    }

    static func errorMessage(_ defaults: UserDefaults = AppGroup.defaults) -> String {
        defaults.string(forKey: Key.errorMessage) ?? ""
    }

    static func audioLevel(_ defaults: UserDefaults = AppGroup.defaults) -> Float {
        defaults.float(forKey: Key.audioLevel)
    }

    static var lastActivityDate: Date? {
        let interval = AppGroup.defaults.double(forKey: Key.lastActivity)
        return interval > 0 ? Date(timeIntervalSinceReferenceDate: interval) : nil
    }

    static func wantsStop(_ defaults: UserDefaults = AppGroup.defaults) -> Bool {
        defaults.bool(forKey: Key.stopRequested)
    }

    static func wantsCancel(_ defaults: UserDefaults = AppGroup.defaults) -> Bool {
        defaults.bool(forKey: Key.cancelRequested)
    }

    // MARK: - Writes

    /// Clears session payloads (but keeps the token so the handshake isn't
    /// torn down mid-flight).
    static func clearPayload(defaults: UserDefaults = AppGroup.defaults) {
        defaults.removeObject(forKey: Key.liveText)
        defaults.removeObject(forKey: Key.finalText)
        defaults.removeObject(forKey: Key.errorMessage)
        defaults.removeObject(forKey: Key.audioLevel)
        defaults.set(false, forKey: Key.stopRequested)
        defaults.set(false, forKey: Key.cancelRequested)
    }

    /// Full reset of the shared state (end of a session).
    static func reset(defaults: UserDefaults = AppGroup.defaults) {
        defaults.removeObject(forKey: Key.status)
        defaults.removeObject(forKey: Key.sessionToken)
        defaults.removeObject(forKey: Key.liveText)
        defaults.removeObject(forKey: Key.finalText)
        defaults.removeObject(forKey: Key.errorMessage)
        defaults.removeObject(forKey: Key.audioLevel)
        defaults.set(false, forKey: Key.stopRequested)
        defaults.set(false, forKey: Key.cancelRequested)
        defaults.removeObject(forKey: Key.lastActivity)
        defaults.removeObject(forKey: Key.isColdStart)
    }

    static func setStatus(_ status: Status, defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(status.rawValue, forKey: Key.status)
        touchActivity(defaults: defaults)
    }

    static func touchActivity(defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(Date.timeIntervalSinceReferenceDate, forKey: Key.lastActivity)
    }
}
