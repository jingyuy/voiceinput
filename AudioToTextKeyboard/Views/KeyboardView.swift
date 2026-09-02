import SwiftUI
import UIKit

/// Minimal dictation keyboard: a mic button plus the essential keys
/// (globe / space / delete) so it can stand in for the system keyboard.
struct KeyboardView: View {
    @ObservedObject var state: KeyboardState

    var body: some View {
        VStack(spacing: 12) {
            statusArea
            Spacer(minLength: 0)
            micButton
            Spacer(minLength: 0)
            bottomRow
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusArea: some View {
        Group {
            if !state.hasFullAccess {
                Label("Full Access is off — enable it in Settings → General → Keyboard.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.orange.opacity(0.12)))
            } else if case .failed(let message) = state.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            } else if case .starting = state.phase {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Starting…")
                }
                .font(.caption)
                // Semantic colors adapt with the host theme — the keyboard
                // chrome now does too (see Color.kbBackground).
                .foregroundStyle(.secondary)
            } else {
                Text("Tap the mic to dictate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: state.phase)
    }

    // MARK: - Mic

    private var micButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            state.startDictation()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.teal, Color.teal.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 76, height: 76)
                    .shadow(color: .teal.opacity(0.45), radius: 14)
                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom row

    private var bottomRow: some View {
        HStack(spacing: 10) {
            keyButton(systemName: "space", action: { state.insertText(" ") })
                .frame(maxWidth: .infinity)
            languageKey
            SymbolKeyView(options: [".", ",", "?", "!", ":", ";"], keyWidth: 84) { symbol in
                state.insertText(symbol)
            }
            .zIndex(2)
            keyButton(systemName: "return", action: { state.insertText("\n") })
                .frame(width: 56)
            keyButton(systemName: "delete.left", action: { state.deleteBackward() })
                .frame(width: 48)
        }
        .frame(height: 46)
    }

    /// Globe key: cycles the dictation language on tap (writes the shared
    /// setting and pings the app). A compact code shows the current one.
    private var languageKey: some View {
        Button {
            state.cycleDictationLanguage()
        } label: {
            Label(state.dictationLocaleCode, systemImage: "globe")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 84, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.kbKeyFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.kbKeyStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.teal)
    }

    private func keyButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.kbKeyFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.kbKeyStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
