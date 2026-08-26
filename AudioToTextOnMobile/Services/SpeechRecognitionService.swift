import AVFoundation
import Foundation
import Speech

/// Errors surfaced by `SpeechRecognitionService`.
enum SpeechRecognitionError: LocalizedError {
    case notSupported
    case busyOrUnavailable
    case onDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "Speech recognition is not supported on this device."
        case .busyOrUnavailable:
            return "The speech recognizer is busy, or the offline language pack is still downloading. Please try again in a moment."
        case .onDeviceUnavailable:
            return "On-device recognition is not available for this language on this device."
        }
    }
}

/// Streams microphone audio buffers into Apple's **on-device** speech
/// recognition engine and delivers partial transcriptions as they arrive.
///
/// - Audio buffers are appended via `append(_:)` (thread-safe).
/// - All callbacks are delivered on the main queue.
/// - Recognition runs entirely on the device — no audio ever leaves it.
final class SpeechRecognitionService {

    // MARK: - Callbacks (all on the main queue)

    /// Called on every partial transcription update ("" once a segment finalizes).
    var onTranscriptUpdate: ((String) -> Void)?

    /// Called when a complete utterance is finalized.
    var onSegmentFinalized: ((String) -> Void)?

    /// Called when the recognizer reports a non-cancellation error.
    var onError: ((String) -> Void)?

    // MARK: - Public state

    private(set) var isAvailable = false
    private(set) var supportsOnDevice = false

    // MARK: - Private state

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionToken = UUID()
    private var isCancelling = false

    // MARK: - Init

    init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
        recognizer?.supportsOnDeviceRecognition = true

        supportsOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        isAvailable = recognizer?.isAvailable ?? false
    }

    // MARK: - Session control

    /// Starts a new recognition session. Throws if on-device recognition
    /// cannot run right now.
    func startSession() throws {
        guard let recognizer else {
            throw SpeechRecognitionError.notSupported
        }
        guard recognizer.isAvailable else {
            throw SpeechRecognitionError.busyOrUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechRecognitionError.onDeviceUnavailable
        }

        // Gracefully wind down any previous session before starting a new one.
        finishSession()
        isCancelling = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        recognitionRequest = request

        // A token guards against stale callbacks from a previous session.
        sessionToken = UUID()
        let token = sessionToken

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, token == self.sessionToken else { return }

                if let result {
                    self.onTranscriptUpdate?(result.bestTranscription.formattedString)
                    if result.isFinal {
                        let text = result.bestTranscription.formattedString
                        if !text.isEmpty {
                            self.onSegmentFinalized?(text)
                        }
                        self.onTranscriptUpdate?("")
                        self.recognitionRequest = nil
                        self.recognitionTask = nil
                    }
                }

                if let error {
                    // A cancelled task reports an error too; swallow it.
                    guard !self.isCancelling else {
                        self.isCancelling = false
                        return
                    }
                    self.onError?(error.localizedDescription)
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                }
            }
        }
    }

    /// Appends a captured audio buffer to the active recognition session.
    /// Safe to call from any thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    /// Gracefully ends the session. The final utterance is delivered to
    /// `onSegmentFinalized` shortly after this returns.
    func finishSession() {
        recognitionTask?.finish()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
    }

    /// Immediately aborts the session; no final result is delivered.
    func cancelSession() {
        sessionToken = UUID()
        isCancelling = true
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    // MARK: - Authorization

    /// Requests speech recognition authorization.
    static func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return status == .authorized
    }
}
