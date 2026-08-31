import AVFoundation
import Foundation
import os
import Speech
import UIKit

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

    private static let logger = Logger(
        subsystem: "com.example.AudioToTextOnMobile.shared",
        category: "SpeechRecognition"
    )

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
    /// The locale the recognizer is currently configured for. Change it with
    /// `setLocale(_:)` — never mutate directly.
    private(set) var locale: Locale

    // MARK: - Private state

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionToken = UUID()
    private var isCancelling = false

    // MARK: - Init

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        rebuildRecognizer(locale: locale)
    }

    /// Switches the recognizer to a new locale. Winding down any in-flight
    /// session first is safe even mid-session (callers usually apply the
    /// locale while idle, right before a session starts).
    func setLocale(_ newLocale: Locale) {
        guard newLocale != locale else { return }
        finishSession()
        locale = newLocale
        rebuildRecognizer(locale: newLocale)
    }

    /// True when Apple's on-device recognizer supports the given locale on
    /// this device (the offline language pack is available or downloadable).
    static func supportsOnDevice(locale: Locale) -> Bool {
        let recognizer = SFSpeechRecognizer(locale: locale)
        recognizer?.supportsOnDeviceRecognition = true
        return recognizer?.supportsOnDeviceRecognition ?? false
    }

    private func rebuildRecognizer(locale: Locale) {
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
            Self.logger.error("startSession: recognizer is nil (locale en-US unsupported?)")
            throw SpeechRecognitionError.notSupported
        }
        guard recognizer.isAvailable else {
            Self.logger.error("startSession: recognizer unavailable isAvailable=false")
            throw SpeechRecognitionError.busyOrUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            Self.logger.error("startSession: on-device recognition unsupported")
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
                    Self.logger.error("recognitionTask error: \(Self.errorDetail(error))")
                    self.onError?(SpeechRecognitionService.errorDetail(error))
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

    /// Walks the NSError chain to the deepest cause and returns a compact
    /// "domain code" string. The full chain goes to the pasteboard too.
    static func errorDetail(_ error: Error) -> String {
        var chain: [NSError] = []
        var ns = error as NSError
        chain.append(ns)
        while let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying !== ns {
            chain.append(underlying)
            ns = underlying
        }
        let deepest = chain.last!
        let full = chain
            .map { "\($0.domain) code=\($0.code): \($0.localizedDescription)" }
            .joined(separator: "\n")
        UIPasteboard.general.string = full
        return "\(deepest.domain) code=\(deepest.code)"
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
