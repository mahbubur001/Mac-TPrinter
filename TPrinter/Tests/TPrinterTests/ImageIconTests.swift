import AppKit
import Foundation
import Testing
@testable import TPrinter

/// PNG test pictures drawn in code.
private enum Fixture {
    /// Horizontal grey ramp (a "photo").
    static func gradient(width: Int = 200, height: Int = 100) -> Data {
        draw(width: width, height: height) { ctx in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                               colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        }
    }

    /// Black square on white (a "logo").
    static func logo(width: Int = 200, height: Int = 100) -> Data {
        draw(width: width, height: height) { ctx in
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        body(ctx)
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }
}

private func pixels(_ image: CGImage) -> [UInt8] {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height))
}

struct MonochromeImageTests {
    @Test func outputIsPureBlackAndWhiteAtRequestedWidthKeepingAspect() throws {
        let image = try #require(MonochromeImage.render(Fixture.gradient(), widthDots: 80, dithers: true, threshold: 0.5))
        #expect(image.width == 80)
        #expect(image.height == 40)
        #expect(Set(pixels(image)).isSubset(of: [0, 255]))
    }

    @Test func ditheringShadesAGradientThresholdSplitsIt() throws {
        let data = Fixture.gradient()
        let dithered = pixels(try #require(MonochromeImage.render(data, widthDots: 80, dithers: true, threshold: 0.5)))
        let thresholded = pixels(try #require(MonochromeImage.render(data, widthDots: 80, dithers: false, threshold: 0.5)))
        func blackShare(_ p: [UInt8], columns: Range<Int>) -> Double {
            let rows = p.count / 80
            let values = (0..<rows).flatMap { r in columns.map { p[r * 80 + $0] } }
            return Double(values.filter { $0 == 0 }.count) / Double(values.count)
        }
        // Middle-grey band: dithering mixes black and white, threshold gives solid blocks per side.
        let mid = blackShare(dithered, columns: 30..<50)
        #expect(mid > 0.2 && mid < 0.8)
        #expect(blackShare(thresholded, columns: 0..<30) > 0.95)
        #expect(blackShare(thresholded, columns: 50..<80) < 0.05)
    }

    @Test func unreadableDataGivesNil() {
        #expect(MonochromeImage.render(Data("nope".utf8), widthDots: 50, dithers: true, threshold: 0.5) == nil)
    }
}

struct ImageImportTests {
    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try data.write(to: url)
        return url
    }

    @Test func fitsInsideLabelWithMarginAndDetectsLineArt() throws {
        let url = try write(Fixture.logo(width: 200, height: 100)) // 2:1
        defer { try? FileManager.default.removeItem(at: url) }
        let element = try ImageImport.element(from: url, label: CGSize(width: 30, height: 15))
        #expect(element.kind == .image)
        // Margins trimmed to the black square (+3 % border): ~1.9:1, fitted to the 11 mm usable height.
        #expect(element.imageWidthMM > 20 && element.imageWidthMM < 21.5, "got \(element.imageWidthMM)")
        #expect(element.dithers == false, "black-on-white logo → line art")
        #expect(element.imageThreshold == 0.75)
    }

    @Test func photosDitherAndHugeImagesAreScaledDown() throws {
        let url = try write(Fixture.gradient(width: 3000, height: 1000))
        defer { try? FileManager.default.removeItem(at: url) }
        let element = try ImageImport.element(from: url, label: CGSize(width: 30, height: 15))
        #expect(element.dithers)
        let stored = try #require(element.imageData)
        let size = try #require(MonochromeImage.pixelSize(of: stored))
        // Scaled to 960 px, then the pure-white end of the ramp is trimmed a little.
        #expect(size.width <= CGFloat(ImageImport.maxPixelWidth) && size.width > 800, "got \(size)")
    }

    @Test func rejectsNonImages() throws {
        let url = try write(Data("not an image".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ImageImport.ImportError.self) { try ImageImport.element(from: url, label: CGSize(width: 30, height: 15)) }
    }
}

struct ImageIconElementTests {
    @Test func imageDataSurvivesTemplateRoundTrip() throws {
        var document = LabelDocument()
        document.elements = [LabelElement.image(Fixture.logo(), named: "Logo"), LabelElement.make(.icon)]
        document.elements[0].dithers = false
        let decoded = try LabelTemplate.decode(LabelTemplate.encode(document))
        #expect(decoded == document)
    }

    @Test func iconCatalogIsValidAndSearchable() {
        #expect(IconCatalog.groups.allSatisfy { !$0.symbols.isEmpty })
        #expect(IconCatalog.groups.flatMap(\.symbols).allSatisfy(IconCatalog.isValid))
        #expect(IconCatalog.search("snow").contains("snowflake"))
        #expect(IconCatalog.search("paperplane").first == "paperplane", "any valid SF Symbol name works")
        #expect(IconCatalog.search("definitely.not.a.symbol").isEmpty)
    }

    @MainActor @Test func iconAndImageRenderToBlackDots() throws {
        for element in [LabelElement.make(.icon), LabelElement.image(Fixture.logo(), named: "Logo")] {
            let bitmap = try #require(LabelRasterizer.render(element))
            #expect(bitmap.rows.contains { $0 != 0xFF }, "\(element.kind) should print something")
        }
    }

    @MainActor @Test func nativeModeSendsImagesAndIconsAsBitmaps() throws {
        var document = LabelDocument()
        document.printMethod = .nativeTSPL
        document.elements = [LabelElement(kind: .text, content: "Hi", x: 1, y: 1), LabelElement.make(.icon),
                             LabelElement.image(Fixture.logo(), named: "Logo")]
        let text = String(decoding: try LabelPrintService.job(for: document), as: UTF8.self)
        #expect(text.components(separatedBy: "BITMAP ").count - 1 == 2)
        #expect(text.contains("TEXT "))
    }
}

/// Regressions from a real logo: gold artwork on a large white canvas printed blank.
struct LightLogoTests {
    /// Gold (#D4A64A-ish) shaded rings — thin strokes like real logo artwork — on a big white canvas.
    private func goldLogo() -> Data {
        let size = 400
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for (i, shade) in [0.83, 0.75, 0.68].enumerated() { // lighter → darker gold, all above 50 % luminance
            ctx.setFillColor(CGColor(red: shade, green: shade * 0.78, blue: shade * 0.35, alpha: 1))
            ctx.setStrokeColor(CGColor(red: shade, green: shade * 0.78, blue: shade * 0.35, alpha: 1))
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: 150 + i * 10, y: 150 + i * 10, width: 100 - i * 20, height: 100 - i * 20))
        }
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    @Test func lightColouredArtworkStillPrintsBlack() throws {
        let image = try #require(MonochromeImage.render(goldLogo(), widthDots: 100, dithers: false, threshold: 0.5))
        let black = pixels(image).filter { $0 == 0 }.count
        // ~1-dot rings at this size ≈ 190 dots of ink; before auto-levels this was 0 (all gold > 50 % cut).
        #expect(black > 60, "gold must become black dots, got \(black)")
    }

    @Test func importTrimsMarginsAndPicksLineArt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try goldLogo().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let element = try ImageImport.element(from: url, label: CGSize(width: 30, height: 15))
        let stored = try #require(element.imageData)
        let size = try #require(MonochromeImage.pixelSize(of: stored))
        #expect(size.width < 140 && size.height < 140, "400 px canvas trimmed to the ~100 px artwork, got \(size)")
        #expect(element.dithers == false)
    }
}
