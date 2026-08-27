import AVFoundation
import Foundation

/// Captures microphone audio with `AVAudioEngine` and forwards raw PCM
/// buffers plus a normalized level signal to callbacks for live processing.
///
/// The service is deliberately stateless: it owns no transcription logic,
/// so it can be reused or replaced (e.g. with a custom audio pipeline)
/// without touching the UI.
final class AudioCaptureService {

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case engineStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let error):
                return "Could not start the microphone: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Callbacks

    /// Called on an internal audio queue with every captured PCM buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called on the main queue at ~30 Hz with a normalized level in 0...1.
    var onLevel: ((Float) -> Void)?

    /// Called on the main queue when the system interrupts audio capture
    /// (e.g. an incoming phone call).
    var onInterruption: (() -> Void)?

    // MARK: - Private state

    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private var lastLevelDispatchTime: CFAbsoluteTime = 0
    private let levelDispatchInterval: CFAbsoluteTime = 1.0 / 30.0

    // MARK: - Init

    init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType),
                  type == .began else { return }
            self.onInterruption?()
        }
    }

    // MARK: - Capture control

    /// Starts capturing from the microphone. Throws if the audio session
    /// cannot be configured or the audio engine fails to start.
    func start() throws {
        let inputNode = audioEngine.inputNode

        try configureAudioSession()

        // IMPORTANT: resolve the input format AFTER the audio session is
        // active. Before activation, outputFormat(forBus:) can report a stale
        // client format (e.g. 48 kHz) that doesn't match the hardware's actual
        // rate (e.g. 16 kHz once preferredSampleRate is applied). Installing a
        // tap with that mismatched format throws "Failed to create tap due to
        // format mismatch" and crashes the app.
        let recordingFormat = inputFormat(for: inputNode)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw CaptureError.engineStartFailed(error)
        }
    }

    /// Resolves the tap format. Prefers the input node's own output format,
    /// but defensively rebuilds it at the session's actual sample rate if the
    /// node is still reporting a stale rate.
    private func inputFormat(for inputNode: AVAudioInputNode) -> AVAudioFormat {
        let nodeFormat = inputNode.outputFormat(forBus: 0)
        let sessionRate = audioSession.sampleRate
        guard abs(nodeFormat.sampleRate - sessionRate) > 1,
              let rebuilt = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sessionRate,
                  channels: nodeFormat.channelCount,
                  interleaved: false
              ) else {
            return nodeFormat
        }
        return rebuilt
    }

    /// Stops capturing and releases the microphone.
    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
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

    private func configureAudioSession() throws {
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        // Ask for a sample rate the speech recognizer handles well.
        try audioSession.setPreferredSampleRate(16_000)
        try audioSession.setPreferredIOBufferDuration(0.02)
        try audioSession.setActive(true)
    }

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
