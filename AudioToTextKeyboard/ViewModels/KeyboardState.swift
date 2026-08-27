import AVFoundation
import Foundation
import Speech
import UIKit

/// Drives the keyboard extension UI. Records audio and performs on-device
/// speech recognition IN THIS PROCESS (Full Access is required for the
/// microphone) and inserts the final text into the host app. The container
/// app is not involved — no App Group, no Darwin notifications, nothing to
/// cold-launch. This is the robust design used by shipping dictation
/// keyboards (Gboard, SwiftKey, …).
@MainActor
final class KeyboardState: ObservableObject {

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case transcribing
        case ready
        case failed(String)
    }

    // MARK: - Published state

    @Published var phase: Phase = .idle
    @Published var liveTranscript = ""
    @Published var audioLevel: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var hasFullAccess = false

    // MARK: - Private state

    private weak var controller: KeyboardViewController?
    private let captureService = AudioCaptureService()
    private let speechService = SpeechRecognitionService()
    private var smoothedLevel: Float = 0
    private var finalizedSegments: [String] = []
    private var isFinishing = false
    private var sessionGeneration = 0
    private var elapsedTimer: Timer?
    private var startTime: Date?
    private var finishWatchdog: Task<Void, Never>?

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    deinit {
        elapsedTimer?.invalidate()
        finishWatchdog?.cancel()
    }

    // MARK: - Public API

    func refreshFullAccessStatus() {
        hasFullAccess = controller?.hasFullAccess ?? false
    }

    func startDictation() {
        switch phase {
        case .idle, .failed:
            break
        default:
            return
        }

        // Full Access is required for the keyboard extension to access the
        // microphone. The banner in `KeyboardView` explains how to enable it
        // (requestOpenAccess was removed in the iOS 26 SDK — enabling happens
        // in Settings).
        guard hasFullAccess else { return }

        sessionGeneration += 1
        let generation = sessionGeneration
        phase = .starting
        Task {
            await beginSession(generation: generation)
        }
    }

    func stopDictation() {
        switch phase {
        case .recording:
            isFinishing = true
            phase = .transcribing
            captureService.stop()
            speechService.finishSession()

            // Watchdog: if the recognizer never reports a final result,
            // publish whatever we have after a few seconds.
            finishWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                self.publishFinal()
            }
        case .starting:
            // Permission prompt still up — stand down.
            cancelDictation()
        default:
            break
        }
    }

    func cancelDictation() {
        finishWatchdog?.cancel()
        captureService.stop()
        speechService.cancelSession()
        resetToIdle()
    }

    // MARK: - Keyboard actions (delegate to the controller)

    func insertText(_ text: String) {
        controller?.insertText(text)
    }

    func deleteBackward() {
        controller?.deleteBackward()
    }

    func switchToNextKeyboard() {
        controller?.switchToNextInputMode()
    }

    // MARK: - Session

    private func beginSession(generation: Int) async {
        let micGranted = await Self.requestMicrophonePermission()
        let speechGranted = await Self.requestSpeechPermission()
        guard micGranted && speechGranted else {
            guard generation == sessionGeneration else { return }
            fail("Microphone or speech recognition access was denied. Enable both in Settings → Privacy, then try again.")
            return
        }
        // The user may have cancelled (or failed/restarted) while the
        // permission prompts were up — stand down if the session is stale.
        guard generation == sessionGeneration, phase == .starting else { return }

        do {
            finalizedSegments = []
            isFinishing = false
            try speechService.startSession()
            try captureService.start()
            wireCallbacks()
            phase = .recording
            startElapsedTimer()
        } catch {
            speechService.cancelSession()
            captureService.stop()
            fail(error.localizedDescription)
        }
    }

    /// Inserts the accumulated text into the host app and returns to idle.
    private func publishFinal() {
        guard isFinishing else { return }
        finishWatchdog?.cancel()
        stopElapsedTimer()
        let text = (finalizedSegments + [liveTranscript])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            resetToIdle()
            return
        }
        phase = .ready
        controller?.insertText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .ready else { return }
                self.resetToIdle()
            }
        }
    }

    // MARK: - Service wiring

    private func wireCallbacks() {
        speechService.onTranscriptUpdate = { [weak self] text in
            guard let self else { return }
            self.liveTranscript = text
            if self.isFinishing {
                self.phase = .transcribing
            }
        }
        speechService.onSegmentFinalized = { [weak self] text in
            guard let self else { return }
            self.finalizedSegments.append(text)
            self.liveTranscript = ""
            if self.isFinishing {
                self.publishFinal()
            }
        }
        speechService.onError = { [weak self] message in
            guard let self else { return }
            if self.isFinishing {
                // Error while finalizing — publish what we have.
                self.publishFinal()
            } else {
                self.fail(message)
            }
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
            // E.g. an incoming call. Wind the session down cleanly.
            self?.stopDictation()
        }
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        finishWatchdog?.cancel()
        stopElapsedTimer()
        captureService.stop()
        speechService.cancelSession()
        phase = .failed(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            Task { @MainActor in
                guard let self, case .failed = self.phase else { return }
                self.resetToIdle()
            }
        }
    }

    private func resetToIdle() {
        sessionGeneration += 1
        finishWatchdog?.cancel()
        stopElapsedTimer()
        isFinishing = false
        finalizedSegments = []
        liveTranscript = ""
        audioLevel = 0
        elapsed = 0
        phase = .idle
    }

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
