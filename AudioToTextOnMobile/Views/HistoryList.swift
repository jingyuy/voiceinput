import SwiftUI

/// The history rows (and empty state), shared by the pushed History page and
/// the History section on the main screen. Each row pushes the detail view.
struct HistoryList: View {
    let store: TranscriptionHistoryStore

    var body: some View {
        if store.entries.isEmpty {
            emptyState
        } else {
            rows
        }
    }

    // MARK: - Rows

    private var rows: some View {
        List {
            ForEach(store.entries) { entry in
                NavigationLink(value: AppNavigationModel.Route.historyDetail(entry.id)) {
                    entryRow(entry)
                }
                .listRowBackground(Color.white.opacity(0.05))
                .listRowSeparatorTint(.white.opacity(0.08))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.remove(entry)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 24, for: .scrollContent)
    }

    private func entryRow(_ entry: TranscriptionHistoryStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(3)
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption2)
                Text(relativeDate(entry.date))
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No transcriptions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Dictations you complete will be saved here, even after you close the app.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 30 * 24 * 3600 {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
