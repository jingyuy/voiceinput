import AVFoundation
import Foundation
import os
import UIKit

/// Captures microphone audio with `AVAudioEngine` and forwards raw PCM
/// buffers plus a normalized level signal to callbacks for live processing.
///
/// The service is deliberately stateless: it owns no transcription logic,
/// so it can be reused or replaced (e.g. with a custom audio pipeline)
/// without touching the UI.
final class AudioCaptureService {

    private static let logger = Logger(
        subsystem: "com.example.AudioToTextOnMobile.shared",
        category: "AudioCapture"
    )

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case engineStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let error):
                return "Mic start failed: \(AudioCaptureService.errorDetail(error))"
            }
        }
    }

    /// Walks the NSError chain to the deepest cause and returns a compact
    /// "domain code" string that survives UI truncation. The full chain is
    /// copied to the pasteboard (works with Full Access) for reading later,
    /// unless `copyToPasteboard` is false — callers that already placed a
    /// richer diagnostic (e.g. the full per-attempt log in `start()`) must
    /// pass false so it isn't clobbered.
    static func errorDetail(_ error: Error, copyToPasteboard: Bool = true) -> String {
        var chain: [NSError] = []
        var ns = error as NSError
        chain.append(ns)
        while let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying !== ns {
            chain.append(underlying)
            ns = underlying
        }
        // Deepest cause is the real one (e.g. com.apple.coreaudio.avfaudio
        // 561145910 '!rec' = recording not permitted).
        let deepest = chain.last!
        let full = chain
            .map { "\($0.domain) code=\($0.code): \($0.localizedDescription)" }
            .joined(separator: "\n")
        if copyToPasteboard {
            UIPasteboard.general.string = full
        }
        return "\(deepest.domain) code=\(deepest.code)"
    }

    // MARK: - Callbacks

    /// Called on an internal audio queue with every captured PCM buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called on the main queue at ~30 Hz with a normalized level in 0...1.
    var onLevel: ((Float) -> Void)?

    /// Called on the main queue when the system interrupts audio capture
    /// (e.g. an incoming phone call).
    var onInterruption: (() -> Void)?

    /// Called on the main queue when an interruption ends and the session
    /// may resume (used to re-arm the always-on capture engine).
    var onInterruptionEnded: (() -> Void)?

    /// Called on the main queue when the audio route changed (headphones
    /// plugged/unplugged, Bluetooth, etc.).
    var onRouteChanged: (() -> Void)?

    /// Called on the main queue when mediaserverd reset — the engine object
    /// is dead and must be recreated.
    var onMediaServicesReset: (() -> Void)?

    /// The engine is recreated fresh inside `tryStart` AFTER the audio
    /// session is configured — an engine created early (e.g. at init) can
    /// lock in a 2ch input-node format that the mono hardware then rejects
    /// with kAudioUnitErr_UnsupportedFormat ('what').
    private var audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private var lastLevelDispatchTime: CFAbsoluteTime = 0
    private let levelDispatchInterval: CFAbsoluteTime = 1.0 / 30.0
    private var lastBufferDiagTime: CFAbsoluteTime = 0
    /// True while the capture engine is running. The engine is kept running
    /// almost permanently (always-armed mic) so dictation can start instantly
    /// in the background without re-initializing the input unit.
    private(set) var isRunning = false
    /// Last time a PCM buffer arrived (any thread). Lets the arm-watcher
    /// detect an engine that claims to run but is actually dead (session
    /// stolen by an interruption / route change / media reset).
    private(set) var lastBufferAt = Date.distantPast
    /// When the current engine's `start()` succeeded. A fresh engine needs
    /// tens of milliseconds before its FIRST buffer can arrive, so a
    /// no-buffers check alone cannot judge a just-armed engine — callers
    /// must give it a grace period (see `armedEngineIsFresh`).
    private(set) var lastEngineStartAt = Date.distantPast
    /// When the last audio interruption ended — the system then permits a
    /// background re-arm (unlike the general '!int' 560557684 ban).
    private(set) var lastInterruptionEndedAt = Date.distantPast
    /// The attempt configuration currently applied to the session (nil while
    /// no engine is running). Set when an engine start succeeds, cleared
    /// whenever the engine is torn down.
    private var activeAttempt: Attempt?
    /// True while a live dictation session has asked the system to duck other
    /// apps' audio (background music plays softly instead of into the mic).
    private(set) var isOtherAudioDucked = false
    /// True while the silent keepalive session is running (see
    /// `startKeepAlive`). Mutually exclusive with `isRunning` — never both.
    private(set) var isKeepingAlive = false
    private var keepAliveEngine: AVAudioEngine?
    private var keepAlivePlayer: AVAudioPlayerNode?
    /// True while THIS process holds the audio session active (armed capture
    /// or silent keepalive). The session is deliberately kept active and is
    /// NEVER deactivated for idle transitions (armed ↔ keepalive): a
    /// backgrounded app whose session goes inactive is suspended within
    /// seconds, and repeated background deactivate/reactivate cycles look
    /// like session-churning to the watchdog (the app visibly "stops" after
    /// a few). False when the system took the session (interruption began,
    /// media-services reset) or before anything has activated it.
    private var sessionActive = false
    /// The capture configuration that most recently started successfully.
    /// Survives teardown so a background keepalive→mic swap can re-apply the
    /// exact config the hardware accepted without re-running the whole
    /// attempt chain. Cleared on media-services reset.
    private var lastWinningAttempt: Attempt?

    init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began:
                DictationSharedState.diag("interruption .began — session deactivated by system")
                // The system deactivated our session for the interruption.
                self.sessionActive = false
                self.onInterruption?()
            case .ended:
                DictationSharedState.diag("interruption .ended — session needs reactivation")
                self.lastInterruptionEndedAt = Date()
                // The session was deactivated at .began — a resume needs a
                // fresh activation (startKeepAlive / start do that when
                // sessionActive is false).
                self.sessionActive = false
                // If the interruption hit while we were silently keeping this
                // process alive, bring that session back before the
                // coordinator reconciles the idle audio state.
                self.repairKeepAliveIfNeeded()
                self.onInterruptionEnded?()
            @unknown default:
                break
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] note in
            // A route change can invalidate the keepalive engine (new sample
            // rate / route) — rebuild it if it died. No-op when capture is
            // armed (the coordinator rebuilds that on route change instead).
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "?"
            DictationSharedState.diag("route change (reason \(reason))")
            self?.repairKeepAliveIfNeeded()
            self?.onRouteChanged?()
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DictationSharedState.diag("media services reset — all engines dropped")
            // mediaserverd died: every engine object is garbage. Drop them
            // now so a later start() rebuilds from scratch.
            self.audioEngine = AVAudioEngine()
            self.isRunning = false
            self.activeAttempt = nil
            self.isOtherAudioDucked = false
            self.sessionActive = false
            self.lastWinningAttempt = nil
            if self.isKeepingAlive {
                // The silent keepalive died with the server — rebuild it so
                // this process isn't suspended while another app plays
                // (startKeepAlive tears the stale engine down and rebuilds).
                self.keepAliveEngine = nil
                self.keepAlivePlayer = nil
                self.startKeepAlive()
            }
            self.onMediaServicesReset?()
        }
    }

    /// True when a PCM buffer arrived within `window` seconds — i.e. the
    /// engine is genuinely delivering audio, not just claiming to run.
    func hasRecentBuffers(within window: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastBufferAt) < window
    }

    /// The real `AVAudioEngine.isRunning` — distinguishes a genuinely
    /// running engine from a stale-true `isRunning` flag on a dead one.
    var engineActuallyRunning: Bool { audioEngine.isRunning }

    // MARK: - Capture control

    /// One candidate configuration for the audio engine.
    private struct Attempt {
        let name: String
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let format: AVAudioFormat?
        /// Apply preferred sample rate / input channels / IO buffer before
        /// activating the session and creating the engine.
        let prefs: Bool
        /// Enable voice processing on the input node (VPIO) — requires the
        /// playAndRecord category and typically unlocks 48 kHz mono input.
        let voiceProcessing: Bool
    }

    /// Starts capturing from the microphone. Throws if no configuration
    /// could start the engine.
    ///
    /// The keyboard extension shares the audio hardware with the host app,
    /// so the input unit can reject certain category/mode/format combos
    /// (kAudioUnitErr_FormatNotSupported / 'what'). Try a chain of configs
    /// and use the first that starts. Every AVFoundation call runs inside
    /// an ObjC @try so an NSException can never crash the extension.
    ///
    /// Key fix: each attempt creates a FRESH AVAudioEngine AFTER the session
    /// is configured. An engine whose input node was first accessed in the
    /// host's default session state caches a 2ch format; the real hardware
    /// input is 1ch, so the input unit rejects the engine with 'what'.
    func start() throws {
        guard !isRunning else { return }
        // Entering capture mode always exits the silent keepalive first —
        // both claim the same session and must never run together.
        if isKeepingAlive {
            stopKeepAlive()
        }
        let attempts: [Attempt] = [
            // The engine is ALWAYS ARMED while the app is alive, so an
            // exclusive (non-mixing) session interrupts whatever the user
            // is listening to — music goes silent for as long as the app
            // stays open. `.mixWithOthers` (honored only for
            // `.playAndRecord` / `.playback`) keeps other apps' audio
            // playing while the mic stays warm, so it is tried FIRST. The
            // `.record`-category attempts remain below as fallbacks for
            // hardware that rejects playAndRecord.
            Attempt(name: "playAndRecord/measurement/speaker+mix", category: .playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers], format: nil, prefs: false, voiceProcessing: false),
            Attempt(name: "playAndRecord/default/speaker+mix", category: .playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers], format: nil, prefs: false, voiceProcessing: false),
            Attempt(name: "record/measurement/duck", category: .record, mode: .measurement, options: [.duckOthers], format: nil, prefs: false, voiceProcessing: false),
            Attempt(name: "record/measurement/none", category: .record, mode: .measurement, options: [], format: nil, prefs: false, voiceProcessing: false),
            Attempt(name: "record/default/none", category: .record, mode: .default, options: [], format: nil, prefs: false, voiceProcessing: false),
            Attempt(name: "playAndRecord/default/speaker", category: .playAndRecord, mode: .default, options: [.defaultToSpeaker], format: nil, prefs: false, voiceProcessing: false),
            Attempt(name: "playAndRecord/measurement/speaker", category: .playAndRecord, mode: .measurement, options: [.defaultToSpeaker], format: nil, prefs: false, voiceProcessing: false),
            Attempt(name: "playAndRecord/voiceChat/speaker", category: .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker], format: nil, prefs: false, voiceProcessing: false),
            Attempt(name: "record/measurement/prefs", category: .record, mode: .measurement, options: [], format: nil, prefs: true, voiceProcessing: false),
            Attempt(name: "playAndRecord/default/prefs", category: .playAndRecord, mode: .default, options: [.defaultToSpeaker], format: nil, prefs: true, voiceProcessing: false),
            Attempt(name: "playAndRecord/voiceChat/prefs", category: .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker], format: nil, prefs: true, voiceProcessing: false),
            Attempt(name: "playAndRecord/default/VPIO", category: .playAndRecord, mode: .default, options: [.defaultToSpeaker], format: nil, prefs: false, voiceProcessing: true),
            Attempt(name: "playAndRecord/voiceChat/VPIO", category: .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker], format: nil, prefs: false, voiceProcessing: true),
            // Deliberately wrong rate — should raise the informative
            // NSException "Failed to create tap due to format mismatch".
            Attempt(name: "record/measurement/16k", category: .record, mode: .measurement, options: [],
                    format: Self.floatFormat(rate: 16_000, channels: 1), prefs: false, voiceProcessing: false),
        ]

        var log: [String] = []
        var lastError: Error?
        var nodeOut = ""
        var nodeIn = ""
        for attempt in attempts {
            var exceptionReason: NSString?
            var attemptError: Error?
            var started = false
            ObjCExceptionCatcher.catchException({
                do {
                    try self.tryStart(attempt, nodeOut: &nodeOut, nodeIn: &nodeIn, deactivateFirst: !self.sessionActive)
                    started = true
                } catch {
                    attemptError = error
                }
            }, outExceptionReason: &exceptionReason)

            if started {
                UIPasteboard.general.string = "SUCCESS: \(attempt.name)\nnodeOut=\(nodeOut)\nnodeIn=\(nodeIn)\n" + log.joined(separator: "\n")
                isRunning = true
                Self.logger.info("audio engine started with: \(attempt.name)")
                return
            }
            if let exceptionReason {
                // AVFoundation raised an NSException (e.g. node access on a
                // broken engine) — capture it so the keyboard doesn't die.
                let reason = String(exceptionReason)
                lastError = NSError(domain: "AVFoundation.Exception", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Exception: \(reason)"])
                log.append("\(attempt.name): NSException \(reason)")
                Self.logger.error("attempt '\(attempt.name)' raised: \(reason)")
            } else if let attemptError {
                lastError = attemptError
                let detail = Self.errorDetail(attemptError)
                log.append("\(attempt.name): \(detail) nodeOut=\(nodeOut) nodeIn=\(nodeIn)")
                Self.logger.error("attempt '\(attempt.name)' failed: \(detail)")
            }
            teardownEngine()
        }

        // All attempts failed — dump the full environment + per-attempt
        // errors to the pasteboard so we can diagnose on the Mac.
        let full = "ALL ATTEMPTS FAILED\n" + log.joined(separator: "\n") + "\n---\n" + diagnostics()
        UIPasteboard.general.string = full
        Self.logger.error("\(full)")
        throw CaptureError.engineStartFailed(lastError ?? NSError(domain: "AudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio configuration could start"]))
    }

    /// Applies one configuration and starts the engine, installing the tap.
    /// Creates a FRESH engine after the session is configured so the input
    /// node's cached format reflects the active hardware (see `start()`).
    private func tryStart(_ attempt: Attempt, nodeOut: inout String, nodeIn: inout String, deactivateFirst: Bool) throws {
        let session = audioSession
        if deactivateFirst {
            // Only when we do NOT already hold the session active (fresh
            // launch, after an interruption/reset). When the session is
            // already active (armed or keepalive), deactivating it here is
            // exactly what lets a backgrounded app get suspended.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
        try session.setCategory(attempt.category, mode: attempt.mode, options: attempt.options)
        if attempt.prefs {
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredInputNumberOfChannels(1)
            try? session.setPreferredIOBufferDuration(0.02)
        }
        try session.setActive(true)
        sessionActive = true

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        if attempt.voiceProcessing {
            try inputNode.setVoiceProcessingEnabled(true)
        }
        nodeOut = "\(inputNode.outputFormat(forBus: 0))"
        nodeIn = "\(inputNode.inputFormat(forBus: 0))"
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: attempt.format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        lastEngineStartAt = Date()
        DictationSharedState.diag("engine running: \(attempt.name) (deactivateFirst=\(deactivateFirst))")
        // Remember the winning configuration so a later option swap (duck
        // other audio during live dictation) changes ONLY the options and
        // never the category/mode the hardware accepted.
        activeAttempt = attempt
        // ... and so a background keepalive→mic swap can re-apply it
        // without re-running the whole attempt chain.
        lastWinningAttempt = attempt
    }

    /// Stops the engine and removes the tap without touching the session
    /// (used between failed attempts). Exception-safe: removing a tap from
    /// a broken engine can raise an NSException.
    private func teardownEngine() {
        var exceptionReason: NSString?
        ObjCExceptionCatcher.catchException({
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine.stop()
        }, outExceptionReason: &exceptionReason)
        if let exceptionReason {
            Self.logger.warning("teardownEngine raised: \(String(exceptionReason)) — recreating engine")
        }
        // Always hand back a FRESH engine so the next start never touches a
        // broken one.
        audioEngine = AVAudioEngine()
        activeAttempt = nil
        isOtherAudioDucked = false
    }

    private static func floatFormat(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)
    }

    /// Full environment snapshot for diagnosis. Uses the EXISTING engine's
    /// node — never create a throwaway AVAudioEngine here, that raises
    /// inside a sandboxed extension.
    private func diagnostics() -> String {
        let session = audioSession
        let node = audioEngine.inputNode
        let out = node.outputFormat(forBus: 0)
        let inn = node.inputFormat(forBus: 0)
        return """
        recordPermission=\(session.recordPermission.rawValue)
        isInputAvailable=\(session.isInputAvailable)
        sessionSampleRate=\(session.sampleRate)
        outputFormat=\(out.sampleRate)Hz \(out.channelCount)ch common=\(out.commonFormat.rawValue) interleaved=\(out.isInterleaved)
        inputFormat=\(inn.sampleRate)Hz \(inn.channelCount)ch common=\(inn.commonFormat.rawValue) interleaved=\(inn.isInterleaved)
        inputDataSources=\(String(describing: session.inputDataSources))
        preferredInput=\(String(describing: session.preferredInput))
        currentRoute=\(session.currentRoute)
        """
    }

    /// Compact one-line environment summary for on-screen display.
    func environmentSummary() -> String {
        let session = audioSession
        let node = audioEngine.inputNode.outputFormat(forBus: 0)
        return "node=\(node.sampleRate)/\(node.channelCount) sess=\(session.sampleRate) in=\(session.isInputAvailable ? 1 : 0) perm=\(session.recordPermission.rawValue)"
    }

    /// Stops capturing and releases the microphone, deactivating the audio
    /// session. Only for real release points in the FOREGROUND — never use
    /// this for an idle transition while the process may be backgrounded
    /// (use `stopCaptureKeepingSession` + a hot swap instead).
    func stop() {
        guard isRunning else { return }
        DictationSharedState.diag("capture stop() — full release, session DEACTIVATED")
        teardownEngine()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        sessionActive = false
    }

    /// Stops the capture engine but keeps the audio session ACTIVE. The
    /// engine must be replaced immediately (keepalive or a fresh capture
    /// start) so a backgrounded process never loses its active session.
    func stopCaptureKeepingSession() {
        guard isRunning else { return }
        DictationSharedState.diag("capture engine stopped — session KEPT active")
        teardownEngine()
        isRunning = false
    }

    // MARK: - Silent keepalive (stay alive without the mic)

    /// Starts a silent `.playback` session (`.mixWithOthers`) that renders
    /// digital silence. A backgrounded app only stays alive while its audio
    /// session is active AND actually running (UIBackgroundModes audio) —
    /// but an armed microphone is exactly what silences/degrades other
    /// apps' audio. When another app is playing we therefore trade the mic
    /// for this silent session: this process keeps running (instant
    /// keyboard adoption is preserved once the mic re-arms) while the other
    /// app's audio plays clean and untouched. Mutually exclusive with
    /// capture (`start`/`stop`). Idempotent and rebuildable: if the flag is
    /// set but the engine died (interruption / media reset), it rebuilds.
    func startKeepAlive() {
        if isKeepingAlive, keepAliveEngine?.isRunning == true { return }
        if isRunning {
            // Never hold the mic and the keepalive at once — same session.
            // Hot swap: the session stays active the whole time.
            stopCaptureKeepingSession()
        }
        // Drop any stale engine before rebuilding.
        keepAlivePlayer?.stop()
        keepAliveEngine?.stop()
        keepAlivePlayer = nil
        keepAliveEngine = nil
        var exceptionReason: NSString?
        ObjCExceptionCatcher.catchException({
            do {
                try self.audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                if !self.sessionActive {
                    try self.audioSession.setActive(true)
                    self.sessionActive = true
                }
                let engine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                engine.attach(player)
                // Resolve the format AFTER activation so it matches the
                // current hardware route (same trap as the capture engine).
                let format = engine.outputNode.inputFormat(forBus: 0)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                    Self.logger.error("keepalive: could not allocate silent buffer")
                    self.isKeepingAlive = false
                    return
                }
                buffer.frameLength = 4096
                // AVAudioPCMBuffer memory is not guaranteed zeroed — make the
                // loop genuinely silent.
                let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for buf in abl {
                    if let data = buf.mData {
                        memset(data, 0, Int(buf.mDataByteSize))
                    }
                }
                engine.connect(player, to: engine.mainMixerNode, format: format)
                engine.prepare()
                try engine.start()
                player.scheduleBuffer(buffer, at: nil, options: [.loops])
                player.play()
                self.keepAliveEngine = engine
                self.keepAlivePlayer = player
                self.isKeepingAlive = true
                DictationSharedState.diag("keepalive STARTED (silent mixable playback)")
                Self.logger.info("keepalive started (silent mixable playback)")
            } catch {
                self.isKeepingAlive = false
                DictationSharedState.diag("keepalive start FAILED: \(error.localizedDescription)")
                Self.logger.error("keepalive start failed: \(error.localizedDescription)")
            }
        }, outExceptionReason: &exceptionReason)
        if let exceptionReason {
            isKeepingAlive = false
            Self.logger.error("keepalive start raised: \(String(exceptionReason))")
        }
    }

    /// Stops the silent keepalive ENGINE but keeps the audio session ACTIVE.
    /// The engine is always replaced immediately (real capture via
    /// `rearmFromKeepAlive`, or a rebuilt keepalive), so the process never
    /// loses its active session while backgrounded. Never deactivates — a
    /// deactivation is the one act that lets iOS suspend a backgrounded app.
    /// Idempotent.
    func stopKeepAlive() {
        guard isKeepingAlive else { return }
        var exceptionReason: NSString?
        ObjCExceptionCatcher.catchException({
            self.keepAlivePlayer?.stop()
            self.keepAliveEngine?.stop()
        }, outExceptionReason: &exceptionReason)
        if let exceptionReason {
            Self.logger.warning("stopKeepAlive raised: \(String(exceptionReason))")
        }
        keepAlivePlayer = nil
        keepAliveEngine = nil
        isKeepingAlive = false
        DictationSharedState.diag("keepalive engine stopped — session kept active")
        Self.logger.info("keepalive engine stopped (session kept active)")
    }

    /// Releases every engine after a foreign app took the audio session
    /// (interruption `.began`) while we were idle. The system already
    /// deactivated the session — this never re-activates and never calls
    /// `setActive(false)` (the deactivation already happened; notifying
    /// others adds nothing). The point is to go QUIET: a backgrounded app
    /// that keeps re-activating against a SILENT session owner (e.g. a
    /// video app that launched but plays nothing, so `isOtherAudioPlaying`
    /// is false and the "yield to playing audio" logic never engages) is
    /// watchdog-killed after a few churn cycles. After this the process is
    /// suspended normally; the next dictation request cold-launches it
    /// (the designed fallback when the mic is not armed).
    func releaseEnginesForForeignOwner() {
        DictationSharedState.diag("engines released — foreign session owner (process will suspend)")
        if isRunning {
            teardownEngine()
            isRunning = false
        }
        if isKeepingAlive {
            keepAlivePlayer?.stop()
            keepAliveEngine?.stop()
            keepAlivePlayer = nil
            keepAliveEngine = nil
            isKeepingAlive = false
        }
        // sessionActive is already false (the system deactivated us at
        // `.began`) and stays false until a real re-arm activates again.
    }

    /// Hot-swaps an armed capture engine to the silent keepalive WITHOUT
    /// deactivating the audio session (safe in the background). The session
    /// stays active and an engine is running at every instant, so the
    /// process never becomes suspendible mid-transition.
    func yieldToKeepAlive() {
        guard isRunning else { return }
        DictationSharedState.diag("YIELD: armed capture → silent keepalive (mic off)")
        stopCaptureKeepingSession()
        startKeepAlive()
    }

    /// The capture configurations to try when re-arming from keepalive in
    /// the background, in order. The winning attempt is prepended when
    /// known; these cover the first start of the process (e.g. the app was
    /// launched directly into keepalive over music and never armed).
    private static let rearmFallbackAttempts: [Attempt] = [
        Attempt(name: "playAndRecord/measurement/speaker+mix", category: .playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers], format: nil, prefs: false, voiceProcessing: false),
        Attempt(name: "record/measurement/duck", category: .record, mode: .measurement, options: [.duckOthers], format: nil, prefs: false, voiceProcessing: false),
        Attempt(name: "record/measurement/none", category: .record, mode: .measurement, options: [], format: nil, prefs: false, voiceProcessing: false),
    ]

    /// Hot-swaps the silent keepalive back to an armed capture engine
    /// WITHOUT deactivating the audio session. Safe to attempt in the
    /// background: the process is running (the keepalive engine keeps it
    /// alive) and the session never goes inactive, so this cannot open a
    /// suspension window. Returns false if the input unit refuses the
    /// background start — the keepalive is restored and the caller retries
    /// on a throttle. The process is never left without an engine.
    @discardableResult
    func rearmFromKeepAlive() -> Bool {
        guard isKeepingAlive else { return isRunning }
        stopKeepAlive()
        let attempts: [Attempt]
        if let winner = lastWinningAttempt {
            attempts = [winner] + Self.rearmFallbackAttempts
        } else {
            attempts = Self.rearmFallbackAttempts
        }
        var nodeOut = ""
        var nodeIn = ""
        var lastError: Error?
        var exceptionReason: NSString?
        var started = false
        for attempt in attempts {
            ObjCExceptionCatcher.catchException({
                do {
                    try self.tryStart(attempt, nodeOut: &nodeOut, nodeIn: &nodeIn, deactivateFirst: false)
                    started = true
                } catch {
                    lastError = error
                }
            }, outExceptionReason: &exceptionReason)
            if started {
                isRunning = true
                DictationSharedState.diag("RE-ARM OK: \(attempt.name)")
                Self.logger.info("background re-arm succeeded with: \(attempt.name)")
                return true
            }
            teardownEngine()
        }
        DictationSharedState.diag("RE-ARM REFUSED: \(lastError.map { Self.errorDetail($0, copyToPasteboard: false) } ?? "unknown") — keepalive restored")
        Self.logger.error("background re-arm refused: \(lastError.map { Self.errorDetail($0, copyToPasteboard: false) } ?? "unknown")")
        // The session was never deactivated — bring the silent keepalive
        // back on the still-active session.
        startKeepAlive()
        return false
    }

    /// Recreates the keepalive engine if the flag claims keepalive but the
    /// engine is no longer running (an interruption, route change, or media
    /// reset killed it while another app kept playing). Keeps this process
    /// alive without ever grabbing the mic back.
    func repairKeepAliveIfNeeded() {
        guard isKeepingAlive else { return }
        guard keepAliveEngine?.isRunning != true else { return }
        DictationSharedState.diag("keepalive engine DEAD — rebuilding")
        Self.logger.warning("keepalive engine dead — rebuilding")
        keepAlivePlayer = nil
        keepAliveEngine = nil
        startKeepAlive()
    }

    // MARK: - Other apps' audio (mixing / ducking)

    /// True while the armed session lets other apps' audio keep playing
    /// (a `.playAndRecord` session configured with `.mixWithOthers`).
    var isMixableWithOtherApps: Bool {
        isRunning && (activeAttempt?.options.contains(.mixWithOthers) == true)
    }

    /// Lowers other apps' audio (music) while a live dictation session is
    /// capturing, or restores it to full volume + mixing when dictation
    /// ends. The always-armed session uses `.mixWithOthers` so music never
    /// stops when the app is open; once recognition is actually running,
    /// background music at full volume would fight the recognizer, so it is
    /// ducked instead (iOS fades it back up when the options are restored).
    ///
    /// Only the OPTIONS are changed — the category/mode stay exactly as the
    /// winning attempt configured them (re-applying a category the hardware
    /// rejected during `start()` would break the engine). No-op for the
    /// `.record`-category fallbacks, which cannot mix or duck.
    func setOtherAudioDucked(_ ducked: Bool) {
        guard ducked != isOtherAudioDucked else { return }
        guard isRunning, let attempt = activeAttempt,
              attempt.options.contains(.mixWithOthers) else { return }
        let options: AVAudioSession.CategoryOptions = ducked
            ? [.defaultToSpeaker, .duckOthers]
            : [.defaultToSpeaker, .mixWithOthers]
        var exceptionReason: NSString?
        ObjCExceptionCatcher.catchException({
            do {
                try self.audioSession.setCategory(attempt.category, mode: attempt.mode, options: options)
                self.isOtherAudioDucked = ducked
                Self.logger.info("\(ducked ? "other audio ducked (dictation live)" : "other audio restored (mixWithOthers)")")
            } catch {
                Self.logger.error("setOtherAudioDucked(\(ducked)) failed: \(error.localizedDescription)")
            }
        }, outExceptionReason: &exceptionReason)
        if let exceptionReason {
            Self.logger.error("setOtherAudioDucked(\(ducked)) raised: \(String(exceptionReason))")
        }
    }

    // MARK: - Buffer handling

    private func handle(buffer: AVAudioPCMBuffer) {
        lastBufferAt = Date()
        onBuffer?(buffer)

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferDiagTime >= 2 {
            lastBufferDiagTime = now
            DictationSharedState.diag("buffers flowing (frames=\(buffer.frameLength))")
        }

        // Throttle level updates so we don't flood the main queue.
        guard now - lastLevelDispatchTime >= levelDispatchInterval else { return }
        lastLevelDispatchTime = now

        let level = normalizedLevel(of: buffer)
        DispatchQueue.main.async {
            self.onLevel?(level)
        }
    }

    // MARK: - Audio session

    // (Audio session setup now happens per-attempt in `tryStart`.)

    // MARK: - Level metering

    /// Converts a PCM buffer into a normalized 0...1 level for the waveform.
    private func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }
        let frames = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for frame in 0..<frames {
            let sample = channelData[0][frame]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frames))
        // Typical speech RMS is ~0.01–0.1; scale up for a lively waveform.
        return min(max(rms * 12, 0), 1)
    }
}
