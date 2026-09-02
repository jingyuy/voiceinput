import SwiftUI
import UIKit

/// The main screen: live waveform, streaming transcript, and record control.
/// When a keyboard-driven session is live, this same screen shows it
/// (recording state, live text, stop/cancel) — the app has no separate
/// dictation overlay anymore.
struct TranscriptionView: View {
    @State private var viewModel = TranscriptionViewModel()
    @State private var historyStore = TranscriptionHistoryStore.shared
    @State private var confirmClearHistory = false
    @State private var showLanguages = false

    private enum MainSection: Hashable {
        case dictate
        case history
    }

    @State private var section: MainSection = .dictate

    var body: some View {
        ZStack {
            BackgroundView()
            VStack(spacing: 14) {
                header
                sectionPicker
                Group {
                    if section == .dictate {
                        dictateSection
                    } else {
                        historySection
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // The keyboard's globe key may have changed the dictation
            // language in another process — re-read it and apply.
            DictationSettings.shared.reloadFromDefaults()
            viewModel.applyLocaleFromSettings()
        }
        .onChange(of: viewModel.isKeyboardSession) {
            // A keyboard session (e.g. a cold launch) must be visible —
            // jump back to the Dictate tab so the live recording shows.
            if viewModel.isKeyboardSession {
                withAnimation(.easeInOut(duration: 0.2)) {
                    section = .dictate
                }
            }
        }
        .sheet(isPresented: $showLanguages) {
            LanguagesSheetView {
                viewModel.applyLocaleFromSettings()
            }
        }
    }

    // MARK: - Section picker

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            Text("Dictate").tag(MainSection.dictate)
            Text("History").tag(MainSection.history)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Dictate section

    private var dictateSection: some View {
        VStack(spacing: 18) {
            sessionBanner
            waveformCard
            errorBanner
            transcriptCard
            Spacer(minLength: 0)
            recordSection
        }
    }

    // MARK: - History section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !historyStore.entries.isEmpty {
                    Button {
                        confirmClearHistory = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            HistoryList(store: historyStore)
        }
        .padding(14)
        .cardStyle()
        .confirmationDialog(
            "Clear all history?",
            isPresented: $confirmClearHistory,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    historyStore.clear()
                }
            }
        } message: {
            Text("This removes every saved transcription. This can't be undone.")
        }
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
            languageButton
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

    /// Opens the language sheet. The capsule shows the ACTIVE language (the
    /// one the next dictation uses); the sheet edits the up-to-five language
    /// pair the keyboard's globe key cycles through.
    private var languageButton: some View {
        Button {
            showLanguages = true
        } label: {
            Label(DictationSettings.shared.localeName, systemImage: "globe")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.teal.opacity(0.16)))
                .foregroundStyle(Color.teal)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Session banner (keyboard-driven sessions)

    @ViewBuilder
    private var sessionBanner: some View {
        if viewModel.isKeyboardSession {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: bannerIcon)
                    .foregroundStyle(Color.teal)
                Text(bannerText)
                    .font(.footnote)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.teal.opacity(0.12)))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var bannerIcon: String {
        switch viewModel.state {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "keyboard"
        }
    }

    private var bannerText: String {
        switch viewModel.state {
        case .recording: return "Recording for your keyboard — the text is inserted where you were typing."
        case .ready: return viewModel.isFinalizing
            ? "Finalizing your dictation…"
            : "Dictation complete — insert the text from your keyboard."
        case .failed: return "The dictation failed — details below."
        default: return ""
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
        if viewModel.isKeyboardSession {
            switch viewModel.state {
            case .recording: return "Dictating for your keyboard"
            case .ready: return viewModel.isFinalizing ? "Finalizing…" : "Dictation complete"
            case .failed: return "Something went wrong"
            case .idle, .requestingPermission: return "Ready"
            }
        }
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
                if !viewModel.isKeyboardSession, !viewModel.finalizedSegments.isEmpty {
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
                        if let readyText = viewModel.readyDisplayText {
                            segmentRow(readyText)
                                .id("bottom")
                        } else if viewModel.finalizedSegments.isEmpty && viewModel.liveTranscript.isEmpty {
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

    @ViewBuilder
    private var recordSection: some View {
        if viewModel.isKeyboardSession {
            keyboardSessionControls
        } else {
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
    }

    /// Controls for a live keyboard session: stop (finalize + insert on the
    /// keyboard side), cancel, or Done once the result is ready.
    private var keyboardSessionControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 36) {
                if viewModel.state == .recording || viewModel.isFinalizing {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(duration: 0.35)) {
                            viewModel.cancelKeyboardSession()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(.white.opacity(0.12)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel dictation")
                }

                switch viewModel.state {
                case .recording:
                    Button {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        withAnimation(.spring(duration: 0.35)) {
                            viewModel.stopKeyboardSession()
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title2.weight(.bold))
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(.red.opacity(0.85)))
                            .shadow(color: .red.opacity(0.5), radius: 10)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop and insert")
                case .ready where viewModel.isFinalizing:
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 60, height: 60)
                case .ready:
                    Button {
                        withAnimation(.spring(duration: 0.35)) {
                            viewModel.dismissKeyboardReady()
                        }
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.headline)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.teal))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                default:
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 60, height: 60)
                }
            }
            Text(keyboardHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var keyboardHint: String {
        switch viewModel.state {
        case .recording: return "Return to your keyboard — the text is inserted automatically"
        case .ready: return viewModel.isFinalizing ? "Finalizing your dictation…" : "Text is ready — insert it from your keyboard"
        default: return ""
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
