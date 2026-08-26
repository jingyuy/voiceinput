import SwiftUI

/// Dark gradient backdrop with soft ambient glows.
struct BackgroundView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.045, green: 0.05, blue: 0.12),
                    Color(red: 0.07, green: 0.09, blue: 0.19),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Color(red: 0.25, green: 0.45, blue: 1.0).opacity(0.14))
                .frame(width: 340, height: 340)
                .blur(radius: 110)
                .offset(y: -240)
            Circle()
                .fill(Color(red: 0.1, green: 0.85, blue: 0.9).opacity(0.08))
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .offset(y: 320)
        }
        .ignoresSafeArea()
    }
}

#Preview {
    BackgroundView()
}
