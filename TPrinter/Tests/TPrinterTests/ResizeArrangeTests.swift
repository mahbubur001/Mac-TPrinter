import CoreGraphics
import Foundation
import Testing
@testable import TPrinter

struct ElementResizeTests {
    private var icon: LabelElement { var e = LabelElement.make(.icon); e.x = 5; e.y = 4; e.iconSizeMM = 8; return e }
    private let square = CGSize(width: 8, height: 8)

    @Test func cornerFollowsTheDiagonalContinuously() {
        // Growing along the diagonal by (2, 2) on an 8×8 element: 8 → 10.
        let r = ElementResize.resized(icon, handle: .bottomTrailing, translationMM: CGSize(width: 2, height: 2), sizeMM: square)
        #expect(abs(r.iconSizeMM - 10) < 0.001)
        #expect(r.x == 5 && r.y == 4)
        // Tiny drags give tiny changes (0.1 mm steps) — no jumps.
        let small = ElementResize.resized(icon, handle: .bottomTrailing, translationMM: CGSize(width: 0.2, height: 0.2), sizeMM: square)
        #expect(abs(small.iconSizeMM - 8.2) < 0.001)
    }

    @Test func diagonalDragIsMonotonicWithoutJumps() {
        // Sweep a drag that wobbles between mostly-x and mostly-y: size must never step backwards.
        var previous = 0.0
        for i in 1...40 {
            let t = Double(i) * 0.25
            let wobble = i.isMultiple(of: 2) ? 0.3 : -0.3
            let r = ElementResize.resized(icon, handle: .bottomTrailing, translationMM: CGSize(width: t + wobble, height: t - wobble),
                                          sizeMM: square, rounds: false)
            #expect(r.iconSizeMM >= previous)
            previous = r.iconSizeMM
        }
    }

    @Test func topLeftKeepsTheOppositeCornerFixed() {
        let r = ElementResize.resized(icon, handle: .topLeading, translationMM: CGSize(width: -2, height: -2), sizeMM: square)
        #expect(abs(r.iconSizeMM - 10) < 0.001)
        #expect(abs(r.x - 3) < 0.001 && abs(r.y - 2) < 0.001)
    }

    @Test func sideHandlesScaleProportionalElementsFromOneAxis() {
        var image = LabelElement.make(.image); image.imageWidthMM = 10
        let r = ElementResize.resized(image, handle: .trailing, translationMM: CGSize(width: 2.34, height: 5), sizeMM: CGSize(width: 10, height: 5))
        #expect(abs(r.imageWidthMM - 12.3) < 0.001) // vertical movement ignored on a side handle
        let top = ElementResize.resized(image, handle: .top, translationMM: CGSize(width: 0, height: -1), sizeMM: CGSize(width: 10, height: 5))
        #expect(abs(top.imageWidthMM - 12) < 0.001)   // height 5 → 6 = ×1.2
        #expect(abs(top.y - (image.y - 1)) < 0.001)
    }

    @Test func textHandlesSetTheBoxAndNeverTheFont() {
        let text = LabelElement(kind: .text, content: "Hello", x: 1, y: 1, fontSizeMM: 3)
        let side = ElementResize.resized(text, handle: .trailing, translationMM: CGSize(width: -4, height: 0), sizeMM: CGSize(width: 14, height: 4))
        #expect(side.wrapsText && !side.shrinksToFit)
        #expect(abs(side.fitWidthMM - 10) < 0.001)
        #expect(side.fontSizeMM == 3 && side.boxHeightMM == 0) // height still follows the lines
        let corner = ElementResize.resized(text, handle: .bottomTrailing, translationMM: CGSize(width: 6, height: 2), sizeMM: CGSize(width: 14, height: 4))
        #expect(corner.fontSizeMM == 3)
        #expect(abs(corner.fitWidthMM - 20) < 0.001 && abs(corner.boxHeightMM - 6) < 0.001)
    }

    @Test func barcodeWidthStepsAndHeightFollows() {
        var barcode = LabelElement.make(.barcode); barcode.barcodeModuleDots = 1; barcode.barcodeHeightMM = 5
        let wide = ElementResize.resized(barcode, handle: .trailing, translationMM: CGSize(width: 13, height: 0), sizeMM: CGSize(width: 13, height: 8))
        #expect(wide.barcodeModuleDots == 2 && wide.barcodeHeightMM == 5)
        let tall = ElementResize.resized(barcode, handle: .bottom, translationMM: CGSize(width: 0, height: 1.3), sizeMM: CGSize(width: 13, height: 8))
        #expect(tall.barcodeModuleDots == 1 && abs(tall.barcodeHeightMM - 6.3) < 0.001)
    }

