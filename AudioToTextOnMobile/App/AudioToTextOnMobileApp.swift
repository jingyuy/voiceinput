import SwiftUI

@main
struct AudioToTextOnMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let coordinator = KeyboardDictationCoordinator.shared
    /// The navigation path is persisted, so after a restart the user lands
    /// back on the screen they were on and can swipe back to where they were.
    @State private var navigation = AppNavigationModel.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $navigation.path) {
                TranscriptionView()
                    .navigationDestination(for: AppNavigationModel.Route.self) { route in
                        switch route {
                        case .history:
                            HistoryView()
                        case .historyDetail(let id):
                            HistoryDetailView(entryID: id)
                        }
                    }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onOpenURL { url in
                guard url.scheme == "attotext" else { return }
                coordinator.noteOpenURL()
            }
            .onChange(of: navigation.path) {
                navigation.persist()
            }
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhase(newPhase)
        }
    }
}
