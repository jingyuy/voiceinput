import Foundation

/// Lifecycle of a dictation session, as seen by both processes.
///
/// The keyboard writes `requested` and reads the rest; the container app
/// owns everything from `recording` onward.
enum DictationStatus: String, Codable {
    case idle
    case requested      // keyboard asked the app to start
    case recording      // app is capturing + recognizing
    case transcribing   // app is finalizing the final result
    case ready          // final text is available in `finalText`
    case failed         // `errorMessage` explains why
}

/// Keys in the App Group `UserDefaults` suite.
enum DictationKey {
    static let sessionToken   = "dictation.sessionToken"
    static let status         = "dictation.status"
    static let liveTranscript = "dictation.liveTranscript"
    static let finalText      = "dictation.finalText"
    static let audioLevel     = "dictation.audioLevel"
    static let errorMessage   = "dictation.errorMessage"
    static let lastUpdatedAt  = "dictation.lastUpdatedAt"
}

/// The custom URL scheme used to cold-launch the container app from the keyboard.
enum DictationURL {
    static let scheme = "attotext"
    static let dictate = URL(string: "attotext://dictate?source=keyboard")!
    static let settings = URL(string: "attotext://settings")!
}

/// Typed read/write helpers over the shared suite.
///
/// Every `status` write also stamps `lastUpdatedAt` so either side can run
/// watchdogs against a stale session.
enum DictationSharedState {
    static var sessionToken: String? {
        get { AppGroup.defaults.string(forKey: DictationKey.sessionToken) }
        set { AppGroup.defaults.set(newValue, forKey: DictationKey.sessionToken) }
    }

    static var status: DictationStatus {
        get {
            guard let raw = AppGroup.defaults.string(forKey: DictationKey.status),
                  let status = DictationStatus(rawValue: raw) else { return .idle }
            return status
        }
        set {
            AppGroup.defaults.set(newValue.rawValue, forKey: DictationKey.status)
            AppGroup.defaults.set(Date().timeIntervalSince1970, forKey: DictationKey.lastUpdatedAt)
        }
    }

    static var liveTranscript: String {
        get { AppGroup.defaults.string(forKey: DictationKey.liveTranscript) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: DictationKey.liveTranscript) }
    }

    static var finalText: String {
        get { AppGroup.defaults.string(forKey: DictationKey.finalText) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: DictationKey.finalText) }
    }

    static var audioLevel: Double {
        get { AppGroup.defaults.double(forKey: DictationKey.audioLevel) }
        set { AppGroup.defaults.set(newValue, forKey: DictationKey.audioLevel) }
    }

    static var errorMessage: String {
        get { AppGroup.defaults.string(forKey: DictationKey.errorMessage) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: DictationKey.errorMessage) }
    }

    static var lastUpdatedAt: TimeInterval {
        AppGroup.defaults.double(forKey: DictationKey.lastUpdatedAt)
    }
}
