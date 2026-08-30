import SwiftUI

/// Full-page history (reached via a persisted navigation path). The rows
/// themselves live in `HistoryList`, shared with the main screen's History
/// section.
struct HistoryView: View {
    @State private var store = TranscriptionHistoryStore.shared
    @State private var confirmClear = false

    var body: some View {
        ZStack {
            BackgroundView()
            HistoryList(store: store)
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !store.entries.isEmpty {
                    Button("Clear All", role: .destructive) {
                        confirmClear = true
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.clear()
                }
            }
        } message: {
            Text("This removes every saved transcription. This can't be undone.")
        }
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}
