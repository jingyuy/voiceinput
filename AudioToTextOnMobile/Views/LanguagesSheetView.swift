import SwiftUI
import UIKit

/// Sheet for editing the dictation languages (up to `DictationSettings
/// .maxLanguages`, i.e. five).
///
/// Two groups with two jobs:
/// - **Your languages** — the selected languages; tap a row to make it the
///   ACTIVE one (mic). The active language is what the next dictation
///   uses; the keyboard's globe key cycles through the selected ones.
/// - **All languages** — membership only. A checkmark means the language is
///   in "Your languages"; tap to add or remove it. The active one is NOT
///   special here — pick it in "Your languages" above.
///
/// Removing the ACTIVE language promotes another selected one; the last
/// remaining language is locked (dictation needs at least one).
struct LanguagesSheetView: View {
    /// Called whenever the ACTIVE language may have changed, so the caller
    /// can rebuild the recognizer for the new locale.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let settings = DictationSettings.shared

    var body: some View {
        ZStack {
            BackgroundView()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        selectedSection
                        allSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 44)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Dictation Languages")
                .font(.title3.weight(.bold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Selected languages

    private var selectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Your languages")
            VStack(spacing: 10) {
                ForEach(settings.selectedLocales, id: \.self) { id in
                    selectedRow(id)
                }
            }
        }
    }

    private func selectedRow(_ id: String) -> some View {
        let isActive = id == settings.localeIdentifier
        return Button {
            makeActive(id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "mic.fill" : "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.teal : Color.teal.opacity(0.65))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isActive ? Color.teal.opacity(0.2) : .white.opacity(0.07)))
                Text(DictationSettings.name(for: id))
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isActive ? 1 : 0.85))
                    .lineLimit(1)
                if isActive {
                    Text("ACTIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.teal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.teal.opacity(0.16)))
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DictationSettings.name(for: id))
        .accessibilityHint(isActive ? "Active language" : "Tap to make active")
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isActive ? Color.teal.opacity(0.12) : .white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isActive ? Color.teal.opacity(0.45) : .white.opacity(0.07))
        )
        .animation(.easeInOut(duration: 0.2), value: settings.selectedLocales)
    }

    private func makeActive(_ id: String) {
        guard id != settings.localeIdentifier else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        settings.activate(id)
        onChange()
    }

    // MARK: - All languages

    private var allSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("All languages")
            VStack(spacing: 6) {
                ForEach(DictationSettings.supportedLocales, id: \.id) { entry in
                    allRow(entry)
                }
            }
        }
    }

    private func allRow(_ entry: (id: String, name: String)) -> some View {
        let isMember = settings.selectedLocales.contains(entry.id)
        // The sole remaining language can't be removed (dictation needs one).
        let locked = isMember && settings.selectedLocales.count == 1
        return Button {
            guard !locked else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if isMember {
                settings.deselect(entry.id)
            } else {
                settings.add(entry.id)
            }
            onChange()
        } label: {
            HStack(spacing: 12) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(isMember ? 1 : 0.8))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isMember {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.teal)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isMember ? .white.opacity(0.07) : .white.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(locked ? 0.7 : 1)
        .accessibilityLabel(entry.name)
        .accessibilityHint(
            locked
                ? "Your last language — keep at least one"
                : (isMember ? "Remove from your languages" : "Add to your languages")
        )
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

#Preview {
    LanguagesSheetView {}
}
