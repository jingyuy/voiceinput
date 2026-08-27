import SwiftUI

/// Top-level keyboard view: swaps between the idle layout and the
/// recording overlay.
struct KeyboardRootView: View {
    @ObservedObject var state: KeyboardState

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.075, blue: 0.11)
                .ignoresSafeArea()

            Group {
                switch state.phase {
                case .recording, .transcribing, .ready:
                    RecordingOverlayView(state: state)
                case .idle, .starting, .failed:
                    KeyboardView(state: state)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }
}
