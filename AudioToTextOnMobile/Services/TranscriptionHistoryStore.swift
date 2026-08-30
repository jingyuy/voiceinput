import Foundation
import Observation

/// Persistent history of every dictation the app has finalized — both app
/// sessions (the record button in `TranscriptionView`) and keyboard-driven
/// sessions whose text was published to the shared store.
///
/// Entries are persisted as JSON in `UserDefaults` so the history survives
/// app restarts. Newest entries come first.
@MainActor
@Observable
final class TranscriptionHistoryStore {

    static let shared = TranscriptionHistoryStore()

    struct Entry: Codable, Identifiable, Hashable {
        let id: UUID
        let text: String
        let date: Date
    }

    private(set) var entries: [Entry] = []

    private static let storageKey = "history.entries"
    private static let maxEntries = 200

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Mutation

    /// Adds a finalized transcription to the top of the history.
    /// Empty/whitespace-only text is ignored.
    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(Entry(id: UUID(), text: trimmed, date: Date()), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func entry(id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
