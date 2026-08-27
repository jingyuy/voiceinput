import AVFoundation
import Foundation
import UIKit

/// One-shot diagnostic probe for the keyboard extension, where
/// AVAudioEngine's real-time input unit is rejected with
/// kAudioUnitErr_UnsupportedFormat ('what') even with a perfect
/// 48 kHz / 1 ch / Float32 node format, granted mic permission
/// (recordPermission='grnt') and isInputAvailable=true.
///
/// The engine failure proves the format is correct and the hardware is
/// visible, so we need to know whether ANY audio input subsystem works
/// inside this extension process. Runs three probes SEQUENTIALLY, each
/// fully torn down before the next:
///   1. AVAudioRecorder   — AudioQueue-based file recording
///   2. AVCaptureSession  — capture-pipeline audio data output
///   3. AVAudioEngine     — with preferred rate/channels/IO-buffer and
///                          voice-processing (VPIO) variants
enum CaptureProbe {

    static func run() -> String {
        var lines: [String] = []
        lines.append("=== Probe 1: AVAudioRecorder ===")
        lines.append(probeRecorder())
        lines.append("=== Probe 2: AVCaptureSession ===")
        lines.append(probeCaptureSession())
        lines.append("=== Probe 3: AVAudioEngine prefs/VPIO ===")
        lines.append(probeEngineVariants())
        return lines.joined(separator: "\n")
    }

    // MARK: - Probe 1: AVAudioRecorder

    private static func probeRecorder() -> String {
        let session = AVAudioSession.sharedInstance()
        var out: [String] = []
        do {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            out.append("session setup failed: \(error)")
            return out.joined(separator: "\n")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        var exc: NSString?
        ObjCExceptionCatcher.catchException({
            do {
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.isMeteringEnabled = true
                let prepared = recorder.prepareToRecord()
                let started = recorder.record(forDuration: 2.0)
                out.append("prepared=\(prepared) started=\(started)")
                guard started else { return }
                var peak: Float = -160
                var lastIsRecording = recorder.isRecording
                let deadline = Date().addingTimeInterval(4.0)
                while recorder.isRecording && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                    recorder.updateMeters()
                    peak = max(peak, recorder.averagePower(forChannel: 0))
                    lastIsRecording = recorder.isRecording
                }
                recorder.stop()
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
                out.append("autoStopped=\(!lastIsRecording) peak=\(String(format: "%.1f", peak)) fileSize=\(size)")
            } catch {
                out.append("recorder failed: \(error)")
            }
        }, outExceptionReason: &exc)
        if let exc {
            out.append("NSException: \(exc)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Probe 2: AVCaptureSession (capture pipeline)

    private static func probeCaptureSession() -> String {
        let session = AVAudioSession.sharedInstance()
        var out: [String] = []
        do {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            out.append("session setup failed: \(error)")
            return out.joined(separator: "\n")
        }

        var exc: NSString?
        ObjCExceptionCatcher.catchException({
            guard let device = AVCaptureDevice.default(for: .audio) else {
                out.append("no audio input device")
                return
            }
            do {
                let capture = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                guard capture.canAddInput(input) else {
                    out.append("canAddInput=false")
                    return
                }
                capture.addInput(input)
                let output = AVCaptureAudioDataOutput()
                let counter = SampleBufferCounter()
                output.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "probe.audio"))
                guard capture.canAddOutput(output) else {
                    out.append("canAddOutput=false")
                    return
                }
                capture.addOutput(output)
                capture.startRunning()
                out.append("startRunning")
                Thread.sleep(forTimeInterval: 2.0)
                out.append("running=\(capture.isRunning) buffers=\(counter.count)")
                capture.stopRunning()
            } catch {
                out.append("capture failed: \(error)")
            }
        }, outExceptionReason: &exc)
        if let exc {
            out.append("NSException: \(exc)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Probe 3: AVAudioEngine with prefs / VPIO

    private static func probeEngineVariants() -> String {
        let session = AVAudioSession.sharedInstance()
        var lines: [String] = []
        let variants: [(name: String, category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions, prefs: Bool, vp: Bool)] = [
            ("record/measurement/prefs", .record, .measurement, [], true, false),
            ("playAndRecord/default/prefs", .playAndRecord, .default, [.defaultToSpeaker], true, false),
            ("playAndRecord/voiceChat/prefs", .playAndRecord, .voiceChat, [.defaultToSpeaker], true, false),
            ("playAndRecord/default/VPIO", .playAndRecord, .default, [.defaultToSpeaker], false, true),
            ("playAndRecord/voiceChat/VPIO", .playAndRecord, .voiceChat, [.defaultToSpeaker], false, true),
        ]
        for v in variants {
            var exc: NSString?
            var result = "\(v.name): "
            ObjCExceptionCatcher.catchException({
                do {
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                    try session.setCategory(v.category, mode: v.mode, options: v.options)
                    if v.prefs {
                        try? session.setPreferredSampleRate(48_000)
                        try? session.setPreferredInputNumberOfChannels(1)
                        try? session.setPreferredIOBufferDuration(0.02)
                    }
                    try session.setActive(true)
                    let engine = AVAudioEngine()
                    let inputNode = engine.inputNode
                    if v.vp {
                        try inputNode.setVoiceProcessingEnabled(true)
                    }
                    let nodeOut = inputNode.outputFormat(forBus: 0)
                    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
                    engine.prepare()
                    try engine.start()
                    result += "OK nodeOut=\(nodeOut.sampleRate)Hz/\(nodeOut.channelCount)ch"
                    engine.stop()
                    inputNode.removeTap(onBus: 0)
                } catch {
                    result += "\(error)"
                }
            }, outExceptionReason: &exc)
            if let exc {
                result += "NSException: \(exc)"
            }
            lines.append(result)
        }
        return lines.joined(separator: "\n")
    }
}

/// Counts audio sample buffers delivered by the capture pipeline.
private final class SampleBufferCounter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private(set) var count = 0

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        count += 1
    }
}
