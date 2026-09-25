import SwiftUI

/// Dark rounded tip beside a control (tool rails, sidebar), shown after a short hover. Faster and
/// clearer than the system tooltip, and never cut off by the window edge on the left rails.
struct HoverTip: ViewModifier {
    enum Edge { case trailing, top }

    let title: String
    var shortcut: String?
    var edge: Edge = .trailing
    @State private var hovering = false
    @State private var shows = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside {
                    // Short delay so sweeping past a column of icons doesn't flash every tip.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if hovering { withAnimation(.easeOut(duration: 0.12)) { shows = true } }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { shows = false }
                }
            }
            .overlay(alignment: edge == .trailing ? .leading : .bottom) {
                GeometryReader { geometry in
                    if shows {
                        TipBubble(title: title, shortcut: shortcut, pointsLeft: edge == .trailing)
                            .fixedSize()
                            .position(edge == .trailing
                                      ? CGPoint(x: geometry.size.width + 12 + tipWidth / 2, y: geometry.size.height / 2)
                                      : CGPoint(x: geometry.size.width / 2, y: -20))
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            }
            .zIndex(shows ? 10 : 0)
    }

    /// Rough width so the bubble starts right next to the control.
    private var tipWidth: CGFloat {
        CGFloat(title.count) * 7.2 + CGFloat((shortcut ?? "").count) * 7 + (shortcut == nil ? 20 : 30)
    }
}

private struct TipBubble: View {
    let title: String
    let shortcut: String?
    let pointsLeft: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let shortcut {
                Text(shortcut).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: pointsLeft ? .leading : .bottom) {
            Image(systemName: pointsLeft ? "arrowtriangle.left.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color(white: 0.17))
                .offset(x: pointsLeft ? -6 : 0, y: pointsLeft ? 0 : 6)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

extension View {
    func hoverTip(_ title: String, shortcut: String? = nil, edge: HoverTip.Edge = .trailing) -> some View {
        modifier(HoverTip(title: title, shortcut: shortcut, edge: edge))
    }
}
