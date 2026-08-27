import SwiftUI

/// Full-keyboard overlay shown while a dictation session is live: waveform,
/// live partial results, elapsed time, and stop/cancel controls.
struct RecordingOverlayView: View {
    @ObservedObject var state: KeyboardState

    var body: some View {
        VStack(spacing: 12) {
            header
            WaveformBarsView(level: state.audioLevel, isActive: state.phase == .recording)
                .frame(height: 44)
            transcript
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if state.phase == .ready {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: .red.opacity(0.8), radius: 4)
            }
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(timeString(state.elapsed))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.2), value: state.phase)
    }

    private var title: String {
        switch state.phase {
        case .recording: return "Listening"
        case .transcribing: return "Finalizing…"
        case .ready: return "Inserted"
        default: return "Dictating"
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            Text(state.liveTranscript.isEmpty ? "Speak now…" : state.liveTranscript)
                .font(.body.weight(.medium))
                .foregroundStyle(state.liveTranscript.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 64)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 36) {
            Button {
                state.cancelDictation()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            Button {
                state.stopDictation()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title2.weight(.bold))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.red.opacity(0.85)))
                    .shadow(color: .red.opacity(0.5), radius: 10)
            }
        }
        .foregroundStyle(.white)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
