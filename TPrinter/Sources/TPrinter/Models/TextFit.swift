import AppKit
import SwiftUI

/// "Shrink to fit" for text elements: the size text is actually drawn at, so long values (e.g. a
/// long product name from a CSV row) fit their space while short ones keep the chosen size.
enum TextFit {
    /// Smallest size shrinking goes to; below ~1 mm (8 dots) printed text is unreadable.
    static let minimumSizeMM = 1.0
    /// SwiftUI and AppKit measure a hair differently; leave a little room so text never clips.
    private static let safety = 0.97

    /// The font size to draw `element` at: `fontSizeMM`, or smaller so the widest line fits
    /// `fitWidthMM`. Never larger than `fontSizeMM`.
    static func fontSizeMM(for element: LabelElement) -> Double {
        guard element.kind.isTextual, element.shrinksToFit, !element.wrapsText, element.fitWidthMM > 0 else { return element.fontSizeMM }
        let natural = widthMM(of: element, sizeMM: element.fontSizeMM)
        guard natural > element.fitWidthMM else { return element.fontSizeMM }
        // Text width scales ~linearly with size; one correction pass handles hinting differences.
        var size = element.fontSizeMM * element.fitWidthMM / natural * safety
        let check = widthMM(of: element, sizeMM: size)
        if check > element.fitWidthMM { size *= element.fitWidthMM / check * safety }
        return max(minimumSizeMM, size)
    }

    /// Width of the widest line, in mm, drawn with the system font at `sizeMM`.
    static func widthMM(of text: String, sizeMM: Double, bold: Bool) -> Double {
        var element = LabelElement(kind: .text, content: text, x: 0, y: 0, fontSizeMM: sizeMM)
        element.fontWeight = bold ? .bold : .regular
        return widthMM(of: element, sizeMM: sizeMM)
    }

    /// Width of the element's widest line at `sizeMM`, with its font, weight, italic and letter spacing.
    static func widthMM(of element: LabelElement, sizeMM: Double) -> Double {
        let font = nsFont(for: element, sizeDots: sizeMM * dotsPerMM)
        let kern = element.letterSpacingMM * dotsPerMM
        let widest = element.displayText.components(separatedBy: .newlines)
            .map { NSAttributedString(string: $0, attributes: [.font: font, .kern: kern]).size().width }
            .max() ?? 0
        return widest / dotsPerMM
    }

    /// SwiftUI font for a text element's family and weight.
    static func font(for element: LabelElement, sizeDots: CGFloat) -> Font {
        let weight = element.resolvedWeight.fontWeight
        switch element.fontFamily {
        case "system": return .system(size: sizeDots, weight: weight)
        case "rounded": return .system(size: sizeDots, weight: weight, design: .rounded)
        case "serif": return .system(size: sizeDots, weight: weight, design: .serif)
        case "monospaced": return .system(size: sizeDots, weight: weight, design: .monospaced)
        default: return .custom(element.fontFamily, size: sizeDots).weight(weight)
        }
    }

    /// AppKit font matching `font(for:)`, for measuring.
    static func nsFont(for element: LabelElement, sizeDots: CGFloat) -> NSFont {
        let weight = element.resolvedWeight.nsWeight
        let base = NSFont.systemFont(ofSize: sizeDots, weight: weight)
        var descriptor: NSFontDescriptor
        switch element.fontFamily {
        case "system": descriptor = base.fontDescriptor
        case "rounded": descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        case "serif": descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        case "monospaced": descriptor = base.fontDescriptor.withDesign(.monospaced) ?? base.fontDescriptor
        default:
            descriptor = NSFontDescriptor(fontAttributes: [.family: element.fontFamily,
                                                            .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        }
        if element.italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        return NSFont(descriptor: descriptor, size: sizeDots) ?? base
    }

    /// Font families the text inspector offers: designs of the system font, then installed families.
    static var installedFamilies: [String] { NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") } }

    /// Printer-resident fonts (TSPL "1"…"5"), character cell in dots.
    private static let nativeFonts: [(name: String, width: Int, height: Int)] = [
        ("1", 8, 12), ("2", 12, 20), ("3", 16, 24), ("4", 24, 32), ("5", 32, 48),
    ]

    /// Native TSPL font + multiplier for a text element. Without shrink-to-fit: font "3" scaled to
    /// the size. With it: the tallest font/multiplier that is no taller than the chosen size and fits
    /// the width; falls back to the smallest font.
    static func nativeFont(for element: LabelElement) -> (font: String, multiplier: Int) {
        let targetDots = element.fontSizeMM * dotsPerMM
        guard element.shrinksToFit else {
            return ("3", min(max(Int((targetDots / 24).rounded()), 1), 10))
        }
        let longestLine = element.displayText.components(separatedBy: .newlines).map(\.count).max() ?? 0
        let maxWidthDots = element.fitWidthMM * dotsPerMM
        let candidates = nativeFonts.flatMap { font in (1...10).map { (font, $0) } }
            .filter { font, mul in
                Double(font.height * mul) <= max(targetDots, 12) && Double(font.width * mul * longestLine) <= maxWidthDots
            }
        // Tallest wins; on a tie prefer the smaller multiplier (a native-size font prints crisper).
        guard let best = candidates.max(by: { a, b in
            let (ha, hb) = (a.0.height * a.1, b.0.height * b.1)
            return ha != hb ? ha < hb : a.1 > b.1
        }) else { return ("1", 1) }
        return (best.0.name, best.1)
    }
}
