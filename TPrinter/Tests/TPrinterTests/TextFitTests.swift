import SwiftUI
import Testing
@testable import TPrinter

@MainActor
struct TextFitTests {
    private func text(_ content: String, fit: Bool = true, width: Double = 16) -> LabelElement {
        var element = LabelElement(kind: .text, content: content, x: 1.5, y: 1.5, fontSizeMM: 3, bold: true)
        element.shrinksToFit = fit
        element.fitWidthMM = width
        return element
    }

    /// Width of the text as SwiftUI actually draws it, in mm.
    private func drawnWidthMM(_ element: LabelElement) throws -> Double {
        let view = Text(element.content)
            .font(.system(size: TextFit.fontSizeMM(for: element) * dotsPerMM, weight: element.bold ? .bold : .regular))
            .fixedSize()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return Double(try #require(renderer.cgImage).width) / dotsPerMM
    }

    @Test func longTextShrinksToFitTheWidth() throws {
        let long = text("Coffee, Dark Roast Beans")
        #expect(TextFit.fontSizeMM(for: long) < 3)
        #expect(try drawnWidthMM(long) <= 16 + 0.25, "drawn text must not be wider than its box (1-2 dot tolerance)")
    }

    @Test func shortTextKeepsItsSizeAndNeverGrows() {
        #expect(TextFit.fontSizeMM(for: text("Tea")) == 3)
        #expect(TextFit.fontSizeMM(for: text("Coffee, Dark Roast Beans", fit: false)) == 3)
    }

    @Test func neverShrinksBelowTheMinimum() {
        #expect(TextFit.fontSizeMM(for: text(String(repeating: "W", count: 200), width: 5)) == TextFit.minimumSizeMM)
    }

    @Test func widestLineDecidesForMultilineText() {
        let lines = text("Short\nA much much longer second line")
        let single = text("A much much longer second line")
        #expect(abs(TextFit.fontSizeMM(for: lines) - TextFit.fontSizeMM(for: single)) < 0.01)
    }

    @Test func nativeFontFitsWidthAndPrefersTheLargest() {
        let short = TextFit.nativeFont(for: text("Tea"))            // 3 chars in 128 dots, ≤ 24 dots tall
        #expect(short.font == "3" && short.multiplier == 1)
        let long = TextFit.nativeFont(for: text("Coffee, Dark Roast"))  // 18 chars in 128 dots → 7 dots each max
        #expect(long.font == "1" && long.multiplier == 1)
        #expect(TextFit.nativeFont(for: text("Tea", fit: false)).font == "3")
    }

    @Test func settingsSurviveTemplateRoundTrip() throws {
        var document = LabelDocument()
        document.elements = [text("{{name}}", width: 14.5)]
        #expect(try LabelTemplate.decode(LabelTemplate.encode(document)) == document)
    }
}
