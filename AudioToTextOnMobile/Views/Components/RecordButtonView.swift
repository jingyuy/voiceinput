import SwiftUI

/// The primary record/stop control with a pulsing ring while recording.
struct RecordButtonView: View {
    var state: TranscriptionViewModel.RecordingState
    var action: () -> Void

    private var isRecording: Bool { state == .recording }
    private var isBusy: Bool { state == .requestingPermission }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    PulseRing(color: .red)
                }
                Circle()
                    .fill(AnyShapeStyle(buttonFill))
                    .frame(width: 78, height: 78)
                    .shadow(color: shadowColor, radius: 18)
                Image(systemName: iconName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: 110, height: 110)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Appearance

    private var buttonFill: LinearGradient {
        switch state {
        case .recording:
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.32, blue: 0.32), Color(red: 0.9, green: 0.1, blue: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .failed:
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.65, blue: 0.3), Color(red: 0.95, green: 0.4, blue: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            LinearGradient(
                colors: [Color(red: 0.2, green: 0.85, blue: 1.0), Color(red: 0.35, green: 0.4, blue: 1.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var shadowColor: Color {
        switch state {
        case .recording: return .red.opacity(0.6)
        case .failed: return .orange.opacity(0.6)
        default: return .blue.opacity(0.5)
        }
    }

    private var iconName: String {
        switch state {
        case .recording: return "stop.fill"
        case .failed: return "arrow.clockwise"
        default: return "mic.fill"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .recording: return "Stop recording"
        case .failed: return "Retry"
        default: return "Start recording"
        }
    }
}

/// An expanding, fading ring shown behind the record button while recording.
private struct PulseRing: View {
    var color: Color
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .stroke(color.opacity(0.5), lineWidth: 2)
            .frame(width: 78, height: 78)
            .scaleEffect(scale)
            .opacity(Double(max(0, 1.8 - scale) / 0.8))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    scale = 1.8
                }
            }
    }
}

#Preview {
    ZStack {
        Color.black
        RecordButtonView(state: .idle, action: {})
    }
    .preferredColorScheme(.dark)
}
