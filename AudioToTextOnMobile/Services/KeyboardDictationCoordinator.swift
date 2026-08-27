import AVFoundation
import Foundation
import Observation
import os
import Speech
import SwiftUI
import UIKit

/// App-side owner of the dictation session. The keyboard only requests and
/// observes; this coordinator captures audio + runs on-device recognition
/// and publishes progress through the App Group.
///
/// The app keeps recording while backgrounded (UIBackgroundModes audio +
/// an active `.record` session), so the keyboard can stay in front in Notes.
/// A suspended app is NOT woken by Darwin notifications — in that case the
/// keyboard cold-launches us via `attotext://dictate`.
@MainActor
@Observable
final class KeyboardDictationCoordinator {

    static let shared = KeyboardDictationCoordinator()

    private static let logger = Logger(
        subsystem: "com.example.AudioToTextOnMobile.app",
        category: "DictationCoordinator"
    )

    // MARK: - Published state (drives the app's own overlay UI)

    private(set) var isActive = false
    private(set) var isColdStart = false
    private(set) var status: DictationSharedState.Status = .idle
    private(set) var liveText = ""
    private(set) var finalText = ""
    private(set) var errorMessage: String?

    // MARK: - Services

    private let captureService = AudioCaptureService()
    private let speechService = SpeechRecognitionService()
    private var finalizedSegments: [String] = []

    // MARK: - Private state

    private var token = ""
    private var isFinishing = false
    private var lastLevelPublish = Date.distantPast
    private var sessionLoopTask: Task<Void, Never>?
    private var finishWatchdog: Task<Void, Never>?
    private var darwinObservation: DarwinNotifications.Observation?

    private init() {
        darwinObservation = DarwinNotifications.observe { [weak self] in
            Task { @MainActor in self?.handlePing() }
        }
        wireCallbacks()
        // Keep the mic armed (always-on) so a background request can be
        // adopted without initializing the input unit.
        ensureMicArmed()
        // If this process was (re)launched while a session was already
        // requested (keyboard tapped the mic before we existed), adopt it.
        Task { @MainActor in
            await self.checkRequested()
        }
    }

    // MARK: - Inbound (keyboard → app)

    /// Called when the app is opened via `attotext://dictate` (cold launch
    /// by the keyboard) — the ONLY way to wake a suspended app.
    func noteOpenURL() {
        isColdStart = true
        ensureMicArmed()
        Task { await checkRequested() }
    }

