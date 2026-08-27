import Foundation
import UIKit

/// Drives the keyboard extension UI. Talks to the container app over the
/// App Group + Darwin notifications; never touches the microphone itself.
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

    /// Injected by the SwiftUI root from `@Environment(\.openURL)`.
    /// Used to cold-launch the container app when it isn't running.
    var openURLHandler: ((URL) -> Void)?

    // MARK: - Private state

    private weak var controller: KeyboardViewController?
    private var pollTimer: Timer?
    private var elapsedTimer: Timer?
    private var startWatchdog: Timer?
    private var sessionToken: String?
    private var startTime: Date?

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    deinit {
        pollTimer?.invalidate()
        elapsedTimer?.invalidate()
        startWatchdog?.invalidate()
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

        // Full Access is required for the shared App Group container. The
        // banner in `KeyboardView` explains how to enable it (requestOpenAccess
        // was removed in the iOS 26 SDK — enabling happens in Settings).
        guard hasFullAccess else { return }

        // The shared container must actually exist. If it doesn't (unsigned
        // build, or the app was never launched once to provision the group),
        // touching the suite crashes cfprefsd — fail visibly instead.
        guard AppGroup.isAvailable else {
            fail("Dictation isn't connected. Open the Audio To Text app once, then retry.")
            return
        }
        startDictationSession()
    }

    func stopDictation() {
        switch phase {
        case .starting:
            // App never acknowledged — stand down entirely.
            cancelDictation()
        case .recording, .transcribing:
            startWatchdog?.invalidate()
            stopElapsedTimer()
            DarwinNotifications.post(.stopRequested)
            // Keep polling; the app will set .transcribing then .ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                Task { @MainActor in
                    guard let self,
                          self.phase == .recording || self.phase == .transcribing else { return }
                    self.fail("The app did not finish dictation. Try again.")
                }
            }
        default:
            break
        }
    }

    func cancelDictation() {
        stopPolling()
        stopElapsedTimer()
        startWatchdog?.invalidate()
        DarwinNotifications.post(.cancelRequested)
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

    // MARK: - Session start

    private func startDictationSession() {
        sessionToken = UUID().uuidString
        DictationSharedState.sessionToken = sessionToken
        DictationSharedState.liveTranscript = ""
        DictationSharedState.finalText = ""
        DictationSharedState.errorMessage = ""
        DictationSharedState.status = .requested
        DarwinNotifications.post(.recordingRequested)

        phase = .starting
        beginPolling()

        // If the app doesn't acknowledge within 1.5 s it is probably not
        // running — cold-launch it via the URL scheme. The guard on
        // `phase == .starting` means a warm app that already flipped us to
        // `.recording` is never launched, so the user stays in their host
        // app and the container app records in the background.
        startWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .starting else { return }
                self.openURLHandler?(DictationURL.dictate)
            }
        }
    }

    /// Called whenever the keyboard view appears. Handles the case where the
    /// keyboard process was suspended or killed while the container app was
    /// in the foreground (e.g. a cold launch, then a swipe back to Notes):
    /// a fresh keyboard process spawns and must re-attach to the session the
    /// app is still recording, or insert text the app already finalized.
    func recoverKeyboardSession() {
        guard phase == .idle else { return }
        let status = DictationSharedState.status
        let age = Date().timeIntervalSince1970 - DictationSharedState.lastUpdatedAt
        guard age < 30 else { return }

        switch status {
        case .requested, .recording, .transcribing:
            // The container app owns the session; re-attach to it so the
            // recording overlay reappears and live text keeps streaming.
            sessionToken = DictationSharedState.sessionToken
            phase = status == .recording || status == .transcribing ? .recording : .starting
            startTime = Date()
            startElapsedTimer()
            startWatchdog?.invalidate()
            beginPolling()

        case .ready:
            // The app finished while we were away — insert immediately.
            let text = DictationSharedState.finalText
            if !text.isEmpty {
                controller?.insertText(text)
            }
            DictationSharedState.finalText = ""
            DictationSharedState.status = .idle

        case .idle, .failed:
            break
        }
    }

    // MARK: - Polling the App Group

    private func beginPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
    }

    private func pollOnce() {
        guard let sessionToken, DictationSharedState.sessionToken == sessionToken else {
            // Stale or foreign session — stand down.
            resetToIdle()
            return
        }

        let status = DictationSharedState.status
        let age = Date().timeIntervalSince1970 - DictationSharedState.lastUpdatedAt

        switch status {
        case .requested:
            if age > 30 {
                fail("The app did not respond. Is it installed?")
            }

        case .recording:
            if phase == .starting {
                phase = .recording
                startTime = Date()
                startElapsedTimer()
                startWatchdog?.invalidate()
            }
            liveTranscript = DictationSharedState.liveTranscript
            audioLevel = Float(DictationSharedState.audioLevel)
            if age > 5 {
                fail("Recording stalled. Try again.")
            }

        case .transcribing:
            if phase == .recording {
                phase = .transcribing
            }
            liveTranscript = DictationSharedState.liveTranscript
            if age > 10 {
                fail("Finalizing timed out. Try again.")
            }

        case .ready:
            let text = DictationSharedState.finalText
            guard !text.isEmpty else {
                resetToIdle()
                return
            }
            stopPolling()
            stopElapsedTimer()
            startWatchdog?.invalidate()
            phase = .ready
            controller?.insertText(text)
            // Clear the shared result so a respawned keyboard process never
            // inserts it a second time.
            DictationSharedState.finalText = ""
            DictationSharedState.status = .idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                Task { @MainActor in self?.resetToIdle() }
            }

        case .failed:
            fail(DictationSharedState.errorMessage.isEmpty
                 ? "Dictation failed. Try again."
                 : DictationSharedState.errorMessage)

        case .idle:
            if phase == .recording || phase == .transcribing {
                // The app cleared the session (e.g. the user cancelled from
                // the app's overlay).
                resetToIdle()
            }
        }
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        stopPolling()
        stopElapsedTimer()
        startWatchdog?.invalidate()
        phase = .failed(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            Task { @MainActor in self?.resetToIdle() }
        }
    }

    private func resetToIdle() {
        stopPolling()
        stopElapsedTimer()
        startWatchdog?.invalidate()
        sessionToken = nil
        liveTranscript = ""
        audioLevel = 0
        elapsed = 0
        phase = .idle
    }

    private func startElapsedTimer() {
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

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
