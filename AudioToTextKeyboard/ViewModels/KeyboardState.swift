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

    enum Phase: Equatable, CustomStringConvertible {
        case idle
        case starting
        case recording
        case transcribing
        case ready
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "idle"
            case .starting: return "starting"
            case .recording: return "recording"
            case .transcribing: return "transcribing"
            case .ready: return "ready"
            case .failed(let message): return "failed(\(message))"
            }
        }
    }

    // MARK: - Published state

    @Published var phase: Phase = .idle
    @Published var liveTranscript = ""
    @Published var audioLevel: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var hasFullAccess = false
    /// The final text of the last completed session. Kept so the overlay can
    /// offer a manual "Insert" when an auto-insert couldn't be verified.
    @Published var finalText = ""
    /// True when the last auto-insert could not be verified against the
    /// document — the overlay shows a manual insert button as a fallback so
    /// text that was seen is never lost.
    @Published var needsManualInsert = false
    /// The dictation language shown on the keyboard's globe key (e.g. "EN",
    /// "中"). Updated when the key cycles the language.
    @Published var dictationLocaleCode = DictationSettings.shared.shortCode

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
    /// Throttle for the presence beacon (the app's orphan finalizer reads it).
    private var lastPresenceWrite: Date = .distantPast
    /// True while the keyboard is on screen. Inserts are only attempted when
    /// visible — a `.ready` polled during the dismissal transition would
    /// otherwise insert into a detached input session and lose the text.
    private var isVisible = false
    /// True when the app was alive (fresh heartbeat) when `startDictation`
    /// ran. If the keyboard is then dismissed before the app acknowledged,
    /// the request is abandoned on purpose (the app discards it). When the
    /// app was dead, dismissal is usually the cold-launch handoff — the
    /// request must survive so the app can adopt it on launch.
    private var appWasAliveAtStart = false

    // MARK: - Timings

    private let pollInterval: TimeInterval = 0.1
    /// Cold-launch delay when the app was never seen (or hasn't been alive
    /// for a long while): it's almost certainly terminated, so launch it fast.
    private let coldLaunchDelay: TimeInterval = 1.5
    /// A heartbeat younger than this counts as "the app is (or was very
    /// recently) running" — trust the Darwin wake instead of cold-launching.
    private let coldLaunchDelayWhenAppKnown: TimeInterval = 4.0
    private let startTimeout: TimeInterval = 10
    /// Generous on purpose: the app's own finalize watchdog is ~3s, so this
    /// must never race it.
    private let transcribeTimeout: TimeInterval = 25

    /// A FRESH app-heartbeat means the app is alive AND can serve a request
    /// in the background (its engine is armed, or a session is running). In
    /// that case a Darwin ping will wake it WITHOUT stealing the foreground,
    /// so give the wake time to land. A stale/absent heartbeat means the app
    /// is dead or unarmed — cold-launch it fast (the only way to re-arm).
    private var appIsAlive: Bool {
        guard let date = DictationSharedState.appHeartbeatDate else { return false }
        return Date().timeIntervalSince(date) < 3
    }

    private var effectiveColdLaunchDelay: TimeInterval {
        appIsAlive ? coldLaunchDelayWhenAppKnown : coldLaunchDelay
    }

    /// The app's session loop (or armed engine) keeps its heartbeat fresh;
    /// a stale one means the app died (or was force-quit).
    private func appHeartbeatStale(_ threshold: TimeInterval = 8) -> Bool {
        guard let date = DictationSharedState.appHeartbeatDate else { return true }
        return Date().timeIntervalSince(date) > threshold
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
        case .idle, .failed, .starting:
            // `.starting` too: tapping the mic again while a request is
            // pending writes a FRESH session + generation. That is the
            // keyboard's guaranteed reset — the app treats any newer
            // request as a preemption of whatever it is stuck on, so a
            // wedged app heals on the very next tap.
            break
        case .recording, .transcribing, .ready:
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
        finalText = ""
        needsManualInsert = false
        phase = .starting
        liveTranscript = ""
        audioLevel = 0
        elapsed = 0

        // Snapshot liveness BEFORE reset() — reset wipes the heartbeat key,
        // and the app (if alive) only re-touches it after the ping lands.
        let delay = effectiveColdLaunchDelay
        appWasAliveAtStart = appIsAlive
        // Fresh request: token + .requested, then wake the app.
        myToken = UUID().uuidString
        let defaults = AppGroup.defaults
        DictationSharedState.reset(defaults: defaults)
        defaults.set(myToken, forKey: DictationSharedState.Key.sessionToken)
        // The keyboard's OWN clock. Every timeout that matters — our
        // `.starting` timeout and the app's request TTL — reads this, so a
        // wedged app can never keep a dead request alive.
        defaults.set(Date.timeIntervalSinceReferenceDate, forKey: DictationSharedState.Key.requestedAt)
        DictationSharedState.setStatus(.requested, defaults: defaults)
        Self.logger.info("startDictation: requested (token \(self.myToken.prefix(8)))")

        DarwinNotifications.post()
        startPolling(generation: generation)

        // If the app doesn't acknowledge quickly, it isn't running (or is
        // suspended — Darwin can't wake it) → cold-launch via URL. When the
        // app is alive (fresh heartbeat), wait longer so the Darwin wake
        // lands in the background instead of stealing the foreground.
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
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
            DictationSharedState.requestStop(for: myToken, defaults: defaults)
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
                        self.finalText = text
                        self.needsManualInsert = false
                        Self.logger.info("stopDictation watchdog: late .ready — inserting final text")
                        self.insertAndVerify(text)
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
        if current == .requested || current == .recording || current == .transcribing {
            // Cancel whatever session the store currently names — that is
            // the session the app is (or will be) serving. `.transcribing`
            // too: a cancel during finalizing must abort, not leave a
            // `.ready` that surprise-inserts later.
            let target = DictationSharedState.sessionToken(defaults)
            DictationSharedState.requestCancel(for: target, defaults: defaults)
            DictationSharedState.touchActivity(defaults: defaults)
            DarwinNotifications.post()
        } else if current == .ready {
            // The user cancelled from the "insert" overlay — drop the
            // pending result so it can't surprise-insert later.
            DictationSharedState.clearFinalResult(defaults: defaults)
            DictationSharedState.setStatus(.idle, defaults: defaults)
        }
        resetToIdle()
    }

    /// Called from `viewWillAppear`.
    func keyboardDidAppear() {
        isVisible = true
        // The app's menu may have changed the language / cycle list in
        // another process — reflect it on the globe key.
        DictationSettings.shared.reloadFromDefaults()
        dictationLocaleCode = DictationSettings.shared.shortCode
    }

    /// Called from `viewWillDisappear`.
    func keyboardWillDisappear() {
        isVisible = false
    }

    /// Called from `viewWillDisappear`. A LIVE session lives in the app and
    /// keeps recording — never touch it here. A `.starting` request is LEFT
    /// in the shared store if the app was dead (cold-launch handoff in
    /// progress — it must still be able to adopt it when it launches); if
    /// the app was alive it is cancelled so it can't record into a void.
    /// Requests the app never picks up expire on its side (`.requested`
    /// older than 30s is discarded), so they can't dangle into a surprise
    /// session.
    func cancelPendingRequest() {
        guard phase == .starting else { return }
        sessionGeneration += 1
        watchdogTask?.cancel()
        finishWatchdog?.cancel()
        stopPolling()
        if appWasAliveAtStart {
            // The app is alive in the background: it WILL adopt the request,
            // so tell it the user walked away. Cancel whatever the store
            // names — if the app already adopted our request, that session
            // must not record into a void (the orphan that wedges the app).
            let defaults = AppGroup.defaults
            let shared = DictationSharedState.status(defaults)
            if shared == .requested || shared == .recording {
                let target = DictationSharedState.sessionToken(defaults)
                DictationSharedState.requestCancel(for: target, defaults: defaults)
                DictationSharedState.touchActivity(defaults: defaults)
                DarwinNotifications.post()
            }
        }
        resetToIdle()
    }

    /// Called from `viewWillAppear`: the keyboard process may have been
    /// suspended/killed while the app was foreground (cold launch) — re-attach
    /// to the live session or insert immediately if it already finished.
    func recoverKeyboardSession() {
        refreshFullAccessStatus()
        // An overlay phase is a LIVE, visible session — leave it alone. All
        // other phases (including `.starting`: we may have been suspended
        // mid-start with dead timers) re-evaluate the shared state below.
        switch phase {
        case .idle, .failed, .starting:
            break
        case .recording, .transcribing, .ready:
            return
        }
        let defaults = AppGroup.defaults
        let status = DictationSharedState.status(defaults)
        Self.logger.info("recoverKeyboardSession: phase=\(self.phase) shared=\(status.rawValue)")

        switch status {
        case .requested:
            // A request is still pending (we died/slept before the app
            // adopted). Adopt it and resume with a FRESH request clock —
            // both our timeout and the app's TTL read it, so a resumed
            // request gets its full timeout instead of failing on a stale
            // timestamp from before the suspension.
            myToken = DictationSharedState.sessionToken(defaults)
            guard !myToken.isEmpty else {
                resetToIdle()
                return
            }
            defaults.set(Date.timeIntervalSinceReferenceDate, forKey: DictationSharedState.Key.requestedAt)
            sessionGeneration += 1
            let generation = sessionGeneration
            insertedFinalText = false
            phase = .starting
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
            // The app adopted our request (or an orphan session) while we
            // slept — resume watching it and keep it alive via presence.
            sessionGeneration += 1
            let generation = sessionGeneration
            myToken = DictationSharedState.sessionToken(defaults)
            insertedFinalText = false
            phase = (status == .recording) ? .recording : .transcribing
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
            let fresh = DictationSharedState.readyAtDate.map {
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
                finalText = text
                needsManualInsert = false
                Self.logger.info("recoverKeyboardSession: inserting final text")
                insertAndVerify(text)
            } else {
                phase = .idle
            }
        case .failed:
            let message = DictationSharedState.errorMessage(defaults)
            DictationSharedState.reset(defaults: defaults)
            DictationSharedState.setStatus(.idle, defaults: defaults)
            fail(message.isEmpty ? "Dictation failed." : message)
        case .idle:
            if phase == .starting {
                // We were starting but the app (or a reset) cleared the
                // request while we slept — don't sit on a dead `.starting`.
                fail("Dictation isn't connected. Make sure the app is installed and open it once, then try again.")
            }
        }
    }

    // MARK: - Keyboard actions (delegate to the controller)

    func insertText(_ text: String) {
        controller?.insertText(text)
    }

    /// Cycles the dictation language to the next one in the ENABLED cycle.
    /// The choice is persisted in the App Group and the app is pinged so a
    /// live app applies it immediately — the NEXT dictation (app or
    /// keyboard) uses the new language. With two enabled languages this
    /// simply toggles between them.
    func cycleDictationLanguage() {
        DictationSettings.shared.reloadFromDefaults()
        DictationSettings.shared.cycleToNextLocale()
        dictationLocaleCode = DictationSettings.shared.shortCode
        DarwinNotifications.post()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func deleteBackward() {
        controller?.deleteBackward()
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

    /// Marks the keyboard present for the app's orphan finalizer (a
    /// backgrounded keyboard session whose presence goes stale gets
    /// finalized by the app). Throttled: shared-defaults writes every poll
    /// tick are wasteful, and 1s is far under the app's grace period.
    private func touchPresence() {
        let now = Date()
        guard now.timeIntervalSince(lastPresenceWrite) >= 1 else { return }
        lastPresenceWrite = now
        DictationSharedState.touchKeyboardPresence()
    }

    private func pollOnce(generation: Int) {
        guard generation == sessionGeneration else { return }
        let defaults = AppGroup.defaults
        let shared = DictationSharedState.status(defaults)
        audioLevel = DictationSharedState.audioLevel(defaults)
        // Mark the keyboard present while it watches the session: the app
        // finalizes an orphan session (keyboard died / user left) as soon
        // as this goes stale.
        touchPresence()

        switch shared {
        case .requested:
            if phase == .starting,
               let requestedAt = DictationSharedState.requestedAtDate(defaults) {
                // Timeout from the KEYBOARD's own request clock — a wedged
                // app cannot refresh this, so it always fires and the UI
                // can never hang on "Starting…" forever.
                if Date().timeIntervalSince(requestedAt) > startTimeout {
                    fail("Dictation isn't connected. Make sure the app is installed and open it once, then try again.")
                }
            }
        case .recording:
            if phase == .starting {
                phase = .recording
                startElapsedTimer()
            }
            // The app's session loop keeps its heartbeat fresh every 250ms.
            // A stale one means it died (or was force-quit) — fail fast so
            // the user isn't stuck watching a dead session.
            if appHeartbeatStale() {
                fail("The app closed mid-dictation. Open it once, then try again.")
                return
            }
            updateLiveText(DictationSharedState.liveText(defaults))
            // No keyboard-side idle auto-stop: the app owns timeouts now
            // (real-speech idle, keyboard presence, session cap) and
            // publishes `.ready` itself; we just insert it.
        case .transcribing:
            phase = .transcribing
            // The app is finalizing; its session loop keeps the heartbeat
            // fresh. If it died, nothing will ever arrive — fail fast.
            if appHeartbeatStale() {
                fail("The app closed while finalizing. Open it once, then try again.")
                return
            }
        case .ready:
            guard isVisible else { return }
            let text = DictationSharedState.finalText(defaults)
            if !text.isEmpty, !insertedFinalText {
                insertedFinalText = true
                finalText = text
                needsManualInsert = false
                insertAndVerify(text)
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

    // MARK: - Insertion

    /// Inserts the last final text (manual fallback from the overlay when an
    /// auto-insert could not be verified).
    func insertFinalText() {
        let text = finalText
        guard !text.isEmpty else { return }
        insertAndVerify(text)
    }

    /// Inserts `text` and verifies it landed before clearing the shared
    /// result. The host gets a runloop turn to commit; if the document
    /// doesn't show the text (field switched away, keyboard dismissed
    /// mid-insert, stale proxy), the shared result is KEPT and the overlay
    /// offers a manual "Insert" — text the user already saw must never be
    /// silently lost to a dropped insert.
    private func insertAndVerify(_ text: String) {
        controller?.insertText(text)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.verifyInsert(text) {
                self.needsManualInsert = false
                self.consumeReadyResult()
            } else {
                Self.logger.warning("insert not verified — keeping text for manual insert")
                self.needsManualInsert = true
                self.phase = .ready
                self.liveTranscript = ""
                // Polling continues; `insertedFinalText` prevents a re-insert.
            }
        }
    }

    private func verifyInsert(_ text: String) -> Bool {
        guard isVisible else { return false }
        guard let controller else { return false }
        guard let before = controller.textDocumentProxy.documentContextBeforeInput else {
            // No context to check against (secure field, detached input
            // session) — assume it landed to avoid duplicate inserts.
            return true
        }
        return before.hasSuffix(text)
    }

    /// The result was consumed: clear it from the shared store and show the
    /// brief "Inserted" state before returning to idle.
    private func consumeReadyResult() {
        let defaults = AppGroup.defaults
        DictationSharedState.clearFinalResult(defaults: defaults)
        DictationSharedState.setStatus(.idle, defaults: defaults)
        phase = .ready
        liveTranscript = ""
        stopPolling()
        scheduleIdle(after: 1.5)
        Self.logger.info("final text inserted and verified")
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

    /// The keyboard is giving up on the session currently in the store
    /// (timeout, app death, full-access refusal). Tag-cancel it so the app
    /// can never adopt/keep recording into a void after the keyboard walked
    /// away. No-op when the store holds no live session.
    private func abandonSharedSession() {
        let defaults = AppGroup.defaults
        let shared = DictationSharedState.status(defaults)
        guard shared == .requested || shared == .recording || shared == .transcribing else { return }
        let target = DictationSharedState.sessionToken(defaults)
        guard !target.isEmpty else { return }
        DictationSharedState.requestCancel(for: target, defaults: defaults)
        DictationSharedState.touchActivity(defaults: defaults)
        DarwinNotifications.post()
    }

    private func fail(_ message: String) {
        Self.logger.error("fail: \(message)")
        // This keyboard session is over — make sure the app never keeps the
        // underlying shared session running for nobody.
        abandonSharedSession()
        // Copy the error to the pasteboard so the user can paste it back to
        // the developer without typing it.
        let shared = DictationSharedState.status()
        let dump = """
        [AudioToTextKeyboard] \(message)
        phase=\(phase)
        sharedStatus=\(shared.rawValue)
        token=\(myToken.prefix(8))
        lastActivity=\(DictationSharedState.lastActivityDate.map { String(format: "%.1fs ago", Date().timeIntervalSince($0)) } ?? "nil")
        appHeartbeat=\(DictationSharedState.appHeartbeatDate.map { String(format: "%.1fs ago", Date().timeIntervalSince($0)) } ?? "nil")
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
        finalText = ""
        needsManualInsert = false
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
