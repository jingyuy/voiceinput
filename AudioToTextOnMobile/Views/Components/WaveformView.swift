import SwiftUI

/// An animated bar waveform. Bars breathe gently when idle and respond to
/// the live microphone level while recording. Rendered with `Canvas` so it
/// stays smooth at 30 fps.
struct WaveformView: View {
    /// Normalized audio level in 0...1.
    var level: Float
    /// Whether the microphone is actively recording.
    var isActive: Bool
    var barCount: Int = 36

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                drawBars(in: &context, size: size, time: time)
            }
        }
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let spacing: CGFloat = 3
        let barWidth = (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
        let midY = size.height / 2

        let gradient = Gradient(colors: [
            Color(red: 0.35, green: 0.85, blue: 1.0),
            Color(red: 0.45, green: 0.40, blue: 1.0),
        ])

        for index in 0..<barCount {
            let t = Double(index) / Double(barCount - 1)
            let phase = t * .pi * 2 * 2.5 + time * (isActive ? 5.5 : 1.8)
            // Gentle idle breathing even when silent.
            let idleWave = 0.08 + 0.06 * sin(phase)
            // Level-driven bars with a moving envelope while speaking.
            let speechWave = isActive ? Double(level) * (0.35 + 0.65 * abs(sin(phase))) : 0
            let amplitude = max(idleWave, speechWave)
            let barHeight = max(4, size.height * amplitude)

            let x = CGFloat(index) * (barWidth + spacing)
            let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

            context.fill(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: midY),
                    endPoint: CGPoint(x: 0, y: midY + barHeight / 2)
                )
            )
        }
    }
}

#Preview {
    WaveformView(level: 0.4, isActive: true)
        .frame(height: 96)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}
