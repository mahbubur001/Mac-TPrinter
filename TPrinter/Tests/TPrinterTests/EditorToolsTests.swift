import AppKit
import Foundation
import Testing
@testable import TPrinter

@MainActor
struct EditorToolsTests {
    private let label = CGSize(width: 30, height: 15)

    @Test func oldTemplatesKeepBoldAndGetNewDefaults() throws {
        let json = #"{"format":"tprinter-label","version":1,"label":{"elements":[{"kind":"text","content":"Old","bold":true}]}}"#
        let element = try LabelTemplate.decode(Data(json.utf8)).elements[0]
        #expect(element.fontWeight == .bold && element.resolvedWeight == .bold)
        #expect(element.rotation == 0 && !element.isLocked && !element.isHidden && element.fontFamily == "system")
    }

    @Test func newStyleFieldsRoundTrip() throws {
        var element = LabelElement.make(.text)
        element.fontFamily = "serif"; element.fontWeight = .heavy; element.italic = true; element.textCase = .upper
        element.rotation = 90; element.isLocked = true; element.invertsText = true; element.letterSpacingMM = 0.5
        var document = LabelDocument(); document.elements = [element]
        #expect(try LabelTemplate.decode(LabelTemplate.encode(document)) == document)
    }

    @Test func quarterTurnsSwapWidthAndHeight() {
        var element = LabelElement(kind: .text, content: "WIDE TEXT", x: 0, y: 0, fontSizeMM: 3)
        let flat = ElementGeometry.sizeMM(of: element)
        element.rotation = 90
        let turned = ElementGeometry.sizeMM(of: element)
        #expect(abs(turned.width - flat.height) < 0.2 && abs(turned.height - flat.width) < 0.2)
    }

    @Test func overflowIsDetectedAndFixed() {
        var element = LabelElement(kind: .text, content: "VAMPIRE BLOOD", x: 9.5, y: 4, fontSizeMM: 4.5)
        element.fontWeight = .heavy
        #expect(ElementGeometry.overflowMM(of: element, label: label) > 0)

        let shrunk = ElementSizing.textBox(element, label: label, wraps: false)
        #expect(shrunk.shrinksToFit && ElementGeometry.overflowMM(of: shrunk, label: label) == 0)

        var qr = LabelElement.make(.qrCode); qr.x = 20; qr.qrSizeMM = 14
        let fitted = ElementSizing.fittingOnLabel(qr, label: label)
        #expect(ElementGeometry.overflowMM(of: fitted, label: label) == 0)
        #expect(fitted.qrSizeMM < 14)
    }

    @Test func qrHelpersComposeAndParse() {
        var fields = QRContent(); fields.ssid = "Shop"; fields.password = "p;ss"
        let wifi = fields.compose(.wifi)!
        #expect(wifi == #"WIFI:T:WPA;S:Shop;P:p\;ss;;"#)
        let (kind, parsed) = QRContent.parse("MECARD:N:Rumayz;TEL:0123;EMAIL:a@b.c;;")
        #expect(kind == .contact && parsed.phone == "0123" && parsed.email == "a@b.c")
        #expect(QRContent.parse("https://x.y").0 == .link && QRContent.parse("tel:5").1.phone == "5")
    }

    @Test func hiddenElementsDontPrint() throws {
        var document = LabelDocument()
        document.printMethod = .nativeTSPL
        document.elements = [LabelElement(kind: .text, content: "Visible", x: 1, y: 1),
                             { var e = LabelElement(kind: .text, content: "Secret", x: 1, y: 6); e.isHidden = true; return e }()]
        let text = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(text.contains("Visible") && !text.contains("Secret"))
    }

    @Test func styledTextGoesAsDotsInNativeMode() throws {
        var document = LabelDocument()
        document.printMethod = .nativeTSPL
        var fancy = LabelElement(kind: .text, content: "Fancy", x: 1, y: 1)
        fancy.italic = true
        var plain = LabelElement(kind: .text, content: "plain", x: 1, y: 8)
        plain.textCase = .upper
        document.elements = [fancy, plain]
        let text = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(text.components(separatedBy: "BITMAP ").count - 1 == 1)
        #expect(text.contains("\"PLAIN\""), "letter case applies to printer text")
    }

    @Test func invertedImageSwapsBlackAndWhite() throws {
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        func blackShare(_ inverted: Bool) throws -> Double {
            let image = try #require(MonochromeImage.render(data, widthDots: 40, dithers: false, threshold: 0.5, inverted: inverted, trims: false))
            let g = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            g.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let p = UnsafeBufferPointer(start: g.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height)
            return Double(p.filter { $0 == 0 }.count) / Double(p.count)
        }
        #expect(abs(try blackShare(false) - 0.5) < 0.05)
        #expect(abs(try blackShare(true) - 0.5) < 0.05)
        #expect(try blackShare(false) + blackShare(true) > 0.95)
    }
}
