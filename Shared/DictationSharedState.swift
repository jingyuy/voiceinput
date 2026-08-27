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
        /// App-only liveness marker: written ONLY by the container app
        /// (armed engine, session loop, ping). The keyboard reads it to
        /// decide Darwin-wake vs cold-launch and to detect app death fast.
        static let appHeartbeat = "dictation.appHeartbeat"
        /// Timestamp (ref date) when the app published `.ready` — the
        /// keyboard's freshness gate for auto-inserting a result.
        static let readyAt = "dictation.readyAt"
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

    /// App-only liveness. Nil means the app has never (or not recently)
    /// written a heartbeat.
    static var appHeartbeatDate: Date? {
        let interval = AppGroup.defaults.double(forKey: Key.appHeartbeat)
        return interval > 0 ? Date(timeIntervalSinceReferenceDate: interval) : nil
    }

    /// When the app published the current `.ready` result.
    static var readyAtDate: Date? {
        let interval = AppGroup.defaults.double(forKey: Key.readyAt)
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
        defaults.removeObject(forKey: Key.readyAt)
        defaults.removeObject(forKey: Key.errorMessage)
        defaults.removeObject(forKey: Key.audioLevel)
        defaults.set(false, forKey: Key.stopRequested)
        defaults.set(false, forKey: Key.cancelRequested)
    }

    /// Removes a consumed (or expired) final result.
    static func clearFinalResult(defaults: UserDefaults = AppGroup.defaults) {
        defaults.removeObject(forKey: Key.finalText)
        defaults.removeObject(forKey: Key.readyAt)
    }

    /// Full reset of the shared state (end of a session).
    static func reset(defaults: UserDefaults = AppGroup.defaults) {
        defaults.removeObject(forKey: Key.status)
        defaults.removeObject(forKey: Key.sessionToken)
        defaults.removeObject(forKey: Key.liveText)
        defaults.removeObject(forKey: Key.finalText)
        defaults.removeObject(forKey: Key.readyAt)
        defaults.removeObject(forKey: Key.errorMessage)
        defaults.removeObject(forKey: Key.audioLevel)
        defaults.set(false, forKey: Key.stopRequested)
        defaults.set(false, forKey: Key.cancelRequested)
        defaults.removeObject(forKey: Key.lastActivity)
        defaults.removeObject(forKey: Key.isColdStart)
        defaults.removeObject(forKey: Key.appHeartbeat)
    }

    /// Writes the app-only liveness marker. The keyboard must NEVER call
    /// this — it is the app's "I'm alive AND can serve" signal.
    static func touchAppHeartbeat(defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(Date.timeIntervalSinceReferenceDate, forKey: Key.appHeartbeat)
    }

    static func setStatus(_ status: Status, defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(status.rawValue, forKey: Key.status)
        touchActivity(defaults: defaults)
    }

    static func touchActivity(defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(Date.timeIntervalSinceReferenceDate, forKey: Key.lastActivity)
    }
}
