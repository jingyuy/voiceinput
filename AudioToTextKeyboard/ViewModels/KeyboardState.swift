import Foundation
import os
import UIKit

/// Drives the keyboard extension UI for dictation.
///
/// IMPORTANT: the keyboard process CANNOT record audio on current iOS (the
/// input unit is rejected at kAUStartIO even with Full Access + granted mic
/// permission + a perfect format — verified with AVAudioEngine,
/// AVAudioRecorder and AVCaptureSession probes). So the CONTAINER APP owns
/// capture + recognition; this state object only:
///   1. writes a `.requested` session (token) to the App Group,
///   2. wakes the app via a Darwin notification — cold-launching it through
///      `attotext://dictate` (SwiftUI openURL) if it doesn't acknowledge,
///   3. polls the shared state and reflects it in the UI,
///   4. inserts `finalText` exactly once when the app reports `.ready`.
@MainActor
final class KeyboardState: ObservableObject {

    private static let logger = Logger(
        subsystem: "com.example.AudioToTextOnMobile.keyboard",
        category: "KeyboardState"
    )

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

    /// Injected by the SwiftUI layer (`KeyboardRootView`). SwiftUI's
    /// `openURL` is the ONLY way a keyboard extension can reliably open a
    /// URL (UIApplication.shared and NSExtensionContext.open don't work for
    /// keyboard extensions).
    var openURL: ((URL) -> Void)?

    // MARK: - Private state

    private weak var controller: KeyboardViewController?
    private var pollTimer: Timer?
    private var watchdogTask: Task<Void, Never>?
    private var finishWatchdog: Task<Void, Never>?
    private var sessionGeneration = 0
    private var myToken = ""
    private var startTime: Date?
    private var elapsedTimer: Timer?
    private var insertedFinalText = false
    private var lastLiveText = ""
    private var lastActivityDate: Date?

    // MARK: - Timings

    private let pollInterval: TimeInterval = 0.1
    /// Cold-launch delay when the app was never seen (or hasn't been alive
    /// for a long while): it's almost certainly terminated, so launch it fast.
    private let coldLaunchDelay: TimeInterval = 1.5
    /// A heartbeat younger than this counts as "the app is (or was very
    /// recently) running" — trust the Darwin wake instead of cold-launching.
    private let coldLaunchDelayWhenAppKnown: TimeInterval = 4.0
    private let startTimeout: TimeInterval = 10
    private let idleTimeout: TimeInterval = 30
    /// Generous on purpose: the app's own finalize watchdog is ~3s, so this
    /// must never race it.
    private let transcribeTimeout: TimeInterval = 25

    /// Any heartbeat at all means the app has run before — and with the
    /// app's silent keep-alive it is (almost always) still alive in the
    /// background, so a Darwin ping will wake it WITHOUT stealing the
    /// foreground. Give the wake time to land; only fast-launch when the
    /// app has never run (first install / never opened).
    private var hasAppHeartbeat: Bool {
        DictationSharedState.lastActivityDate != nil
    }

