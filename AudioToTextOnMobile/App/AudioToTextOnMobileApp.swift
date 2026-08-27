import SwiftUI

@main
struct AudioToTextOnMobileApp: App {
    @State private var coordinator = KeyboardDictationCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if coordinator.isColdStart {
                    KeyboardReturnOverlayView()
                } else {
                    TranscriptionView()
                }
            }
            .onOpenURL { url in
                coordinator.handleOpenURL(url)
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Only drop the cold-start overlay when the user actually
                // leaves the app. Do NOT flip to the main UI when a session
                // ends — that strands the user in the app with no text.
                if newPhase == .inactive || newPhase == .background {
                    if !coordinator.isActive {
                        coordinator.isColdStart = false
                    }
                }
            }
        }
    }
}
