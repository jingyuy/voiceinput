import SwiftUI

/// App-side overlay shown while a keyboard-requested dictation session is
/// live (or finished but not yet picked up by the keyboard). The user is
/// usually in Notes; this overlay matters when the app is foreground — a
/// cold launch by the keyboard, or the user checking in.
struct DictationSessionOverlay: View {
    let coordinator: KeyboardDictationCoordinator

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                header
                transcript
                controls
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.10, blue: 0.15))
            )
            .padding(24)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if coordinator.status == .ready {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Dictation complete")
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: .red.opacity(0.8), radius: 4)
                Text(coordinator.status == .transcribing ? "Finalizing…" : "Dictating")
            }
            Spacer()
            Text(coordinator.status == .ready
                 ? "Return to your keyboard to insert the text"
                 : "Return to your keyboard")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.headline)
        .foregroundStyle(.white)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            Text(displayText)
                .font(.body)
                .foregroundStyle(displayText.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
    }

    private var displayText: String {
        if coordinator.status == .ready { return coordinator.finalText }
        return coordinator.liveText.isEmpty ? "Speak now…" : coordinator.liveText
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                coordinator.cancelSession()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(.white.opacity(0.12)))
            }

            if coordinator.status == .ready {
                Button("Done") {
                    coordinator.dismissReady()
                }
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.teal))
            } else {
                Button {
                    coordinator.beginFinish()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2.weight(.bold))
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(.red.opacity(0.85)))
                        .shadow(color: .red.opacity(0.5), radius: 10)
                }
            }
        }
        .foregroundStyle(.white)
    }
}
