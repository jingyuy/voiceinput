import SwiftUI
import UIKit

/// Top-level keyboard view: swaps between the idle layout and the
/// recording overlay. Injects the SwiftUI `openURL` (the only reliable way
/// for a keyboard extension to open a URL) into `KeyboardState` for the
/// cold-launch fallback.
struct KeyboardRootView: View {
    @ObservedObject var state: KeyboardState
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            // The keyboard mirrors the host app's appearance — light-gray keys
            // inside a light app, the near-black set inside a dark app, like
            // the system keyboard. See the adaptive palette at the bottom.
            Color.kbBackground
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
        .onAppear {
            state.openURL = { url in
                openURL(url)
            }
        }
    }
}

// MARK: - Adaptive keyboard palette

/// The keyboard follows the host app's light/dark appearance exactly like the
/// system keyboard does. Semantic text styles (.primary/.secondary/.tertiary)
/// adapt automatically; these dynamic colors give the chrome, key caps, and
/// the symbol popover matching surfaces in both modes.
extension Color {
    /// Chrome behind the keys.
    static let kbBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.075, blue: 0.11, alpha: 1)
            : UIColor(red: 0.76, green: 0.78, blue: 0.82, alpha: 1)
    })

    /// Standard key cap.
    static let kbKeyFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.white
    })

    /// Key cap while pressed (darker in light mode, lighter in dark mode).
    static let kbKeyFillPressed = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.16)
            : UIColor(white: 0.76, alpha: 1)
    })

    /// Hairline around each key cap. In light mode a dark stroke separates the
    /// white keys from the light chrome (otherwise the whole keyboard reads as
    /// one borderless slab); in dark mode a light stroke defines the key edge
    /// against the near-black chrome. Mirrors the system keyboard's key
    /// definition in both appearances.
    static let kbKeyStroke = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor(white: 0.0, alpha: 0.12)
    })

    /// Floating symbol popover surface.
    static let kbPopoverFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.16, blue: 0.22, alpha: 1)
            : UIColor.white
    })

    /// Floating symbol popover border.
    static let kbPopoverStroke = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.1)
            : UIColor(white: 0.0, alpha: 0.08)
    })
}