    private var effectiveColdLaunchDelay: TimeInterval {
        hasAppHeartbeat ? coldLaunchDelayWhenAppKnown : coldLaunchDelay
    }

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    deinit {
        pollTimer?.invalidate()
        watchdogTask?.cancel()
        finishWatchdog?.cancel()
        elapsedTimer?.invalidate()
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
        guard hasFullAccess else {
            Self.logger.error("startDictation: hasFullAccess=false, refusing")
            fail("Full Access is off — enable it in Settings → General → Keyboard, then tap the mic again.")
            return
        }
        guard AppGroup.isAvailable else {
            Self.logger.error("startDictation: app group unavailable")
            fail("The app isn't installed (no shared container). Install Audio To Text and try again.")
            return
        }

        sessionGeneration += 1
        let generation = sessionGeneration
        insertedFinalText = false
        phase = .starting
        liveTranscript = ""
        audioLevel = 0
        elapsed = 0

        // Fresh request: token + .requested, then wake the app.
        myToken = UUID().uuidString
        let defaults = AppGroup.defaults
        DictationSharedState.reset(defaults: defaults)
        defaults.set(myToken, forKey: DictationSharedState.Key.sessionToken)
        DictationSharedState.setStatus(.requested, defaults: defaults)
        lastActivityDate = DictationSharedState.lastActivityDate
        Self.logger.info("startDictation: requested (token \(self.myToken.prefix(8)))")

        DarwinNotifications.post()
        startPolling(generation: generation)

        // If the app doesn't acknowledge quickly, it isn't running (or is
        // suspended — Darwin can't wake it) → cold-launch via URL. When the
        // app was alive recently, wait longer so the Darwin wake lands in
        // the background instead of stealing the foreground.
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.effectiveColdLaunchDelay ?? 1.5))
            guard let self, !Task.isCancelled, generation == self.sessionGeneration,
                  self.phase == .starting else { return }
            let status = DictationSharedState.status()
            guard status == .requested || status == .idle else { return }
            Self.logger.info("startDictation: app did not acknowledge — cold-launching")
            self.openURL?(URL(string: "attotext://dictate")!)
        }
    }

    /// Stops dictation (user tapped stop): ask the app to finalize.
    func stopDictation() {
        switch phase {
        case .recording:
            phase = .transcribing
            let defaults = AppGroup.defaults
            defaults.set(true, forKey: DictationSharedState.Key.stopRequested)
            DictationSharedState.touchActivity(defaults: defaults)
            DarwinNotifications.post()
            // Bounded wait for the app to finish.
            finishWatchdog?.cancel()
            finishWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.transcribeTimeout ?? 25))
                guard let self, !Task.isCancelled else { return }
                guard case .transcribing = self.phase else { return }
                // Before giving up, re-check the shared state: the app may
                // have published `.ready` just past our check.
                let defaults = AppGroup.defaults
                let shared = DictationSharedState.status(defaults)
                if shared == .ready {
                    let text = DictationSharedState.finalText(defaults)
                    if !text.isEmpty {
                        self.insertedFinalText = true
                        self.controller?.insertText(text)
                        defaults.removeObject(forKey: DictationSharedState.Key.finalText)
                        DictationSharedState.setStatus(.idle, defaults: defaults)
                        Self.logger.info("stopDictation watchdog: late .ready — inserted final text")
                        self.phase = .ready
                        self.liveTranscript = ""
                        self.scheduleIdle(after: 1.5)
                        return
                    }
                }
                self.fail("Speech recognition timed out.")
            }
        case .starting:
            cancelDictation()
        default:
            break
        }
    }

    /// Cancels dictation (user tapped X): tell the app to abort.
    func cancelDictation() {
        sessionGeneration += 1
        watchdogTask?.cancel()
        finishWatchdog?.cancel()
        stopPolling()
        let defaults = AppGroup.defaults
        let current = DictationSharedState.status(defaults)
        if current == .requested || current == .recording {
            defaults.set(true, forKey: DictationSharedState.Key.cancelRequested)
            DictationSharedState.touchActivity(defaults: defaults)
            DarwinNotifications.post()
        }
        resetToIdle()
    }

    /// Called from `viewWillDisappear`. A LIVE session lives in the app and
    /// keeps recording — never touch it here. A `.starting` request is LEFT
    /// in the shared store: if the app was suspended (cold-launch race) it
    /// must still be able to adopt it when it launches; requests the app
    /// never picks up expire on its side (`.requested` older than 30s is
    /// discarded), so they can't dangle into a surprise session.
    func cancelPendingRequest() {
        guard phase == .starting else { return }
        sessionGeneration += 1
        watchdogTask?.cancel()
        finishWatchdog?.cancel()
        stopPolling()
        resetToIdle()
    }

    /// Called from `viewWillAppear`: the keyboard process may have been
    /// suspended/killed while the app was foreground (cold launch) — re-attach
    /// to the live session or insert immediately if it already finished.
    func recoverKeyboardSession() {
        refreshFullAccessStatus()
        switch phase {
        case .idle, .failed:
            break
        default:
            return
        }
        let defaults = AppGroup.defaults
        let status = DictationSharedState.status(defaults)
        Self.logger.info("recoverKeyboardSession: shared status=\(status.rawValue)")

        switch status {
        case .requested:
            // Our request is still pending (we died before the app adopted).
            myToken = DictationSharedState.sessionToken(defaults)
            sessionGeneration += 1
            let generation = sessionGeneration
            insertedFinalText = false
            phase = .starting
            lastActivityDate = DictationSharedState.lastActivityDate
            startPolling(generation: generation)
            // Nudge the app again: if it's alive in the background (its
            // silent keep-alive) it adopts instantly — no cold-launch, no
            // foreground steal.
            DarwinNotifications.post()
            watchdogTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.effectiveColdLaunchDelay ?? 1.5))
                guard let self, !Task.isCancelled, generation == self.sessionGeneration,
                      self.phase == .starting else { return }
                let current = DictationSharedState.status()
                guard current == .requested || current == .idle else { return }
                Self.logger.info("recoverKeyboardSession: cold-launching app")
                self.openURL?(URL(string: "attotext://dictate")!)
            }
        case .recording, .transcribing:
            sessionGeneration += 1
            let generation = sessionGeneration
            myToken = DictationSharedState.sessionToken(defaults)
            insertedFinalText = false
            phase = (status == .recording) ? .recording : .transcribing
            lastActivityDate = DictationSharedState.lastActivityDate
            liveTranscript = DictationSharedState.liveText(defaults)
            lastLiveText = liveTranscript
            audioLevel = DictationSharedState.audioLevel(defaults)
            startElapsedTimer()
            startPolling(generation: generation)
        case .ready:
            // Only auto-insert a FRESH result. A `.ready` that has been
            // sitting in the shared store for a long time (app was
            // cold-launched, user never returned) must not surprise-insert
            // into an unrelated field later.
            let fresh = DictationSharedState.lastActivityDate.map {
                Date().timeIntervalSince($0) < 600
            } ?? false
            if !fresh {
                DictationSharedState.reset(defaults: defaults)
                DictationSharedState.setStatus(.idle, defaults: defaults)
                phase = .idle
                return
            }
            let text = DictationSharedState.finalText(defaults)
            if !text.isEmpty, !insertedFinalText {
                insertedFinalText = true
                controller?.insertText(text)
                defaults.removeObject(forKey: DictationSharedState.Key.finalText)
                DictationSharedState.setStatus(.idle, defaults: defaults)
                Self.logger.info("recoverKeyboardSession: inserted final text")
                phase = .ready
                liveTranscript = ""
                scheduleIdle(after: 1.5)
            } else {
                phase = .idle
            }
        case .failed:
            let message = DictationSharedState.errorMessage(defaults)
            DictationSharedState.reset(defaults: defaults)
            DictationSharedState.setStatus(.idle, defaults: defaults)
            fail(message.isEmpty ? "Dictation failed." : message)
        case .idle:
            break
        }
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

    // MARK: - Polling

    private func startPolling(generation: Int) {
        stopPolling()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollOnce(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce(generation: Int) {
        guard generation == sessionGeneration else { return }
        let defaults = AppGroup.defaults
        let shared = DictationSharedState.status(defaults)
        lastActivityDate = DictationSharedState.lastActivityDate
        audioLevel = DictationSharedState.audioLevel(defaults)

        switch shared {
        case .requested:
            if phase == .starting, let last = lastActivityDate {
                // The app never picked the request up.
                if Date().timeIntervalSince(last) > startTimeout {
                    fail("Dictation isn't connected. Make sure the app is installed and open it once, then try again.")
                }
            }
        case .recording:
            if phase == .starting {
                phase = .recording
                startElapsedTimer()
            }
            updateLiveText(DictationSharedState.liveText(defaults))
            if let last = lastActivityDate, Date().timeIntervalSince(last) > idleTimeout {
                // Long silence — wrap up so the session can't leak.
                Self.logger.info("pollOnce: idle \(self.idleTimeout)s — auto-stopping")
                stopDictation()
            }
        case .transcribing:
            phase = .transcribing
        case .ready:
            let text = DictationSharedState.finalText(defaults)
            if !text.isEmpty, !insertedFinalText {
                insertedFinalText = true
                controller?.insertText(text)
                // Clear so a respawned keyboard process can't double-insert.
                defaults.removeObject(forKey: DictationSharedState.Key.finalText)
                DictationSharedState.setStatus(.idle, defaults: defaults)
                Self.logger.info("pollOnce: inserted final text")
                phase = .ready
                liveTranscript = ""
                stopPolling()
                scheduleIdle(after: 1.5)
            }
        case .failed:
            let message = DictationSharedState.errorMessage(defaults)
            DictationSharedState.reset(defaults: defaults)
            DictationSharedState.setStatus(.idle, defaults: defaults)
            fail(message.isEmpty ? "Dictation failed." : message)
        case .idle:
            if phase == .starting {
                // The app reset the request (it cancelled immediately).
                fail("Dictation isn't connected. Make sure the app is installed and open it once, then try again.")
            } else if phase == .recording || phase == .transcribing {
                // The app ended the session without delivering text.
                resetToIdle()
            }
        }
    }

    private func updateLiveText(_ text: String) {
        guard text != lastLiveText else { return }
        lastLiveText = text
        liveTranscript = text
    }

    // MARK: - Helpers

    private func scheduleIdle(after delay: TimeInterval) {
        finishWatchdog?.cancel()
        finishWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.resetToIdle()
        }
    }

    private func fail(_ message: String) {
        Self.logger.error("fail: \(message)")
        // Copy the error to the pasteboard so the user can paste it back to
        // the developer without typing it.
        let shared = DictationSharedState.status()
        let dump = """
        [AudioToTextKeyboard] \(message)
        phase=\(phase)
        sharedStatus=\(shared.rawValue)
        token=\(myToken.prefix(8))
        lastActivity=\(DictationSharedState.lastActivityDate.map { String(format: "%.1fs ago", Date().timeIntervalSince($0)) } ?? "nil")
        """
        UIPasteboard.general.string = dump
        watchdogTask?.cancel()
        finishWatchdog?.cancel()
        stopPolling()
        stopElapsedTimer()
        phase = .failed(message)
        scheduleIdle(after: 2.5)
    }

    private func resetToIdle() {
        sessionGeneration += 1
        watchdogTask?.cancel()
        finishWatchdog?.cancel()
        stopPolling()
        stopElapsedTimer()
        insertedFinalText = false
        myToken = ""
        lastLiveText = ""
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
}
