import AVFoundation
import Foundation
import Observation
import Speech

/// The app's main state container: orchestrates microphone capture and
/// on-device speech recognition, and exposes everything the UI needs.
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

    private(set) var state: RecordingState = .idle
    private(set) var liveTranscript = ""
    private(set) var finalizedSegments: [String] = []
    private(set) var audioLevel: Float = 0
    private(set) var isOnDevice = true

    // MARK: - Services

    private let captureService: AudioCaptureService
    private let speechService: SpeechRecognitionService
    private var smoothedLevel: Float = 0

    // MARK: - Init

    init(locale: Locale = Locale(identifier: "en-US")) {
        captureService = AudioCaptureService()
        speechService = SpeechRecognitionService(locale: locale)
        isOnDevice = speechService.supportsOnDevice
        wireCallbacks()
    }

    // MARK: - User actions

    /// Toggles recording, or retries after a failure.
    func toggleRecording() {
        switch state {
        case .recording:
            stopRecording()
        case .requestingPermission:
            break
        case .failed:
            state = .idle
            startRecording()
        default:
            startRecording()
        }
    }

    /// Stops recording and clears the transcript history.
    func clearSession() {
        if state == .recording {
            stopRecording()
        }
        finalizedSegments = []
        liveTranscript = ""
        audioLevel = 0
        smoothedLevel = 0
        state = .ready
    }

    // MARK: - Recording

    private func startRecording() {
        state = .requestingPermission
        Task {
            await beginRecording()
        }
    }

    private func beginRecording() async {
        do {
            let micGranted = await Self.requestMicrophonePermission()
            let speechGranted = await Self.requestSpeechPermission()

            guard micGranted && speechGranted else {
                state = .failed("Microphone or speech recognition access was denied. You can enable both in Settings → Privacy.")
                return
            }

            try speechService.startSession()
            try captureService.start()

            liveTranscript = ""
            state = .recording
        } catch {
            speechService.cancelSession()
            captureService.stop()
            state = .failed(error.localizedDescription)
        }
    }

    private func stopRecording() {
        guard state == .recording else { return }
        captureService.stop()
        speechService.finishSession()
        state = .ready
    }

    // MARK: - Service wiring

    private func wireCallbacks() {
        speechService.onTranscriptUpdate = { [weak self] text in
            self?.liveTranscript = text
        }
        speechService.onSegmentFinalized = { [weak self] text in
            guard let self else { return }
            self.finalizedSegments.append(text)
            self.liveTranscript = ""
        }
        speechService.onError = { [weak self] message in
            guard let self else { return }
            self.captureService.stop()
            self.speechService.cancelSession()
            self.liveTranscript = ""
            self.state = .failed(message)
        }
        captureService.onBuffer = { [weak self] buffer in
            self?.speechService.append(buffer)
        }
        captureService.onLevel = { [weak self] level in
            guard let self else { return }
            // Attack/release smoothing for a lively waveform.
            let attack: Float = level > self.smoothedLevel ? 0.55 : 0.2
            self.smoothedLevel += (level - self.smoothedLevel) * attack
            self.audioLevel = self.smoothedLevel
        }
        captureService.onInterruption = { [weak self] in
            self?.stopRecording()
        }
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
