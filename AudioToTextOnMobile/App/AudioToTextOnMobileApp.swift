import SwiftUI

@main
struct AudioToTextOnMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let coordinator = KeyboardDictationCoordinator.shared

    var body: some Scene {
        WindowGroup {
            TranscriptionView()
                .overlay {
                    if coordinator.isActive {
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