    /// Called by the app on scene-phase changes.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if !isActive { isColdStart = false }
            // Heartbeat + always-armed mic: keep the input unit initialized
            // while we're visible so dictation can start instantly later,
            // even from the background.
            DictationSharedState.touchActivity()
            ensureMicArmed()
            Task { await checkRequested() }
        case .inactive:
            // Never clear cold-start while a session is live (that would
            // steal the overlay from a live session).
            if !isActive { isColdStart = false }
        case .background:
            if !isActive { isColdStart = false }
            // The armed capture engine (started while foreground) keeps this
            // process alive in the background (UIBackgroundModes audio) and
            // ready to adopt a request WITHOUT initializing the mic — which
            // iOS forbids in the background.
            ensureMicArmed()
        @unknown default:
            break
        }
    }

    /// Wakes the session loop immediately (used by the Darwin ping).
    private func handlePing() {
        // Heartbeat so the keyboard knows the app is alive and won't
        // cold-launch it (foreground-steal) while a Darwin wake suffices.
        DictationSharedState.touchActivity()
        if isActive {
            Task { await sessionLoopTick() }
        } else {
            Task { await checkRequested() }
        }
    }

    /// Keeps the capture engine running at all times (while the app is alive
    /// and no session is active) so that a dictation request can be adopted
    /// in the background WITHOUT initializing the input unit. iOS refuses to
    /// START mic capture in the background (AURemoteIO '!int' 560557684), but
    /// a capture session started in the foreground keeps running there.
    private func ensureMicArmed() {
        guard !isActive, !captureService.isRunning else { return }
        Task { @MainActor in
            guard !self.isActive, !self.captureService.isRunning else { return }
            if AVAudioApplication.shared.recordPermission == .undetermined && !self.isAppForeground {
                // The permission prompt can only be shown in the foreground.
                Self.logger.info("ensureMicArmed: permission undetermined while backgrounded — deferring")
                return
            }
            let micGranted = await Self.requestMicrophonePermission()
            guard !self.isActive, !self.captureService.isRunning else { return }
            guard micGranted else {
                Self.logger.error("ensureMicArmed: microphone permission denied — dictation will need a foreground start")
                return
            }
            do {
                try self.captureService.start()
                DictationSharedState.touchActivity()
                Self.logger.info("mic armed — background dictation ready")
            } catch {
                Self.logger.error("ensureMicArmed failed: \(AudioCaptureService.errorDetail(error, copyToPasteboard: false))")
            }
        }
    }

    /// Adopts a `.requested` session if one is waiting for us. Refuses to
    /// adopt from the background unless both permissions are already granted
    /// (a permission prompt can't be shown while backgrounded — the keyboard
    /// will cold-launch us instead).
    private func checkRequested() async {
        guard !isActive else { return }
        let defaults = AppGroup.defaults
        guard DictationSharedState.status(defaults) == .requested else { return }
        let requestedToken = DictationSharedState.sessionToken(defaults)
        guard !requestedToken.isEmpty else { return }

        // Don't adopt a request the keyboard gave up on (it disappeared
        // before we could adopt, e.g. the cold-launch race). Those are
        // silently discarded, so they can't start an orphan session later.
        if let requestedAt = DictationSharedState.lastActivityDate,
           Date().timeIntervalSince(requestedAt) > 30 {
            DictationSharedState.reset(defaults: defaults)
            DictationSharedState.setStatus(.idle, defaults: defaults)
            Self.logger.info("checkRequested: stale request discarded")
            return
        }

        let isForeground = UIApplication.shared.applicationState == .active
        let micGranted = AVAudioApplication.shared.recordPermission == .granted
        let speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        // Background adoption is only possible when the mic is ALREADY
        // running (always-armed engine): iOS forbids starting the input unit
        // from the background (AURemoteIO 560557684 '!int'), so without an
        // armed engine we must let the keyboard cold-launch us instead.
        let canAdoptInBackground = micGranted && speechGranted && captureService.isRunning
        guard isForeground || canAdoptInBackground else { return }

        adoptSession(token: requestedToken)
    }

    private func adoptSession(token: String) {
        self.token = token
        isActive = true
        isFinishing = false
        finalizedSegments = []
        liveText = ""
        finalText = ""
        errorMessage = nil
        DictationSharedState.clearPayload()
        DictationSharedState.setStatus(.recording)
        startSessionLoop()
        Self.logger.info("adopting session (token \(token.prefix(8)))")
        Task { await startAudio() }
    }

    // MARK: - Audio + recognition

    private func startAudio() async {
        let micGranted = await Self.requestMicrophonePermission()
        let speechGranted = await Self.requestSpeechPermission()
        guard isActive else { return }  // cancelled while the prompt was up
        guard micGranted && speechGranted else {
            publishFailure("Microphone or speech recognition access was denied. Enable both in Settings → Privacy, then try again.")
            return
        }
        do {
            try speechService.startSession()
            // The engine is normally already armed (running continuously), so
            // a background request never initializes the input unit — that is
            // what iOS forbids (AURemoteIO '!int' 560557684). Only start it if
            // it isn't running (cold-launch race, interruption recovery).
            if !captureService.isRunning {
                try captureService.start()
            }
            DictationSharedState.setStatus(.recording)
            Self.logger.info("dictation recording started (token \(self.token.prefix(8)))")
        } catch {
            publishFailure(error)
        }
    }

    /// User action from the app overlay: stop and finalize.
    func beginFinish() {
        guard isActive, !isFinishing, DictationSharedState.status() == .recording else { return }
        isFinishing = true
        DictationSharedState.setStatus(.transcribing)
        // IMPORTANT: do NOT stop the capture engine here. UIBackgroundModes
        // audio only keeps this process alive while its audio session is
        // active — stopping it now would suspend the background app during
        // the finalize wait below and `.ready` would never be published
        // (the keyboard then times out and the seen text is lost). The
        // engine keeps running (feeding a finished recognizer, which is a
        // harmless no-op) until `finishAndPublish` has written the result.
        speechService.finishSession()

        // The final segment usually lands within ~1-2s of endAudio, but the
        // on-device engine can take much longer. The text the user already
        // saw (liveText) is a perfectly good result — publish it promptly so
        // the keyboard inserts immediately instead of racing a timeout.
        finishWatchdog?.cancel()
        finishWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.isActive, self.isFinishing else { return }
            self.finishAndPublish()
        }
    }

    /// User action from the app overlay: abort everything.
    func cancelSession() {
        guard isActive else { return }
        stopSessionLoop()
        finishWatchdog?.cancel()
        // The capture engine stays armed (always-on mic) — never stop it.
        speechService.cancelSession()
        finalizedSegments = []
        DictationSharedState.reset()
        DictationSharedState.setStatus(.idle)
        standDown()
    }

    /// Dismisses the app-side overlay after a finished (.ready) session.
    ///
    /// The shared `.ready` + `finalText` are intentionally LEFT in place:
    /// the keyboard was very likely cold-launched away (or is dead), and it
    /// will insert the text when the user returns to Notes. The keyboard
    /// only auto-inserts fresh results (10-minute window), so a stale one
    /// can't surprise-insert into an unrelated field later.
    func dismissReady() {
        guard isActive, DictationSharedState.status() == .ready else { return }
        stopSessionLoop()
        finishWatchdog?.cancel()
        standDown()
    }

    private func finishAndPublish() {
        guard isActive else { return }
        finishWatchdog?.cancel()
        isFinishing = false
        let text = (finalizedSegments + [liveText])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = AppGroup.defaults
        // Write the result BEFORE stopping capture: `captureService.stop()`
        // deactivates the audio session, and in the background that can
        // suspend the app almost immediately. The shared store is our only
        // durable channel to the keyboard.
        if text.isEmpty {
            captureService.stop()
            DictationSharedState.reset(defaults: defaults)
            DictationSharedState.setStatus(.idle, defaults: defaults)
            standDown()
            return
        }
        finalText = text
        status = .ready
        DictationSharedState.clearPayload(defaults: defaults)
        DictationSharedState.setStatus(.ready, defaults: defaults)
        defaults.set(text, forKey: DictationSharedState.Key.finalText)
        if !isAppForeground { isColdStart = false }
        Self.logger.info("dictation ready (token \(self.token.prefix(8))): \(text)")
        // The capture engine stays armed (always-on mic), so the app remains
        // alive in the background while the keyboard consumes the result.
        // isActive stays true until the keyboard inserts + clears, so the
        // app overlay can show "Dictation complete — return to your keyboard".
    }

    private func publishFailure(_ error: Error) {
        let detail: String
        if case AudioCaptureService.CaptureError.engineStartFailed(let raw) = error {
            detail = AudioCaptureService.errorDetail(raw)
        } else {
            detail = AudioCaptureService.errorDetail(error)
        }
        publishFailure(detail)
    }

    private func publishFailure(_ message: String) {
        stopSessionLoop()
        finishWatchdog?.cancel()
        // The capture engine stays armed (always-on mic) — never stop it.
        speechService.cancelSession()
        errorMessage = message
        status = .failed
        let defaults = AppGroup.defaults
        DictationSharedState.clearPayload(defaults: defaults)
        DictationSharedState.setStatus(.failed, defaults: defaults)
        defaults.set(message, forKey: DictationSharedState.Key.errorMessage)
        standDown()
        Self.logger.error("dictation failed: \(message)")
        // Copy the error to the pasteboard so the user can paste it back to
        // the developer without typing it.
        let dump = """
        [AudioToTextOnMobile app] \(message)
        isForeground=\(isAppForeground)
        capture=\(captureService.environmentSummary())
        mic=\(AVAudioApplication.shared.recordPermission.rawValue)
        speech=\(SFSpeechRecognizer.authorizationStatus().rawValue)
        """
        UIPasteboard.general.string = dump
    }

    // MARK: - Session loop (runs while a session is live)

    private func startSessionLoop() {
        sessionLoopTask?.cancel()
        sessionLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                await self.sessionLoopTick()
            }
        }
    }

    private func stopSessionLoop() {
        sessionLoopTask?.cancel()
        sessionLoopTask = nil
    }

    private func sessionLoopTick() async {
        guard isActive else { return }
        let defaults = AppGroup.defaults
        switch DictationSharedState.status(defaults) {
        case .recording:
            if DictationSharedState.wantsCancel(defaults) {
                cancelSession()
            } else if DictationSharedState.wantsStop(defaults) {
                beginFinish()
            } else if let last = DictationSharedState.lastActivityDate,
                      Date().timeIntervalSince(last) > 60 {
                // No speech for a minute (keyboard may be dead) — finalize.
                Self.logger.info("dictation idle 60s — auto-finalizing")
                beginFinish()
            }
        case .transcribing, .ready, .requested, .failed:
            break
        case .idle:
            // The keyboard inserted (or cancelled) and cleared the state.
            if !isFinishing {
                standDown()
            }
        }
    }

    // MARK: - Service wiring

    private func wireCallbacks() {
        speechService.onTranscriptUpdate = { [weak self] text in
            guard let self else { return }
            self.liveText = text
            let defaults = AppGroup.defaults
            defaults.set(text, forKey: DictationSharedState.Key.liveText)
            DictationSharedState.touchActivity(defaults: defaults)
        }
        speechService.onSegmentFinalized = { [weak self] text in
            guard let self else { return }
            self.finalizedSegments.append(text)
            self.liveText = ""
            let defaults = AppGroup.defaults
            defaults.set("", forKey: DictationSharedState.Key.liveText)
            DictationSharedState.touchActivity(defaults: defaults)
            if self.isFinishing {
                self.finishAndPublish()
            }
        }
        speechService.onError = { [weak self] message in
            guard let self else { return }
            if self.isFinishing {
                self.finishAndPublish()
            } else {
                self.publishFailure(message)
            }
        }
        captureService.onBuffer = { [weak self] buffer in
            self?.speechService.append(buffer)
        }
        captureService.onLevel = { [weak self] level in
            self?.publishLevel(level)
        }
        captureService.onInterruption = { [weak self] in
            self?.beginFinish()
        }
        captureService.onInterruptionEnded = { [weak self] in
            // The system returned the mic to us — resume the always-on
            // capture engine if the interruption took it down.
            self?.ensureMicArmed()
        }
    }

    private func publishLevel(_ level: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelPublish) >= 0.1 else { return }
        lastLevelPublish = now
        let defaults = AppGroup.defaults
        defaults.set(level, forKey: DictationSharedState.Key.audioLevel)
        // While armed-but-idle, keep the heartbeat fresh so the keyboard
        // knows the app is alive and won't cold-launch it (foreground steal).
        if !isActive {
            DictationSharedState.touchActivity(defaults: defaults)
        }
    }

    // MARK: - Helpers

    private var isAppForeground: Bool {
        UIApplication.shared.applicationState == .active
    }

    private func standDown() {
        stopSessionLoop()
        finishWatchdog?.cancel()
        isActive = false
        isFinishing = false
        isColdStart = false
        token = ""
        finalizedSegments = []
        liveText = ""
        finalText = ""
        errorMessage = nil
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
