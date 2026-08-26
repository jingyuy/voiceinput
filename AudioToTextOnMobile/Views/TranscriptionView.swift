import SwiftUI
import UIKit

/// The main screen: live waveform, streaming transcript, and record control.
struct TranscriptionView: View {
    @State private var viewModel = TranscriptionViewModel()

    var body: some View {
        ZStack {
            BackgroundView()
            VStack(spacing: 18) {
                header
                waveformCard
                errorBanner
                transcriptCard
                Spacer(minLength: 0)
                recordSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Audio To Text")
                    .font(.title2.weight(.bold))
                Text("On-device speech recognition")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isOnDevice {
                Label("On-Device", systemImage: "iphone")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.teal.opacity(0.16)))
                    .foregroundStyle(Color.teal)
            }
        }
    }

    // MARK: - Waveform

    private var waveformCard: some View {
        VStack(spacing: 14) {
            HStack {
                statusIndicator
                Spacer()
                Text(statusText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            WaveformView(level: viewModel.audioLevel, isActive: viewModel.state == .recording)
                .frame(height: 96)
        }
        .padding(18)
        .cardStyle()
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch viewModel.state {
        case .recording:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .shadow(color: .red.opacity(0.8), radius: 6)
                .transition(.scale.combined(with: .opacity))
        case .requestingPermission:
            ProgressView()
                .controlSize(.small)
        default:
            Circle()
                .fill(Color.teal)
                .frame(width: 10, height: 10)
        }
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle: return "Ready"
        case .requestingPermission: return "Checking permissions…"
        case .ready: return "Tap the mic to start"
        case .recording: return "Listening — speak now"
        case .failed: return "Something went wrong"
        }
    }

    // MARK: - Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if case .failed(let message) = viewModel.state {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.12)))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Transcript

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !viewModel.finalizedSegments.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.clearSession()
                        }
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if viewModel.finalizedSegments.isEmpty && viewModel.liveTranscript.isEmpty {
                            emptyTranscript
                        } else {
                            ForEach(Array(viewModel.finalizedSegments.enumerated()), id: \.offset) { _, segment in
                                segmentRow(segment)
                            }
                            if viewModel.state == .recording || !viewModel.liveTranscript.isEmpty {
                                liveRow
                                    .id("live")
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: viewModel.liveTranscript) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.finalizedSegments.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    private var emptyTranscript: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Your transcription will appear here")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func segmentRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.2))
                .frame(width: 3)
            Text(text)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var liveRow: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.teal)
                .frame(width: 3)
            Group {
                if viewModel.liveTranscript.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.teal)
                            .frame(width: 6, height: 6)
                            .shadow(color: .teal, radius: 4)
                        Text("Listening…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(viewModel.liveTranscript)
                        .font(.body.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Record control

    private var recordSection: some View {
        VStack(spacing: 10) {
            RecordButtonView(state: viewModel.state) {
                UIImpactFeedbackGenerator(style: viewModel.state == .recording ? .rigid : .medium)
                    .impactOccurred()
                withAnimation(.spring(duration: 0.35)) {
                    viewModel.toggleRecording()
                }
            }
            Text(hintText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var hintText: String {
        switch viewModel.state {
        case .idle: return "Tap to start transcribing"
        case .ready: return "Tap to record"
        case .recording: return "Tap to stop"
        case .requestingPermission: return ""
        case .failed: return "Tap to try again"
        }
    }
}

// MARK: - Shared card style

extension View {
    func cardStyle() -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

#Preview {
    TranscriptionView()
}
