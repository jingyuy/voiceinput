import SwiftUI
import UIKit

/// Full text of a single history entry with copy and delete actions.
struct HistoryDetailView: View {
    let entryID: UUID
    @State private var store = TranscriptionHistoryStore.shared
    @State private var navigation = AppNavigationModel.shared
    @State private var copied = false

    var body: some View {
        ZStack {
            BackgroundView()
            if let entry = store.entry(id: entryID) {
                content(entry)
            } else {
                missingEntry
            }
        }
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Content

    private func content(_ entry: TranscriptionHistoryStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .cardStyle()
                    .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 12) {
                Label(relativeDate(entry.date), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(entry)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(copied ? Color.green.opacity(0.25) : Color.teal.opacity(0.22)))
                        .foregroundStyle(copied ? Color.green : Color.teal)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.remove(entry)
                    }
                    navigation.path.removeLast()
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.red.opacity(0.14)))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
    }

    private var missingEntry: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("This entry no longer exists")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func copy(_ entry: TranscriptionHistoryStore.Entry) {
        UIPasteboard.general.string = entry.text
        withAnimation(.easeInOut(duration: 0.15)) {
            copied = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.15)) {
                copied = false
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 30 * 24 * 3600 {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

#Preview {
    let store = TranscriptionHistoryStore.shared
    if store.entries.isEmpty {
        store.add("This is a sample transcription saved to the history.")
    }
    return NavigationStack {
        HistoryDetailView(entryID: store.entries.first?.id ?? UUID())
    }
}
