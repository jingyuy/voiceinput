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

    /// The engine is recreated fresh inside `tryStart` AFTER the audio
    /// session is configured — an engine created early (e.g. at init) can
    /// lock in a 2ch input-node format that the mono hardware then rejects
    /// with kAudioUnitErr_UnsupportedFormat ('what').
    private var audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private var lastLevelDispatchTime: CFAbsoluteTime = 0
    private let levelDispatchInterval: CFAbsoluteTime = 1.0 / 30.0
    /// True while the capture engine is running. The engine is kept running
    /// almost permanently (always-armed mic) so dictation can start instantly
    /// in the background without re-initializing the input unit.
    private(set) var isRunning = false

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
                self.onInterruption?()
            case .ended:
                self.onInterruptionEnded?()
            @unknown default:
                break
            }
        }
    }

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
        let attempts: [Attempt] = [
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
                    try self.tryStart(attempt, nodeOut: &nodeOut, nodeIn: &nodeIn)
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
    private func tryStart(_ attempt: Attempt, nodeOut: inout String, nodeIn: inout String) throws {
        let session = audioSession
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(attempt.category, mode: attempt.mode, options: attempt.options)
        if attempt.prefs {
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredInputNumberOfChannels(1)
            try? session.setPreferredIOBufferDuration(0.02)
        }
        try session.setActive(true)

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
    }

    /// Stops the engine and removes the tap without touching the session
    /// (used between failed attempts).
    private func teardownEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
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

    /// Stops capturing and releases the microphone.
    func stop() {
        guard isRunning else { return }
        teardownEngine()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    // MARK: - Buffer handling

    private func handle(buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)

        // Throttle level updates so we don't flood the main queue.
        let now = CFAbsoluteTimeGetCurrent()
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
