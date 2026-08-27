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
    var audioLevel: Float { coordinator.audioLevel }

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
        switch state {
        case .recording:
            stopRecording()
        case .requestingPermission:
            break
        case .failed, .idle, .ready:
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
