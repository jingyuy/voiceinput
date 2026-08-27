import SwiftUI

@main
struct AudioToTextOnMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let coordinator = KeyboardDictationCoordinator.shared

    var body: some Scene {
        WindowGroup {
            TranscriptionView()
                .overlay {
                    // Only keyboard-driven sessions get the overlay — the
                    // app's own sessions live in TranscriptionView.
                    if coordinator.isActive && !coordinator.isAppSession {
                        DictationSessionOverlay(coordinator: coordinator)
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == "attotext" else { return }
                    coordinator.noteOpenURL()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhase(newPhase)
        }
    }
}
