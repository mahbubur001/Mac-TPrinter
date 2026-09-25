import CoreGraphics
import Foundation
import Testing
@testable import TPrinter

struct TSPLCommandBuilderTests {
    @Test func setupAndPrintProduceExpectedLines() {
        var tspl = TSPLCommandBuilder()
        tspl.setup(LabelDocument())
        tspl.print(copies: 2)
        let text = String(decoding: tspl.data, as: UTF8.self)
        #expect(text.hasPrefix("SET TEAR OFF\r\nSIZE 30.0 mm, 15.0 mm\r\nGAP 2.0 mm, 0 mm\r\n"))
        #expect(text.contains("CLS\r\n"))
        #expect(text.hasSuffix("PRINT 1,2\r\n"))
    }

    @Test func quotesAreEscaped() {
        #expect(TSPLCommandBuilder.quote(#"a"b"#) == #""a\["]b""#)
    }

    @Test func bitmapEmbedsRawBytes() {
        var tspl = TSPLCommandBuilder()
        tspl.bitmap(x: 0, y: 0, widthBytes: 2, height: 1, packedRows: Data([0x00, 0xFF]))
        let expected = Data("BITMAP 0,0,2,1,0,".utf8) + Data([0x00, 0xFF, 0x0D, 0x0A])
        #expect(tspl.data == expected)
    }
}

struct LabelRasterizerTests {
    @Test func blackPixelsBecomeZeroBits() throws {
        // 16×2 image: left half black, right half white.
        let context = try #require(CGContext(data: nil, width: 16, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 2))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 2))
        let image = try #require(context.makeImage())

        let bitmap = try #require(LabelRasterizer.monochrome(from: image, widthDots: 16, heightDots: 2))
        #expect(bitmap.widthBytes == 2)
        #expect(Array(bitmap.rows) == [0x00, 0xFF, 0x00, 0xFF])
    }

    @Test func widthIsPaddedToWholeBytes() throws {
        let context = try #require(CGContext(data: nil, width: 10, height: 1, bitsPerComponent: 8, bytesPerRow: 10,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 1))
        let image = try #require(context.makeImage())
        let bitmap = try #require(LabelRasterizer.monochrome(from: image, widthDots: 10, heightDots: 1))
        #expect(bitmap.widthBytes == 2)
        #expect(Array(bitmap.rows) == [0xFF, 0xFF])
    }

    @MainActor @Test func documentRendersAtPrintResolution() throws {
        let document = LabelDocument()
        let bitmap = try #require(LabelRasterizer.render(document))
        #expect(bitmap.widthDots == 240)
        #expect(bitmap.height == 120)
        #expect(bitmap.rows.contains { $0 != 0xFF }, "label should contain some black dots")
    }
}

struct HexParsingTests {
    @Test func parsesSpacedHex() {
        #expect(Data(hexString: "1B 40 0a") == Data([0x1B, 0x40, 0x0A]))
        #expect(Data(hexString: "1") == nil)
        #expect(Data(hexString: "zz") == nil)
    }
}

struct TestJobTests {
    @Test func testJobIsASCIIAndFitsDefaultLabel() {
        let data = LabelPrintService.testJob(date: Date(timeIntervalSince1970: 0))
        #expect(data.allSatisfy { $0 < 0x80 }, "printer fonts are ASCII-only")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("SIZE 30.0 mm, 15.0 mm\r\nGAP 2.0 mm, 0 mm"))
        #expect(text.contains("BOX 2,2,238,118,2"))
    }
}

struct TearModeTests {
    @Test func everyJobTurnsTearModeOffAndUsesTheRealLabelSize() {
        var tspl = TSPLCommandBuilder()
        tspl.setup(LabelDocument())
        let text = String(decoding: tspl.data, as: UTF8.self)
        #expect(text.hasPrefix("SET TEAR OFF\r\nSIZE 30.0 mm, 15.0 mm\r\nGAP 2.0 mm, 0 mm\r\n"))
        #expect(text.contains("REFERENCE 0,0\r\n"))
        #expect(!text.contains("SHIFT"))
    }
}
