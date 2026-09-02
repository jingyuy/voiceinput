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

    // MARK: - Timeout / freshness constants

    /// A `.requested` older than this (by the KEYBOARD's own clock) is
    /// discarded — the requesting keyboard gave up on it.
    static let requestTTL: TimeInterval = 30
    /// How long a backgrounded keyboard session may run with NO keyboard
    /// presence before the app finalizes it (the orphan killer).
    static let presenceGrace: TimeInterval = 10
    /// No REAL speech (RMS above the noise floor / transcript change) for
    /// this long → finalize with what we have.
    static let speechIdleTimeout: TimeInterval = 60
    /// Absolute session-length cap — no session can ever run forever, even
    /// if every other timeout is defeated.
    static let maxSessionDuration: TimeInterval = 240

    // MARK: - Published state (drives the app's own overlay UI)

    private(set) var isActive = false
    /// True while the app's OWN UI (TranscriptionView) is driving a session
    /// through this coordinator. App sessions share the single capture
    /// engine + recognizer and never touch the shared keyboard protocol.
    private(set) var isAppSession = false
    private(set) var isColdStart = false
    private(set) var status: DictationSharedState.Status = .idle
    private(set) var liveText = ""
    private(set) var finalText = ""
    private(set) var errorMessage: String?
    private(set) var audioLevel: Float = 0
    /// Finalized segments (shared by app sessions and displayed in the app's
    /// own transcript card).
    private(set) var finalizedSegments: [String] = []

    // MARK: - Services

    private let captureService = AudioCaptureService()
    private let speechService = SpeechRecognitionService()

    // MARK: - Private state

    private var token = ""
    private var isFinishing = false
    private var lastLevelPublish = Date.distantPast
    /// When the session loop last attempted a mid-session engine re-arm —
    /// used to escalate a still-stalled engine to finalize-with-partial.
    private var stallReArmAttemptedAt: Date?
    /// When the current session last heard REAL speech (RMS above the noise
    /// floor, or a transcript change). Drives the speech-idle finalize.
    /// Unlike `lastActivity` it cannot be refreshed by mere engine liveness.
    private var lastSpeechAt = Date()
    /// When the current session started — base of the absolute cap.
    private var sessionStartedAt = Date()
    private var sessionLoopTask: Task<Void, Never>?
    private var finishWatchdog: Task<Void, Never>?
    private var armWatcherTask: Task<Void, Never>?
    private var darwinObservation: DarwinNotifications.Observation?

    private init() {
        darwinObservation = DarwinNotifications.observe { [weak self] in
            Task { @MainActor in self?.handlePing() }
        }
        wireCallbacks()
        applyLocaleFromSettings()
        // Keep the mic armed (always-on) so a background request can be
        // adopted without initializing the input unit.
        ensureMicArmed()
        // Watch the engine while idle: recover sessions stolen by an
        // interruption / route change / media reset without a restart.
        startArmWatcher()
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
            if !isActive, !isAppSession {
                if captureService.isRunning {
                    // A session may have been stolen while we were away
                    // (media reset, route change, an old second engine) —
                    // recover immediately instead of waiting for the
                    // arm-watcher.
                    if !captureService.hasRecentBuffers(within: 5) {
                        forceReArm()
                    }
                } else {
                    ensureMicArmed()
                }
            }
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
            // iOS forbids in the background ('!int' 560557684). Re-arming
            // from the background is impossible, so recovery happens via the
            // arm-watcher / interruption-ended / route callbacks.
            if captureService.isRunning {
                ensureMicArmed()
            }
        @unknown default:
            break
        }
    }

    /// Wakes the session loop immediately (used by the Darwin ping).
    private func handlePing() {
        // Heartbeat ONLY when we can actually serve the request: a fresh
        // heartbeat makes the keyboard wait for the Darwin wake instead of
        // cold-launching. If the engine is dead (or we're unarmed) we must
        // NOT claim liveness — the keyboard should cold-launch us fast, the
        // only way to re-arm from the background.
        if isActive || captureService.isRunning {
            DictationSharedState.touchAppHeartbeat()
        }
        // The keyboard's globe key may have changed the dictation language
        // — reflect it (no-op while a session is live).
        applyLocaleFromSettings()
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
    ///
    /// `force` tears the engine down first (interruption-ended, route
    /// change, media reset, arm-watcher): `isRunning` can be stale-true on a
    /// dead engine, so the normal guard would never re-arm it.
    private func ensureMicArmed(force: Bool = false) {
        guard !isActive, !isAppSession else { return }
        if !force, captureService.isRunning { return }
        Task { @MainActor in
            guard !self.isActive, !self.isAppSession else { return }
            if !force, self.captureService.isRunning { return }
            if force, self.captureService.isRunning {
                self.captureService.stop()
            }
            if AVAudioApplication.shared.recordPermission == .undetermined && !self.isAppForeground {
                // The permission prompt can only be shown in the foreground.
                Self.logger.info("ensureMicArmed: permission undetermined while backgrounded — deferring")
                return
            }
            let micGranted = await Self.requestMicrophonePermission()
            guard !self.isActive, !self.isAppSession else { return }
            guard micGranted else {
                Self.logger.error("ensureMicArmed: microphone permission denied — dictation will need a foreground start")
                return
            }
            do {
                try self.captureService.start()
                DictationSharedState.touchAppHeartbeat()
                Self.logger.info("mic armed — background dictation ready")
            } catch {
                Self.logger.error("ensureMicArmed failed: \(AudioCaptureService.errorDetail(error, copyToPasteboard: false))")
            }
        }
    }

    /// Tears down a broken engine and re-arms it (used when the system took
    /// the mic away: interruption-ended, route change, media services reset).
    /// Only meaningful while IDLE — during a live session the session-loop
    /// stall detection owns recovery (see `handleSessionStall`).
    private func forceReArm() {
        if captureService.isRunning {
            captureService.stop()
        }
        ensureMicArmed(force: true)
    }

    /// The capture engine stopped delivering buffers mid-session (route
    /// change, media reset, silent session theft). Restart it when we can;
    /// otherwise finalize so the partial text the user already saw lands in
    /// the shared store instead of being silently lost.
    private func handleSessionStall() {
        guard isActive, status == .recording else { return }
        let now = Date()
        if let last = stallReArmAttemptedAt {
            if now.timeIntervalSince(last) > 2 {
                Self.logger.warning("session engine still stalled after re-arm — finalizing with partial text")
                beginFinish()
            }
            return
        }
        stallReArmAttemptedAt = now
        if isAppForegroundish {
            Self.logger.warning("session engine stalled — restarting capture")
            restartCaptureDuringSession()
        } else {
            // In the background a stop+start would deactivate the audio
            // session and suspend us mid-recovery ('!int' forbids a
            // background start anyway) — finalize with what we have.
            Self.logger.warning("session engine stalled in background — finalizing with partial text")
            beginFinish()
        }
    }

    /// Restarts the capture engine while a session is live (the idle guards
    /// in `ensureMicArmed` must not apply). Recognition keeps consuming the
    /// new buffers; the old tap's buffers were already lost.
    private func restartCaptureDuringSession() {
        if captureService.isRunning {
            captureService.stop()
        }
        Task { @MainActor in
            guard self.isActive else { return }
            do {
                try self.captureService.start()
                Self.logger.info("capture re-armed during session")
            } catch {
                Self.logger.error("session re-arm failed: \(AudioCaptureService.errorDetail(error, copyToPasteboard: false))")
            }
        }
    }

    /// Watches the armed engine while idle. Detects engines that claim to
    /// run but stopped delivering buffers (their session was stolen) and
    /// re-arms them; also retries arming when the app is foreground or
    /// shortly after an interruption ended (the one case iOS allows a
    /// background re-arm).
    private func startArmWatcher() {
        armWatcherTask?.cancel()
        armWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                await self.armWatcherTick()
            }
        }
    }

    private func armWatcherTick() async {
        guard !isActive, !isAppSession else { return }
        if captureService.isRunning {
            if !captureService.hasRecentBuffers(within: 10) {
                Self.logger.warning("arm watcher: engine claims running but no buffers for 10s — re-arming")
                forceReArm()
            }
        } else if isAppForeground || Date().timeIntervalSince(captureService.lastInterruptionEndedAt) < 30 {
            // Background re-arm is forbidden ('!int' 560557684) EXCEPT right
            // after an interruption ended, when the system expects us to
            // resume. Otherwise wait for a foreground moment.
            ensureMicArmed(force: true)
        }
    }

    /// Adopts a `.requested` session if one is waiting for us. Refuses to
    /// adopt from the background unless both permissions are already granted
    /// (a permission prompt can't be shown while backgrounded — the keyboard
    /// will cold-launch us instead).
    private func checkRequested() async {
        guard !isActive, !isAppSession else { return }
        let defaults = AppGroup.defaults
        switch DictationSharedState.status(defaults) {
        case .requested:
            await checkRequestedSession(defaults: defaults)
        case .recording, .transcribing:
            // Orphan: the app was killed (or never adopted) while the
            // keyboard believed a session was live. Re-adopt only when we
            // can actually run audio again — foregroundish (cold-launch
            // recovery). In the background there is nothing to record with.
            guard isAppForegroundish else { return }
            let token = DictationSharedState.sessionToken(defaults)
            guard !token.isEmpty else { return }
            // Only a cancel/stop aimed AT this orphan session counts.
            if DictationSharedState.cancelRequested(for: token, defaults: defaults)
                || DictationSharedState.stopRequested(for: token, defaults: defaults) {
                DictationSharedState.reset(defaults: defaults)
                DictationSharedState.setStatus(.idle, defaults: defaults)
                Self.logger.info("checkRequested: orphan session was cancelled — discarded")
                return
            }
            Self.logger.info("checkRequested: re-adopting orphan \(DictationSharedState.status(defaults).rawValue) session")
            adoptSession(token: token)
        case .ready:
            // Orphan result: the keyboard may be dead. Show the overlay so
            // the user can dismiss it; the keyboard will insert the text on
            // its next appearance (freshness-gated).
            guard isAppForegroundish else { return }
            let text = DictationSharedState.finalText(defaults)
            guard !text.isEmpty else {
                DictationSharedState.reset(defaults: defaults)
                DictationSharedState.setStatus(.idle, defaults: defaults)
                return
            }
            isActive = true
            isAppSession = false
            status = .ready
            finalText = text
            errorMessage = nil
            startSessionLoop()
            Self.logger.info("checkRequested: adopted orphan .ready result")
        case .idle, .failed:
            break
        }
    }

    private func checkRequestedSession(defaults: UserDefaults) async {
        // Background adoption is only possible when the mic is ALREADY
        // running (always-armed engine): iOS forbids starting the input unit
        // from the background (AURemoteIO 560557684 '!int'), so without an
        // armed engine we must let the keyboard cold-launch us instead.
        let isForeground = UIApplication.shared.applicationState == .active
        let micGranted = AVAudioApplication.shared.recordPermission == .granted
        let speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        let canAdoptInBackground = micGranted && speechGranted && captureService.isRunning
        guard isForeground || canAdoptInBackground else { return }

        await handleIncomingRequest()
    }

    /// Adopts a keyboard `.requested` session. When we are ALREADY serving a
    /// DIFFERENT keyboard session (an orphan the keyboard walked away from),
    /// the new request PREEMPTS it — a newer request always wins, which is
    /// what makes a wedged app heal on the very next mic tap.
    private func adoptSession(token: String) {
        if isActive {
            // Never preempt a session driven by the app's own UI (a
            // keyboard request can't genuinely race it — no keyboard is
            // visible while the app is foreground — this is defensive).
            guard !isAppSession else { return }
            preemptCurrentSession()
        }
        self.token = token
        isActive = true
        isAppSession = false
        isFinishing = false
        stallReArmAttemptedAt = nil
        lastSpeechAt = Date()
        sessionStartedAt = Date()
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

    /// Handles a keyboard `.requested` session from ANY state (idle or
    /// wedged on an orphan). Freshness comes from the keyboard's own
    /// request clock; a fresh request is adopted unconditionally, after
    /// preempting whatever we are stuck on.
    private func handleIncomingRequest() async {
        let defaults = AppGroup.defaults
        let incoming = DictationSharedState.sessionToken(defaults)
        guard !incoming.isEmpty else { return }

        // Stale by the KEYBOARD's own clock → the requesting keyboard gave
        // up (its process died, it timed out, the user walked away).
        // Discard so it can't start an orphan session later.
        if let requestedAt = DictationSharedState.requestedAtDate(defaults) {
            guard Date().timeIntervalSince(requestedAt) < Self.requestTTL else {
                Self.logger.info("handleIncomingRequest: stale request (keyboard clock) — discarded")
                DictationSharedState.reset(defaults: defaults)
                DictationSharedState.setStatus(.idle, defaults: defaults)
                return
            }
        }

        // Already serving THIS exact request (duplicate ping / scene wake)
        // — nothing to do.
        if isActive && token == incoming { return }

        // The requesting keyboard cancelled before we could adopt.
        if DictationSharedState.cancelRequested(for: incoming, defaults: defaults) {
            Self.logger.info("handleIncomingRequest: request cancelled by keyboard — discarded")
            DictationSharedState.reset(defaults: defaults)
            DictationSharedState.setStatus(.idle, defaults: defaults)
            return
        }

        adoptSession(token: incoming)
    }

    /// Drops whatever keyboard session we are serving (an orphan — nobody
    /// is listening, which is why a NEWER request may supersede it). Partial
    /// text goes to history (never silently lost) but is NOT published to
    /// the shared store: that would race the incoming session. The capture
    /// engine stays armed for the new session.
    private func preemptCurrentSession() {
        Self.logger.info("preempting current session (token \(self.token.prefix(8)))")
        finishWatchdog?.cancel()
        if status == .recording || status == .transcribing || isFinishing {
            speechService.cancelSession()
            let partial = (finalizedSegments + [liveText])
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                TranscriptionHistoryStore.shared.add(partial)
            }
        }
        finalizedSegments = []
        liveText = ""
        finalText = ""
        errorMessage = nil
        isFinishing = false
        stallReArmAttemptedAt = nil
        // Shared state is left alone — adoptSession rewrites it.
    }

    /// True when a KEYBOARD session has no listener left: the app is
    /// backgrounded (its UI can't stop the session) AND the keyboard hasn't
    /// polled within the grace period (it died or the user left). This is
    /// the orphan-killer: no session can outlive its keyboard by much.
    private var keyboardUnattendedInBackground: Bool {
        guard !isAppSession, !isAppForeground else { return false }
        return DictationSharedState.keyboardPresenceStale(Self.presenceGrace)
    }

    // MARK: - App-side sessions (the app's own UI)

    /// True when the app's own record button can start a session. `.ready`
    /// is allowed as a defensive catch: a session that ended while the app
    /// was backgrounded (keyboard inserted, or result dismissed) leaves a
    /// stale status behind, and the mic must still start a NEW session.
    var canStartAppSession: Bool {
        !isActive && (status == .idle || status == .failed || status == .ready)
    }

    /// Starts a session driven by the app's own UI (TranscriptionView).
    /// Uses the SAME capture engine + recognizer as keyboard sessions — the
    /// process must never run two engines (a second AVAudioEngine sharing
    /// the session deactivates the armed one and silently breaks background
    /// dictation until a restart).
    func startAppSession() {
        guard canStartAppSession else { return }
        isActive = true
        isAppSession = true
        isFinishing = false
        stallReArmAttemptedAt = nil
        lastSpeechAt = Date()
        sessionStartedAt = Date()
        finalizedSegments = []
        liveText = ""
        finalText = ""
        errorMessage = nil
        token = ""
        status = .recording
        startSessionLoop()
        Task { await startAudio() }
    }

    /// User tapped stop on the app's own UI: finalize the session.
    func stopAppSession() {
        guard isActive, isAppSession, !isFinishing, status == .recording else { return }
        isFinishing = true
        status = .transcribing
        speechService.finishSession()
        finishWatchdog?.cancel()
        finishWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.isActive, self.isAppSession, self.isFinishing else { return }
            self.finishAppSession()
        }
    }

    /// User tapped cancel on the app's own UI: abort everything.
    func cancelAppSession() {
        guard isActive, isAppSession else { return }
        stopSessionLoop()
        finishWatchdog?.cancel()
        speechService.cancelSession()
        finalizedSegments = []
        liveText = ""
        finalText = ""
        errorMessage = nil
        status = .idle
        isActive = false
        isAppSession = false
        // The capture engine stays armed for the keyboard.
    }

    /// Clears the app's own transcript history (when no session is live).
    func clearAppTranscript() {
        guard !isActive else { return }
        finalizedSegments = []
        liveText = ""
        finalText = ""
        errorMessage = nil
        status = .idle
    }

    private func finishAppSession() {
        guard isActive, isAppSession, isFinishing else { return }
        finishWatchdog?.cancel()
        isFinishing = false
        let text = (finalizedSegments + [liveText])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        finalizedSegments = text.isEmpty ? [] : [text]
        liveText = ""
        status = .idle
        isActive = false
        isAppSession = false
        stopSessionLoop()
        if !text.isEmpty {
            TranscriptionHistoryStore.shared.add(text)
        }
        // The capture engine stays armed for the keyboard.
    }

    // MARK: - Audio + recognition

    /// Reflects the user's chosen dictation language (DictationSettings) in
    /// the shared recognizer. Safe to call anytime; a mid-session call is
    /// ignored (the recognizer is not touched while a session is live).
    func applyLocaleFromSettings() {
        guard !isActive, !isFinishing else { return }
        speechService.setLocale(DictationSettings.shared.locale)
    }

    private func startAudio() async {
        // The keyboard's globe key (or the app's language menu) may have
        // changed the dictation language — reflect it before this session
        // starts. Safe here: no recognition session is in flight yet.
        speechService.setLocale(DictationSettings.shared.locale)
        let micGranted = await Self.requestMicrophonePermission()
        let speechGranted = await Self.requestSpeechPermission()
        // A stop/cancel may have raced the permission prompts (first use).
        guard isActive else { return }  // cancelled while the prompt was up
        guard !isFinishing else {
            // The user asked to stop while the prompt was still up — finalize
            // immediately with whatever text we already have instead of
            // starting a session nobody is listening to.
            finishAndPublish()
            return
        }
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
            if !isAppSession {
                DictationSharedState.setStatus(.recording)
            }
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
            // Keep the capture engine armed — an empty dictation must not
            // cost a cold-launch + focus steal on the next attempt.
            DictationSharedState.reset(defaults: defaults)
            DictationSharedState.setStatus(.idle, defaults: defaults)
            standDown()
            return
        }
        finalText = text
        status = .ready
        TranscriptionHistoryStore.shared.add(text)
        DictationSharedState.clearPayload(defaults: defaults)
        DictationSharedState.setStatus(.ready, defaults: defaults)
        defaults.set(text, forKey: DictationSharedState.Key.finalText)
        defaults.set(Date.timeIntervalSinceReferenceDate, forKey: DictationSharedState.Key.readyAt)
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
        Self.logger.error("dictation failed: \(message)")
        if isAppSession {
            // App-side failure: surface in the app's own UI only, never in
            // the shared keyboard protocol.
            isActive = false
            isAppSession = false
            return
        }
        let defaults = AppGroup.defaults
        DictationSharedState.clearPayload(defaults: defaults)
        DictationSharedState.setStatus(.failed, defaults: defaults)
        defaults.set(message, forKey: DictationSharedState.Key.errorMessage)
        // Keep `.failed` so the main screen shows the error banner.
        standDown(resetStatus: false)
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
        // Liveness: the app is alive while a session runs — keep the
        // heartbeat fresh so the keyboard can detect death fast and never
        // cold-launches mid-session.
        DictationSharedState.touchAppHeartbeat()
        if isAppSession {
            // App-side sessions are stopped/cancelled by the app UI and
            // never touch the shared keyboard protocol.
            return
        }
        let defaults = AppGroup.defaults
        switch DictationSharedState.status(defaults) {
        case .requested:
            // A fresh keyboard request while we're busy PREEMPTS whatever
            // we're stuck on (see handleIncomingRequest) — this is what
            // makes a wedged app heal on the next mic tap.
            await handleIncomingRequest()
        case .recording:
            if DictationSharedState.cancelRequested(for: token, defaults: defaults) {
                cancelSession()
            } else if DictationSharedState.stopRequested(for: token, defaults: defaults) {
                beginFinish()
            } else if captureService.isRunning, !captureService.hasRecentBuffers(within: 3) {
                // The engine claims to run but stopped delivering audio
                // (interruption, route change, media reset, stolen session).
                handleSessionStall()
            } else {
                stallReArmAttemptedAt = nil
                if keyboardUnattendedInBackground {
                    // The ONLY listener of a backgrounded keyboard session is
                    // the keyboard itself. It's been gone past the grace
                    // period — finalize so partial text is preserved and the
                    // orphan can't wedge the app.
                    Self.logger.info("keyboard gone \(Self.presenceGrace)s — finalizing orphan session")
                    beginFinish()
                } else if Date().timeIntervalSince(lastSpeechAt) > Self.speechIdleTimeout {
                    // No REAL speech (silence buffers don't count) for a
                    // minute — finalize so the session can't leak.
                    Self.logger.info("no real speech for \(Self.speechIdleTimeout)s — auto-finalizing")
                    beginFinish()
                } else if Date().timeIntervalSince(sessionStartedAt) > Self.maxSessionDuration {
                    // Absolute cap: even a live-looking session must end.
                    Self.logger.info("session exceeded \(Self.maxSessionDuration)s cap — auto-finalizing")
                    beginFinish()
                }
            }
        case .transcribing:
            // The user cancelled while we were finalizing — abort (the
            // keyboard shows ✕ during this phase too). Otherwise: waiting
            // on the recognizer — the finish watchdog owns this.
            if DictationSharedState.cancelRequested(for: token, defaults: defaults) {
                Self.logger.info("cancel requested during finalizing — aborting session")
                cancelSession()
            } else {
                break
            }
        case .ready:
            // The keyboard inserted (status → .idle) or died before
            // consuming the result. Backgrounded with no keyboard: stand
            // down so the app can't sit active on a result nobody is
            // watching — the text STAYS in the store for the keyboard's
            // freshness-gated insert. Foreground, the app UI shows the
            // "Done" control, so wait for the user.
            if !isAppForeground, DictationSharedState.keyboardPresenceStale(Self.presenceGrace) {
                Self.logger.info("keyboard absent after .ready — standing down (result kept)")
                standDown(resetStatus: false)
            }
        case .failed:
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
            // A transcript change is real speech by definition.
            if self.isActive { self.lastSpeechAt = Date() }
            // App-side sessions must not pollute the shared keyboard protocol.
            guard !self.isAppSession else { return }
            let defaults = AppGroup.defaults
            defaults.set(text, forKey: DictationSharedState.Key.liveText)
            DictationSharedState.touchActivity(defaults: defaults)
        }
        speechService.onSegmentFinalized = { [weak self] text in
            guard let self else { return }
            self.finalizedSegments.append(text)
            self.liveText = ""
            if self.isActive { self.lastSpeechAt = Date() }
            if !self.isAppSession {
                let defaults = AppGroup.defaults
                defaults.set("", forKey: DictationSharedState.Key.liveText)
                DictationSharedState.touchActivity(defaults: defaults)
            }
            if self.isFinishing {
                if self.isAppSession {
                    self.finishAppSession()
                } else {
                    self.finishAndPublish()
                }
            }
        }
        speechService.onError = { [weak self] message in
            guard let self else { return }
            if self.isAppSession {
                // Surface in the app's own UI; never touch the keyboard protocol.
                self.stopSessionLoop()
                self.finishWatchdog?.cancel()
                self.speechService.cancelSession()
                self.errorMessage = message
                self.status = .failed
                self.isActive = false
                self.isAppSession = false
                return
            }
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
            guard let self, self.status == .recording else { return }
            if self.isAppSession {
                // Finalize the app-side session; the engine is force-re-armed
                // when the interruption ends.
                self.isFinishing = true
                self.status = .transcribing
                self.speechService.finishSession()
                self.finishWatchdog?.cancel()
                self.finishWatchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !Task.isCancelled, self.isActive, self.isAppSession, self.isFinishing else { return }
                    self.finishAppSession()
                }
            } else {
                self.beginFinish()
            }
        }
        captureService.onInterruptionEnded = { [weak self] in
            // The system gave the mic back. The engine may be stale-dead
            // with isRunning stuck true — force a clean re-arm. During a
            // live session recovery is owned by the session-loop stall
            // detection: a stop+start here could deactivate the audio
            // session and suspend a backgrounded app mid-finalize.
            guard let self, !self.isActive else { return }
            self.forceReArm()
        }
        captureService.onRouteChanged = { [weak self] in
            guard let self, !self.isActive else { return }
            self.forceReArm()
        }
        captureService.onMediaServicesReset = { [weak self] in
            // mediaserverd died: the engine object is already swapped by
            // AudioCaptureService. During a session the stall detection
            // restarts capture; while idle we re-arm directly.
            guard let self, !self.isActive else { return }
            self.forceReArm()
        }
    }

    private func publishLevel(_ level: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelPublish) >= 0.1 else { return }
        lastLevelPublish = now
        audioLevel = level
        // Only RMS above the noise floor counts as REAL speech. Silence
        // buffers keep arriving while the engine runs, so they must never
        // count as activity for the speech-idle finalize.
        if level > 0.02, isActive {
            lastSpeechAt = now
        }
        // App-side sessions must not pollute the shared keyboard protocol.
        guard !isAppSession else { return }
        let defaults = AppGroup.defaults
        defaults.set(level, forKey: DictationSharedState.Key.audioLevel)
        if !isActive, captureService.isRunning {
            // Armed-but-idle: keep the app-heartbeat fresh so the keyboard
            // knows the app is alive and won't cold-launch it.
            DictationSharedState.touchAppHeartbeat(defaults: defaults)
        }
    }

    // MARK: - Helpers

    private var isAppForeground: Bool {
        UIApplication.shared.applicationState == .active
    }

    /// Foreground or transitioning to it (cold-launch via URL). Audio can
    /// be (re)started in both cases.
    private var isAppForegroundish: Bool {
        UIApplication.shared.applicationState != .background
    }

    /// Ends a session and clears session state. By default the status is
    /// reset to `.idle` so the main screen's record button is usable again;
    /// failure paths pass `resetStatus: false` to keep `.failed` visible.
    private func standDown(resetStatus: Bool = true) {
        stopSessionLoop()
        finishWatchdog?.cancel()
        stallReArmAttemptedAt = nil
        isActive = false
        isAppSession = false
        isFinishing = false
        isColdStart = false
        token = ""
        finalizedSegments = []
        liveText = ""
        finalText = ""
        errorMessage = nil
        if resetStatus {
            status = .idle
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
