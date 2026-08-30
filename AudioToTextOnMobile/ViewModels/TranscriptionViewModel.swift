import AVFoundation
import Foundation
import Observation
import Speech

/// The app's main state container. It drives a session through the shared
/// `KeyboardDictationCoordinator` — the SINGLE owner of capture + recognition —
/// so the process never runs two audio engines. A second `AVAudioEngine`
/// sharing the `AVAudioSession` deactivates the always-armed engine and
/// silently breaks background dictation until a restart, so the app's own UI
/// must ride the same engine the keyboard uses.
@MainActor
@Observable
final class TranscriptionViewModel {

    // MARK: - UI state

    enum RecordingState: Equatable {
        case idle
        case requestingPermission
        case ready
        case recording
        case failed(String)
    }

    /// Who drives the current session. While a keyboard session is live the
    /// main screen shows it directly (waveform + transcript + controls) —
    /// there is no separate dictation overlay anymore.
    enum SessionMode: Equatable {
        case none
        case app
        case keyboard
    }

    // MARK: - Published state

    private(set) var isOnDevice = true

    private let coordinator = KeyboardDictationCoordinator.shared

    // MARK: - Init

    init() {
        // supportsOnDevice is computed from the recognizer at init; a
        // throwaway instance is safe (no session is started on it).
        isOnDevice = SpeechRecognitionService(locale: Locale(identifier: "en-US")).supportsOnDevice
    }

    // MARK: - Session state (bound to the coordinator)

    var liveTranscript: String { coordinator.liveText }
    var finalizedSegments: [String] { coordinator.finalizedSegments }
    var finalText: String { coordinator.finalText }
    var audioLevel: Float { coordinator.audioLevel }

    var sessionMode: SessionMode {
        guard coordinator.isActive else { return .none }
        return coordinator.isAppSession ? .app : .keyboard
    }

    var isKeyboardSession: Bool { sessionMode == .keyboard }

    /// True while the recognizer is wrapping up (`.transcribing`).
    var isFinalizing: Bool { coordinator.status == .transcribing }

    /// The single result of a finished keyboard session (`.ready`), shown as
    /// the transcript until the user dismisses it.
    var readyDisplayText: String? {
        guard isKeyboardSession, state == .ready, !coordinator.finalText.isEmpty else { return nil }
        return coordinator.finalText
    }

    /// Transient "asking the system for permission" indicator.
    private var isStarting = false

    var state: RecordingState {
        if isStarting { return .requestingPermission }
        switch coordinator.status {
        case .recording: return .recording
        case .failed: return .failed(coordinator.errorMessage ?? "Dictation failed.")
        case .ready, .transcribing: return .ready
        case .idle, .requested: return .idle
        }
    }

    // MARK: - User actions

    /// Toggles recording, or retries after a failure.
    func toggleRecording() {
        switch (sessionMode, state) {
        case (_, .requestingPermission):
            break
        case (.keyboard, .recording):
            coordinator.beginFinish()
        case (.keyboard, .ready):
            coordinator.dismissReady()
        case (_, .recording):
            stopRecording()
        case (_, .failed), (_, .idle), (_, .ready):
            startRecording()
        }
    }

    /// Stops recording and clears the transcript history.
    func clearSession() {
        if coordinator.isAppSession {
            coordinator.stopAppSession()
        }
        coordinator.clearAppTranscript()
    }

    // MARK: - Keyboard sessions (adopted via the shared protocol)

    /// Stop a live keyboard session (the user tapped stop while the app is
    /// in front — the text is finalized and inserted by the keyboard).
    func stopKeyboardSession() {
        guard isKeyboardSession, coordinator.status == .recording else { return }
        coordinator.beginFinish()
    }

    /// Cancel a live keyboard session (the user tapped ✕).
    func cancelKeyboardSession() {
        guard isKeyboardSession else { return }
        coordinator.cancelSession()
    }

    /// Dismiss the "complete" state of a keyboard session. The shared
    /// result is left in place for the keyboard to insert on return.
    func dismissKeyboardReady() {
        guard isKeyboardSession, coordinator.status == .ready else { return }
        coordinator.dismissReady()
    }

    // MARK: - Recording

    private func startRecording() {
        guard coordinator.canStartAppSession else { return }
        isStarting = true
        coordinator.startAppSession()
        // startAppSession sets the status synchronously; the async permission
        // + engine start resolves within a moment. Give it a beat before
        // clearing the "requesting permission" indicator.
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            isStarting = false
        }
    }

    private func stopRecording() {
        guard coordinator.isAppSession else { return }
        coordinator.stopAppSession()
    }
}
