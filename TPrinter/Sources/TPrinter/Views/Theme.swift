import AppKit
import SwiftUI

/// Design tokens. The palette comes from the physical label roll: silicone liner, thermal paper,
/// black print, and the printer's status LED. Selection uses the system accent color.
enum Theme {
    /// Label backing paper (the roll's liner). A physical material, so it keeps its colour in dark
    /// mode — the strip reads as paper lying on the (dark) desk.
    static let liner = Color(hex: 0xD6DAD3)
    /// Slightly darker liner edge / die-cut outline.
    static let linerEdge = Color(hex: 0xBFC5BB)
    /// Thermal paper. Always light: it's what prints.
    static let paper = Color(hex: 0xFBFBF8)
    /// Printer LED states.
    static let ledReady = Color(hex: 0x22A06B)
    static let ledBusy = Color(hex: 0xD99A0B)
    static let ledOff = Color(light: 0x9AA09A, dark: 0x6C726C)

    /// Die-cut corner radius of the label, in mm.
    static let labelCornerMM: CGFloat = 1.2
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// Adapts to the window's light / dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The printer's status as a small LED dot, like the one on the RP310.
struct StatusLED: View {
    enum State { case ready, busy, off, problem }
    let state: State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .shadow(color: state == .ready ? color.opacity(0.6) : .clear, radius: 3)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .ready: Theme.ledReady
        case .busy: Theme.ledBusy
        case .off: Theme.ledOff
        case .problem: .red
        }
    }
}
