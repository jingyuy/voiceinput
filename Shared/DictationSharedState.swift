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
/// The keyboard requests stop/cancel by writing the target session's token
/// into `stopFor` / `cancelFor` and pinging a Darwin notification. The app
/// only honors a flag that names the session it is currently serving.
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
        /// Session-ID-tagged control flags (KEYBOARD-only writer). The app
        /// only honors a flag whose value equals the session it is serving,
        /// so a stale flag from a dead session can never kill a new one.
        static let stopFor = "dictation.stopFor"
        static let cancelFor = "dictation.cancelFor"
        /// The keyboard's OWN clock when it wrote the current `.requested`
        /// (KEYBOARD-only writer). Both sides use it for freshness — unlike
        /// `lastActivity`, a wedged app cannot keep it alive.
        static let requestedAt = "dictation.requestedAt"
        /// Keyboard presence: touched while the keyboard is polling a live
        /// session (KEYBOARD-only writer). The app finalizes a backgrounded
        /// session whose keyboard has been gone for a while — this is what
        /// ends orphan sessions (keyboard died / user left) instead of
        /// letting them record forever.
        static let keyboardAliveAt = "dictation.keyboardAliveAt"
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

    /// When the keyboard wrote the current `.requested` (the keyboard's OWN
    /// clock — the app cannot refresh it, so it is a trustworthy timeout).
    static func requestedAtDate(_ defaults: UserDefaults = AppGroup.defaults) -> Date? {
        let interval = defaults.double(forKey: Key.requestedAt)
        return interval > 0 ? Date(timeIntervalSinceReferenceDate: interval) : nil
    }

    /// When the keyboard last polled a live session (keyboard presence).
    static func keyboardAliveAtDate(_ defaults: UserDefaults = AppGroup.defaults) -> Date? {
        let interval = defaults.double(forKey: Key.keyboardAliveAt)
        return interval > 0 ? Date(timeIntervalSinceReferenceDate: interval) : nil
    }

    /// True when the keyboard hasn't polled for `threshold` seconds — i.e.
    /// nobody is listening to the current session.
    static func keyboardPresenceStale(_ threshold: TimeInterval,
                                      defaults: UserDefaults = AppGroup.defaults) -> Bool {
        guard let date = keyboardAliveAtDate(defaults) else { return true }
        return Date().timeIntervalSince(date) > threshold
    }

    /// True when the keyboard asked the app to finalize session `token`.
    static func stopRequested(for token: String,
                              defaults: UserDefaults = AppGroup.defaults) -> Bool {
        guard !token.isEmpty else { return false }
        return defaults.string(forKey: Key.stopFor) == token
    }

    /// True when the keyboard asked the app to cancel session `token`.
    static func cancelRequested(for token: String,
                                defaults: UserDefaults = AppGroup.defaults) -> Bool {
        guard !token.isEmpty else { return false }
        return defaults.string(forKey: Key.cancelFor) == token
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
        defaults.removeObject(forKey: Key.stopFor)
        defaults.removeObject(forKey: Key.cancelFor)
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
        defaults.removeObject(forKey: Key.stopFor)
        defaults.removeObject(forKey: Key.cancelFor)
        defaults.removeObject(forKey: Key.requestedAt)
        defaults.removeObject(forKey: Key.keyboardAliveAt)
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

    /// The keyboard asks the app to finalize (stop) session `token`.
    static func requestStop(for token: String, defaults: UserDefaults = AppGroup.defaults) {
        guard !token.isEmpty else { return }
        defaults.set(token, forKey: Key.stopFor)
    }

    /// The keyboard asks the app to cancel (abort) session `token`.
    static func requestCancel(for token: String, defaults: UserDefaults = AppGroup.defaults) {
        guard !token.isEmpty else { return }
        defaults.set(token, forKey: Key.cancelFor)
    }

    /// The keyboard marks itself present (it is polling a live session).
    static func touchKeyboardPresence(defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(Date.timeIntervalSinceReferenceDate, forKey: Key.keyboardAliveAt)
    }
}