    @Test func neverShrinksBelowTheMinimum() {
        let r = ElementResize.resized(icon, handle: .bottomTrailing, translationMM: CGSize(width: -50, height: -50), sizeMM: square, rounds: false)
        #expect(r.iconSizeMM >= ElementResize.minimumMM)
    }
}

struct ArrangeAlignTests {
    private func elements() -> [LabelElement] {
        ["A", "B", "C"].map { LabelElement(kind: .text, content: $0, x: 0, y: 0) }
    }

    @Test func arrangementsReorderBackToFront() {
        for (arrangement, expected) in [(Arrangement.front, "BCA"), (.back, "ABC"), (.forward, "BAC"), (.backward, "ABC")] {
            var list = elements()
            arrangement.apply(to: &list, id: list[0].id)
            #expect(list.map(\.content).joined() == expected, "\(arrangement.title)")
        }
        var list = elements()
        Arrangement.backward.apply(to: &list, id: list[2].id)
        #expect(list.map(\.content).joined() == "ACB")
    }

    @Test func alignmentPositionsOnTheLabel() {
        let e = LabelElement(kind: .text, content: "x", x: 3, y: 4)
        let size = CGSize(width: 10, height: 5), label = CGSize(width: 30, height: 15)
        #expect(LabelAlignment.center.position(for: e, size: size, label: label) == CGPoint(x: 10, y: 4))
        #expect(LabelAlignment.right.position(for: e, size: size, label: label) == CGPoint(x: 20, y: 4))
        #expect(LabelAlignment.middle.position(for: e, size: size, label: label) == CGPoint(x: 3, y: 5))
        #expect(LabelAlignment.bottom.position(for: e, size: size, label: label) == CGPoint(x: 3, y: 10))
        // Too big for the label: pinned at 0, never negative.
        #expect(LabelAlignment.center.position(for: e, size: CGSize(width: 40, height: 5), label: label).x == 0)
    }
}

@MainActor
struct ElementActionTests {
    private func session() -> LabelSession { LabelSession(defaults: UserDefaults(suiteName: "TPrinterActions-\(UUID())")!) }

    @Test func duplicateAddsOffsetCopyOnTop() throws {
        let s = session()
        let original = s.document.elements[0]
        let copyID = try #require(s.duplicateElement(original.id))
        #expect(s.document.elements.last?.id == copyID)
        #expect(s.document.elements.last?.x == original.x + 1)
        #expect(s.document.elements.last?.content == original.content)
    }

    @Test func deleteArrangeAlignAndUpdate() {
        let s = session()
        let first = s.document.elements[0]
        s.arrange(first.id, .front)
        #expect(s.document.elements.last?.id == first.id)
        s.align(first.id, .left, elementSize: CGSize(width: 5, height: 3))
        #expect(s.document.elements.last?.x == 0)
        var edited = first; edited.content = "Changed"
        s.updateElement(edited, actionName: "Edit")
        #expect(s.document.elements.first { $0.id == first.id }?.content == "Changed")
        s.deleteElement(first.id)
        #expect(!s.document.elements.contains { $0.id == first.id })
    }
}

@MainActor
struct LayerNameTests {
    @Test func automaticNamesComeFromContent() {
        #expect(LabelElement(kind: .text, content: "Hello\nWorld", x: 0, y: 0).layerName == "Hello World")
        #expect(LabelElement(kind: .text, content: "", x: 0, y: 0).layerName == "Text")
        #expect(LabelElement.make(.icon).layerName == "Icon")
        #expect(LabelElement.image(Data(), named: "logo").layerName == "logo")
    }

    @Test func renameSetsAndClearsTheCustomName() {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterRename-\(UUID())")!)
        let id = session.document.elements[0].id
        session.renameElement(id, to: "  Product name  ")
        #expect(session.document.elements[0].name == "Product name")
        #expect(session.document.elements[0].layerName == "Product name")
        session.renameElement(id, to: "")
        #expect(session.document.elements[0].layerName == session.document.elements[0].content, "empty → automatic")
    }

    @Test func nameSurvivesTemplatesAndOldFilesStillOpen() throws {
        var document = LabelDocument()
        document.elements[0].name = "Title"
        #expect(try LabelTemplate.decode(LabelTemplate.encode(document)).elements[0].name == "Title")
        let old = #"{"format":"tprinter-label","version":1,"label":{"elements":[{"kind":"text","content":"Hi"}]}}"#
        #expect(try LabelTemplate.decode(Data(old.utf8)).elements[0].name == "")
    }
}
