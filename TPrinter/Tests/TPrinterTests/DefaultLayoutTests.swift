import CoreGraphics
import SwiftUI
import Testing
@testable import TPrinter

@MainActor
struct DefaultLayoutTests {
    private func frame(of element: LabelElement) throws -> CGRect {
        let renderer = ImageRenderer(content: LabelElementView(element: element))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGRect(x: element.x * dotsPerMM, y: element.y * dotsPerMM, width: CGFloat(image.width), height: CGFloat(image.height))
    }

    @Test func everyElementFitsInsideTheLabel() throws {
        let document = LabelDocument()
        let label = CGRect(x: 0, y: 0, width: document.widthDots, height: document.heightDots)
        for element in document.elements {
            let rect = try frame(of: element)
            #expect(label.contains(rect), "\(element.kind) \(rect) is outside \(label)")
        }
    }

    @Test func elementsDoNotOverlap() throws {
        let rects = try LabelDocument().elements.map(frame(of:))
        for i in rects.indices {
            for j in rects.indices where j > i {
                #expect(!rects[i].intersects(rects[j]), "elements \(i) and \(j) overlap: \(rects[i]) / \(rects[j])")
            }
        }
    }
}

struct ElementDragMathTests {
    private let label = CGSize(width: 30, height: 15)
    private let size = CGSize(width: 10, height: 5)

    @Test func translationInDotsBecomesMillimetres() {
        // 16 dots right, 8 dots down = +2 mm, +1 mm
        let p = ElementDragMath.position(start: CGPoint(x: 1.5, y: 1.5), translationDots: CGSize(width: 16, height: 8),
                                         sizeMM: size, labelMM: label, snaps: false)
        #expect(p == CGPoint(x: 3.5, y: 2.5))
    }

    @Test func snapsToHalfMillimetreGrid() {
        let p = ElementDragMath.position(start: .zero, translationDots: CGSize(width: 13, height: 21), // 1.625, 2.625 mm
                                         sizeMM: size, labelMM: label, snaps: true)
        #expect(p == CGPoint(x: 1.5, y: 2.5))
    }

    @Test func keepsElementOnTheLabel() {
        let farRight = ElementDragMath.position(start: CGPoint(x: 15, y: 5), translationDots: CGSize(width: 800, height: 800),
                                                sizeMM: size, labelMM: label, snaps: true)
        #expect(farRight == CGPoint(x: 20, y: 10)) // 30 - 10, 15 - 5
        let farLeft = ElementDragMath.position(start: CGPoint(x: 2, y: 2), translationDots: CGSize(width: -800, height: -800),
                                               sizeMM: size, labelMM: label, snaps: true)
        #expect(farLeft == .zero)
    }

    @Test func oversizedElementIsPinnedToTopLeft() {
        let p = ElementDragMath.position(start: .zero, translationDots: CGSize(width: 40, height: 40),
                                         sizeMM: CGSize(width: 40, height: 20), labelMM: label, snaps: true)
        #expect(p == .zero)
    }
}
