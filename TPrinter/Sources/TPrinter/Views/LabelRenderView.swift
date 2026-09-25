import AppKit
import SwiftUI

/// Draws the label at print resolution: 1 point = 1 printer dot.
/// Used for both the on-screen preview (scaled) and the bitmap print path.
struct LabelRenderView: View {
    let document: LabelDocument
    /// White for printing; the preview uses the paper tone.
    var paper: Color = .white

    var body: some View {
        ZStack(alignment: .topLeading) {
            paper
            ForEach(document.elements.filter { !$0.isHidden }) { element in
                LabelElementView(element: element)
                    .offset(x: element.x * dotsPerMM, y: element.y * dotsPerMM)
            }
        }
        .frame(width: CGFloat(document.widthDots), height: CGFloat(document.heightDots), alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

/// One element at print resolution, including its rotation.
struct LabelElementView: View {
    let element: LabelElement

    var body: some View {
        RotationLayout(quarterTurns: element.rotation / 90) {
            content.rotationEffect(.degrees(Double(element.rotation)))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch element.kind {
        case .text: text
        case .barcode: barcode
        case .qrCode: qrCode
        case .image: image
        case .icon: icon
        case .shape: shape
        case .date, .counter: text
        }
    }

    // MARK: Text

    @ViewBuilder
    private var text: some View {
        let size = TextFit.fontSizeMM(for: element) * dotsPerMM
        let styled = Text(element.displayText)
            .font(TextFit.font(for: element, sizeDots: size))
            .italic(element.italic)
            .underline(element.underline)
            .strikethrough(element.strikethrough)
            .kerning(element.letterSpacingMM * dotsPerMM)
        let laidOut = styled
            .lineSpacing(element.lineSpacingMM * dotsPerMM)
            .multilineTextAlignment(element.textAlignment.swiftUI)
            .foregroundStyle(element.invertsText ? .white : .black)

        let boxed = Group {
            if element.wrapsText, element.boxHeightMM > 0 {
                // Fixed text box: lines wrap inside it and whatever doesn't fit is hidden.
                laidOut.frame(width: element.fitWidthMM * dotsPerMM, alignment: element.textAlignment.frameAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: element.fitWidthMM * dotsPerMM, height: element.boxHeightMM * dotsPerMM,
                           alignment: Alignment(horizontal: element.textAlignment.frameAlignment.horizontal, vertical: .top))
                    .clipped()
            } else if element.wrapsText {
                laidOut.frame(width: element.fitWidthMM * dotsPerMM, alignment: element.textAlignment.frameAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            } else if element.shrinksToFit {
                // The element spans its fit width, so selection shows the space the text may use.
                laidOut.fixedSize().frame(width: element.fitWidthMM * dotsPerMM, alignment: element.textAlignment.frameAlignment)
            } else {
                laidOut.fixedSize()
            }
        }
        let pad = element.invertsText || element.outlined ? size * 0.18 : 0
        boxed
            .padding(pad)
            .background(element.invertsText ? Color.black : .clear)
            .overlay { if element.outlined { Rectangle().strokeBorder(.black, lineWidth: max(2, size * 0.08)) } }
            .fixedSize()
    }

    // MARK: Image / icon

    /// Shown pre-dithered at print resolution, so the preview is exactly what prints.
    @ViewBuilder
    private var image: some View {
        let widthDots = Int((element.imageWidthMM * dotsPerMM).rounded())
        if let data = element.imageData,
           let bitmap = MonochromeImage.render(data, widthDots: widthDots, dithers: element.dithers,
                                               threshold: element.imageThreshold, inverted: element.invertsImage,
                                               trims: element.trimsImage, crop: element.cropRect) {
            Image(decorative: bitmap, scale: 1)
                .interpolation(.none)
                .frame(width: CGFloat(bitmap.width), height: CGFloat(bitmap.height))
                // White dots are unprinted paper: let the label show through (no white box in the preview).
                .blendMode(.multiply)
        } else {
            invalid("Image missing")
        }
    }

    @ViewBuilder
    private var icon: some View {
        let side = element.iconSizeMM * dotsPerMM
        let name = element.iconFilled && IconCatalog.isValid(element.content + ".fill") ? element.content + ".fill" : element.content
        if IconCatalog.isValid(name) {
            Image(systemName: name)
                .resizable()
                .fontWeight(element.iconWeight.fontWeight)
                .scaledToFit()
                .foregroundStyle(.black)
                .frame(width: side, height: side)
        } else {
            invalid("Unknown icon")
        }
    }

    // MARK: Shape

    @ViewBuilder
    private var shape: some View {
        let w = element.shapeWidthMM * dotsPerMM
        let h = element.shapeKind == .line ? max(element.lineWidthMM * dotsPerMM, 1) : element.shapeHeightMM * dotsPerMM
        let line = max(element.lineWidthMM * dotsPerMM, 1)
        let style = StrokeStyle(lineWidth: line, dash: element.dashed ? [line * 3, line * 2] : [])
        Group {
            switch element.shapeKind {
            case .line:
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(.black, style: StrokeStyle(lineWidth: h, dash: element.dashed ? [line * 3, line * 2] : []))
            case .rectangle: filledOrStroked(Rectangle(), style: style)
            case .rounded: filledOrStroked(RoundedRectangle(cornerRadius: element.cornerRadiusMM * dotsPerMM), style: style)
            case .ellipse: filledOrStroked(Ellipse(), style: style)
            }
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder
    private func filledOrStroked<S: InsettableShape>(_ shape: S, style: StrokeStyle) -> some View {
        if element.shapeFilled { shape.fill(.black) } else { shape.strokeBorder(.black, style: style) }
    }

    // MARK: Codes

    @ViewBuilder
    private var barcode: some View {
        if let (image, label) = barcodeImage {
            let module = CGFloat(max(element.barcodeModuleDots, 1))
            let quiet = element.barcodeQuietZone ? 10 * module : 0
            let number = Text(label)
                .font(.system(size: element.barcodeNumberSizeMM * dotsPerMM, design: .monospaced))
                .foregroundStyle(.black)
                .fixedSize()
            VStack(alignment: .center, spacing: 2) {
                if element.showsBarcodeText, element.barcodeNumberPosition == .above { number }
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(image.width) * module, height: element.barcodeHeightMM * dotsPerMM)
                    .blendMode(.multiply) // white = unprinted paper
                    .padding(.horizontal, quiet)
                if element.showsBarcodeText, element.barcodeNumberPosition == .below { number }
            }
            .fixedSize()
        } else {
            invalid(barcodeError)
        }
    }

    /// The bars (1 px per module) and the number to print under them.
    private var barcodeImage: (CGImage, String)? {
        if element.barcodeType == .code128 {
            return CodeImageGenerator.code128(element.content).map { ($0, element.content) }
        }
        guard let encoded = try? BarcodeEncoder.encode(element.content, as: element.barcodeType),
              let image = BarcodeEncoder.image(encoded.modules) else { return nil }
        return (image, encoded.text)
    }

    private var barcodeError: String {
        if element.barcodeType == .code128 { return "Barcode: ASCII only" }
        do { _ = try BarcodeEncoder.encode(element.content, as: element.barcodeType); return "Barcode error" }
        catch { return error.localizedDescription }
    }

    @ViewBuilder
    private var qrCode: some View {
        if let image = CodeImageGenerator.qrCode(element.content, correction: element.qrCorrection) {
            let side = element.qrSizeMM * dotsPerMM
            // Snap to a whole number of dots per module so edges stay crisp.
            let module = max((side / CGFloat(image.width)).rounded(.down), 1)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: module * CGFloat(image.width), height: module * CGFloat(image.width))
                .blendMode(.multiply) // white = unprinted paper
        } else {
            invalid("QR: empty")
        }
    }

    private func invalid(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 20))
            .foregroundStyle(.black)
            .padding(4)
            .border(.black)
            .fixedSize()
    }
}

/// Lays a child out with width and height swapped for odd quarter turns, so a rotated element takes
/// the space it visually occupies (rotationEffect alone doesn't change layout).
struct RotationLayout: Layout {
    let quarterTurns: Int

    private var swaps: Bool { abs(quarterTurns) % 2 == 1 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(.unspecified)
        return swaps ? CGSize(width: size.height, height: size.width) : size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}

extension TextAlign {
    var swiftUI: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension TextWeight {
    var fontWeight: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    var isBold: Bool { self == .semibold || self == .bold || self == .heavy }
}

extension IconWeight {
    var fontWeight: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .bold: .bold
        }
    }
}

extension LabelElement {
    /// The weight to draw: `fontWeight`, or Bold for older labels that only set `bold`.
    var resolvedWeight: TextWeight { fontWeight == .regular && bold ? .bold : fontWeight }

    /// Crop as a unit rect, or nil for the full picture.
    var cropRect: CGRect? {
        let rect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        return rect == CGRect(x: 0, y: 0, width: 1, height: 1) ? nil : rect
    }
}
