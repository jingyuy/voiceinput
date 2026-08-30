import Foundation
import Observation

/// Holds the app's navigation stack so it can be persisted across launches.
/// When the app is restarted the user is returned to the screen they were
/// on and can swipe back to where they were — the path is rehydrated from
/// `UserDefaults` on init and written back whenever it changes.
@MainActor
@Observable
final class AppNavigationModel {

    static let shared = AppNavigationModel()

    enum Route: Hashable, Codable {
        case history
        case historyDetail(UUID)
    }

    /// The live navigation path (bound to a `NavigationStack`).
    var path: [Route] = []

    private static let storageKey = "navigation.path"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Route].self, from: data)
        else { return }
        path = decoded
    }

    /// Writes the current path to disk. Call from `.onChange(of: path)` in
    /// the root view — SwiftUI mutates `path` through its binding, so we
    /// can't intercept every write in a setter.
    func persist() {
        guard let data = try? JSONEncoder().encode(path) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
