import SwiftUI

/// Shown when the app is cold-launched by the keyboard. While a session is
/// live it shows the recording UI; once the session ends it flips to a "done"
/// screen so the user knows to swipe back to their keyboard (the keyboard
/// inserts the text — the app never keeps it).
struct KeyboardReturnOverlayView: View {
    @State private var coordinator = KeyboardDictationCoordinator.shared

    var body: some View {
        ZStack {
            BackgroundView()
            VStack(spacing: 22) {
                Spacer(minLength: 0)

                if coordinator.isActive {
                    liveContent
                } else if let message = coordinator.errorMessage, !message.isEmpty {
                    statusContent(
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .orange,
                        title: "Dictation failed",
                        message: message
                    )
                } else {
                    statusContent(
                        icon: "checkmark.circle.fill",
                        iconColor: .green,
                        title: "Text inserted",
                        message: "Return to your keyboard to continue typing."
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Live session

    private var liveContent: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.teal)
                .shadow(color: .teal.opacity(0.5), radius: 18)

            VStack(spacing: 6) {
                Text("Dictating")
                    .font(.title2.weight(.bold))
                Text("Speak now — swipe back to your keyboard when you're done.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(coordinator.liveTranscript.isEmpty ? "Listening…" : coordinator.liveTranscript)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                .padding(.horizontal, 24)

            HStack(spacing: 40) {
                Button {
                    coordinator.cancelKeyboardSession()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                Button {
                    coordinator.stopKeyboardSession()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2.weight(.bold))
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                        .shadow(color: .red.opacity(0.5), radius: 12)
                }
            }
            .foregroundStyle(.white)
        }
    }

    // MARK: - Terminal states

    private func statusContent(icon: String, iconColor: Color, title: String, message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(iconColor)
                .shadow(color: iconColor.opacity(0.5), radius: 18)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#Preview {
    KeyboardReturnOverlayView()
}
