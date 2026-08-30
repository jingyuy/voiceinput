import SwiftUI
import UIKit

/// A press-and-slide symbol key: touching it pops a row of options up above
/// the key immediately. The option directly above the press point is
/// highlighted at touch-down; the user slides onto an option and lifts to
/// insert it (what's highlighted is what's inserted). Sliding away below or
/// past the popover cancels.
///
/// Layout: the popover is wider than the key and horizontally CENTERED on
/// it, so it extends over earlier siblings (the space key) and later ones
/// (return / delete). The whole component is raised with `.zIndex` in the
/// bottom row so the popover draws above those siblings.
struct SymbolKeyView: View {
    let options: [String]
    let onSelect: (String) -> Void

    var keyWidth: CGFloat = 84
    private let keyHeight: CGFloat = 46
    private let bubbleSize: CGFloat = 40
    private let popoverGap: CGFloat = 6
    private let spacing: CGFloat = 2
    private let horizontalPadding: CGFloat = 6

    @State private var isPressing = false
    @State private var selection: Int?

    private var popoverWidth: CGFloat {
        CGFloat(options.count) * bubbleSize
            + CGFloat(max(options.count - 1, 0)) * spacing
            + horizontalPadding * 2
    }

    private var popoverHeight: CGFloat {
        bubbleSize + 8
    }

    /// The popover's rect in this component's coordinate space. The key
    /// occupies y ∈ [0, keyHeight]; with `.bottom` alignment the popover is
    /// horizontally centered on the key, and the `.offset` puts its bottom
    /// edge at y = -popoverGap (just above the key).
    private var popoverRect: CGRect {
        CGRect(
            x: (keyWidth - popoverWidth) / 2,
            y: -popoverGap - popoverHeight,
            width: popoverWidth,
            height: popoverHeight
        )
    }

    private var keyRect: CGRect {
        CGRect(x: 0, y: 0, width: keyWidth, height: keyHeight)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPressing {
                popover
                    .offset(y: -keyHeight - popoverGap)
                    .transition(.scale(scale: 0.6, anchor: .bottom)
                        .combined(with: .opacity))
                    .animation(.spring(duration: 0.12), value: selection)
            }
            key
        }
        .frame(width: keyWidth, height: keyHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleChanged(location: value.location)
                }
                .onEnded { value in
                    handleEnded(location: value.location)
                }
        )
        .animation(.spring(duration: 0.16), value: isPressing)
    }

    // MARK: - Key

    private var key: some View {
        Text(".?!")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPressing ? .white.opacity(0.14) : .white.opacity(0.08))
            )
    }

    // MARK: - Popover

    private var popover: some View {
        HStack(spacing: spacing) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(selection == index ? .black : .white)
                    .frame(width: bubbleSize, height: bubbleSize)
                    .background(Circle().fill(selection == index ? Color.white : Color.clear))
                    .scaleEffect(selection == index ? 1.12 : 1.0)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.15, green: 0.16, blue: 0.22))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        )
    }

    // MARK: - Hit handling

    private func handleChanged(location: CGPoint) {
        if !isPressing {
            isPressing = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        let newSelection = optionIndex(at: location)
        if newSelection != selection {
            selection = newSelection
            if newSelection != nil {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }
    }

    /// The option under the finger, active over the popover AND the key
    /// (the popover is centered on the key, so the option directly above
    /// the press point is highlighted from touch-down). Returns nil when
    /// the finger leaves the zone (below the key or past the popover) —
    /// that cancels the press.
    private func optionIndex(at location: CGPoint) -> Int? {
        guard popoverRect.minX <= location.x, location.x <= popoverRect.maxX else {
            return nil
        }
        if location.y < popoverRect.minY || location.y > keyRect.maxY {
            return nil
        }
        let bubbleWidth = popoverRect.width / CGFloat(options.count)
        let raw = Int((location.x - popoverRect.minX) / bubbleWidth)
        return min(max(raw, 0), options.count - 1)
    }

    private func handleEnded(location: CGPoint) {
        // What's highlighted is what's inserted; a nil selection cancels.
        if let index = selection, index < options.count {
            onSelect(options[index])
        }
        isPressing = false
        selection = nil
    }
}
