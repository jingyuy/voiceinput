import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// Owns dictation sessions requested by the keyboard extension.
///
/// The keyboard cannot access the microphone, so the **container app** performs
/// all capture + on-device recognition. This coordinator:
///   - listens for Darwin pings from the keyboard (warm start),
///   - handles `attotext://dictate` URLs (cold start),
///   - mirrors session state into the App Group for the keyboard to read.
///
/// The in-app `TranscriptionViewModel` is untouched; the two paths share the
/// same low-level services but never run at the same time (a keyboard session
/// only starts while the user is in another app).
@MainActor
@Observable
final class KeyboardDictationCoordinator {

    static let shared = KeyboardDictationCoordinator()

    // MARK: - Published state

    /// A keyboard-requested session is running right now.
    private(set) var isActive = false
    /// The app was cold-launched by the keyboard; the UI shows the return overlay.
    var isColdStart = false
    private(set) var liveTranscript = ""
    private(set) var audioLevel: Float = 0
    private(set) var errorMessage: String?
    private(set) var elapsed: TimeInterval = 0

    // MARK: - Private state

    private let captureService = AudioCaptureService()
    private let speechService = SpeechRecognitionService()
    private var observers: [DarwinNotificationObserver] = []
    private var smoothedLevel: Float = 0
    private var finalizedSegments: [String] = []
    private var isFinishing = false
    private var finishWatchdog: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var startTime: Date?

    private init() {
        observers = [
            DarwinNotifications.observe(.recordingRequested) { [weak self] in
                Task { @MainActor in self?.handleRecordingRequested() }
            },
            DarwinNotifications.observe(.stopRequested) { [weak self] in
                Task { @MainActor in self?.handleStopRequested() }
            },
            DarwinNotifications.observe(.cancelRequested) { [weak self] in
                Task { @MainActor in self?.handleCancelRequested() }
            },
        ]
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleBecameActive() }
        }
    }

    // MARK: - Entry points

    /// Called from `.onOpenURL` when the keyboard cold-launches the app.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == DictationURL.scheme else { return }
        switch url.host {
        case "dictate":
            isColdStart = true
            startKeyboardSession()
        case "settings":
            // Onboarding entry; no session. The main UI shows instead.
            isColdStart = false
        default:
            break
        }
    }

    private func handleRecordingRequested() {
        guard !isActive else { return }
        startKeyboardSession()
    }

    private func handleStopRequested() {
        stopKeyboardSession()
    }

    private func handleCancelRequested() {
        cancelKeyboardSession()
    }

    /// Clears stale state left behind by a crashed or interrupted session,
    /// so a later plain app launch never auto-starts recording.
    private func handleBecameActive() {
        guard !isActive else { return }
        if DictationSharedState.status != .idle,
           Date().timeIntervalSince1970 - DictationSharedState.lastUpdatedAt > 10 {
            DictationSharedState.status = .idle
        }
    }

    // MARK: - Session control

    private func startKeyboardSession() {
        guard !isActive else { return }
        isActive = true
        isFinishing = false
        errorMessage = nil
        finalizedSegments = []
        liveTranscript = ""
        DictationSharedState.liveTranscript = ""
        DictationSharedState.finalText = ""
        DictationSharedState.errorMessage = ""
        DictationSharedState.status = .requested

        Task {
            let micGranted = await Self.requestMicrophonePermission()
            let speechGranted = await Self.requestSpeechPermission()
            guard micGranted && speechGranted else {
                fail("Microphone or speech recognition access was denied. Enable both in Settings → Privacy, then try again.")
                return
            }
            do {
                try speechService.startSession()
                try captureService.start()
                wireCallbacks()
                DictationSharedState.status = .recording
                startElapsedTimer()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Gracefully ends the session; the final result is published when the
    /// recognizer reports it (or by a watchdog).
    func stopKeyboardSession() {
        guard isActive, !isFinishing else { return }
        isFinishing = true
        DictationSharedState.status = .transcribing
        captureService.stop()
        speechService.finishSession()

        // Watchdog: if the recognizer never reports a final result, publish
        // whatever we have after a few seconds so the keyboard isn't stuck.
        finishWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.finishAndPublish()
        }
    }

    /// Immediately aborts the session; nothing is published.
    func cancelKeyboardSession() {
        finishWatchdog?.cancel()
        isFinishing = false
        captureService.stop()
        speechService.cancelSession()
        finalizedSegments = []
        liveTranscript = ""
        DictationSharedState.liveTranscript = ""
        DictationSharedState.status = .idle
        isActive = false
        stopElapsedTimer()
    }

    // MARK: - Finalization

    private func finishAndPublish() {
        finishWatchdog?.cancel()
        guard isActive else { return }
        stopElapsedTimer()
        DictationSharedState.finalText = fullText
        DictationSharedState.status = .ready
        isActive = false
        isFinishing = false
        DarwinNotifications.post(.transcriptionReady)
        // If the user already returned to their keyboard, don't show the
        // cold-start overlay when they next open the app.
        if UIApplication.shared.applicationState != .active {
            isColdStart = false
        }
    }

    private var fullText: String {
        let parts = finalizedSegments + [liveTranscript].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private func fail(_ message: String) {
        finishWatchdog?.cancel()
        captureService.stop()
        speechService.cancelSession()
        isActive = false
        isFinishing = false
        stopElapsedTimer()
        errorMessage = message
        DictationSharedState.errorMessage = message
        DictationSharedState.status = .failed
        DarwinNotifications.post(.statusChanged)
    }

    // MARK: - Service wiring

    private func wireCallbacks() {
        speechService.onTranscriptUpdate = { [weak self] text in
            // Ignore updates that arrive after the session ended so a late
            // callback can never overwrite `.ready`.
            guard let self, self.isActive else { return }
            self.liveTranscript = text
            DictationSharedState.liveTranscript = text
            DictationSharedState.status = self.isFinishing ? .transcribing : .recording
        }
        speechService.onSegmentFinalized = { [weak self] text in
            guard let self, self.isActive else { return }
            self.finalizedSegments.append(text)
            self.liveTranscript = ""
            DictationSharedState.liveTranscript = ""
            if self.isFinishing {
                self.finishAndPublish()
            }
        }
        speechService.onError = { [weak self] message in
            guard let self, self.isActive else { return }
            self.fail(message)
        }
        captureService.onBuffer = { [weak self] buffer in
            self?.speechService.append(buffer)
        }
        captureService.onLevel = { [weak self] level in
            guard let self else { return }
            let attack: Float = level > self.smoothedLevel ? 0.55 : 0.2
            self.smoothedLevel += (level - self.smoothedLevel) * attack
            self.audioLevel = self.smoothedLevel
            DictationSharedState.audioLevel = Double(self.smoothedLevel)
        }
        captureService.onInterruption = { [weak self] in
            // E.g. an incoming call. Wind the session down cleanly.
            self?.stopKeyboardSession()
        }
    }

    // MARK: - Elapsed time

    private func startElapsedTimer() {
        startTime = Date()
        elapsed = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startTime = self.startTime else { return }
                self.elapsed = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Permissions

    private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func requestSpeechPermission() async -> Bool {
        await SpeechRecognitionService.requestAuthorization()
    }
}
