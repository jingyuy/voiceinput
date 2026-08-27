import SwiftUI

/// Lightweight animated waveform for the keyboard overlay.
/// Mirrors the app's aesthetic without sharing the app-target view.
struct WaveformBarsView: View {
    let level: Float
    let isActive: Bool

    private let barCount = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.teal.opacity(0.85))
                        .frame(width: 3, height: barHeight(index: index, time: time))
                        .animation(.easeOut(duration: 0.15), value: level)
                }
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isActive else {
            // Gentle idle shimmer so the waveform looks alive when idle.
            return 4 + CGFloat(index % 5) * 2
        }
        let wave = sin(time * 8 + Double(index) * 0.6)
        let base = 8 + Double(level) * 30
        return CGFloat(max(4, base + wave * 6))
    }
}
