import CoreGraphics
import SwiftUI

/// The eight handles around the selected element: four corners and four sides.
enum ResizeHandle: CaseIterable {
    case topLeading, top, topTrailing, trailing, bottomTrailing, bottom, bottomLeading, leading

    /// +1: dragging right/down grows the element; −1: dragging left/up grows it; 0: this axis isn't affected.
    var xSign: CGFloat {
        switch self {
        case .topTrailing, .trailing, .bottomTrailing: 1
        case .topLeading, .leading, .bottomLeading: -1
        case .top, .bottom: 0
        }
    }

    var ySign: CGFloat {
        switch self {
        case .bottomLeading, .bottom, .bottomTrailing: 1
        case .topLeading, .top, .topTrailing: -1
        case .leading, .trailing: 0
        }
    }

    var isCorner: Bool { xSign != 0 && ySign != 0 }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .trailing: .trailing
        case .bottomTrailing: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeading: .bottomLeading
        case .leading: .leading
        }
    }
}

enum ElementResize {
    /// Smallest size a resize can produce, in mm.
    static let minimumMM = 1.5
    /// Sizes are rounded to this while dragging: fine enough to feel continuous (⌥ turns it off).
    static let stepMM = 0.1

    /// The element after dragging `handle` by `translationMM`, the opposite side/corner staying put.
    /// - Parameters:
    ///   - sizeMM: the element's rendered size when the drag began.
    ///   - rounds: round to `stepMM` (⌥ turns this off).
    static func resized(
        _ element: LabelElement,
        handle: ResizeHandle,
        translationMM: CGSize,
        sizeMM: CGSize,
        rounds: Bool = true
    ) -> LabelElement {
        guard sizeMM.width > 0, sizeMM.height > 0 else { return element }
        let dx = translationMM.width * handle.xSign
        let dy = translationMM.height * handle.ySign

        var result = element
        var newSize = sizeMM

        switch element.kind {
        case .barcode:
            // Width in whole bar-width steps; height follows the drag directly.
            if handle.xSign != 0 {
                let modules = max(1, min(6, Int((Double(element.barcodeModuleDots) * (sizeMM.width + dx) / sizeMM.width).rounded())))
                result.barcodeModuleDots = modules
                newSize.width = sizeMM.width * CGFloat(modules) / CGFloat(max(element.barcodeModuleDots, 1))
            }
            if handle.ySign != 0 {
                result.barcodeHeightMM = value(element.barcodeHeightMM + dy, rounds)
                newSize.height = sizeMM.height + (result.barcodeHeightMM - element.barcodeHeightMM)
            }

        case .shape:
            // Shapes stretch freely on each axis; a line only has a length.
            if handle.xSign != 0 {
                result.shapeWidthMM = value(element.shapeWidthMM + dx, rounds)
                newSize.width = sizeMM.width + (result.shapeWidthMM - element.shapeWidthMM)
            }
            if handle.ySign != 0, element.shapeKind != .line {
                result.shapeHeightMM = value(element.shapeHeightMM + dy, rounds)
                newSize.height = sizeMM.height + (result.shapeHeightMM - element.shapeHeightMM)
            }

        case .text, .date, .counter:
            // Handles set the text box, never the font size: text wraps inside the width, and a set
            // height hides whatever doesn't fit. (Invert / outline padding sits outside the box.)
            let pad = element.invertsText || element.outlined ? 2 * TextFit.fontSizeMM(for: element) * 0.18 : 0
            result.wrapsText = true
            result.shrinksToFit = false
            if handle.xSign != 0 {
                let base = element.wrapsText ? element.fitWidthMM : max(sizeMM.width - pad, minimumMM)
                result.fitWidthMM = value(base + dx, rounds)
                newSize.width = sizeMM.width + (result.fitWidthMM - base)
            } else if !element.wrapsText {
                result.fitWidthMM = value(sizeMM.width - pad, rounds)
            }
            if handle.ySign != 0 {
                let base = element.boxHeightMM > 0 ? element.boxHeightMM : max(sizeMM.height - pad, minimumMM)
                result.boxHeightMM = value(base + dy, rounds)
                newSize.height = sizeMM.height + (result.boxHeightMM - base)
            }

        default:
            let scale = proportionalScale(dx: dx, dy: dy, handle: handle, size: sizeMM)
            var applied = scale
            switch element.kind {
            case .image:
                result.imageWidthMM = value(element.imageWidthMM * scale, rounds)
                applied = result.imageWidthMM / element.imageWidthMM
            case .icon:
                result.iconSizeMM = value(element.iconSizeMM * scale, rounds)
                applied = result.iconSizeMM / element.iconSizeMM
            case .qrCode:
                result.qrSizeMM = value(element.qrSizeMM * scale, rounds)
                applied = result.qrSizeMM / element.qrSizeMM
            case .barcode, .shape, .text, .date, .counter:
                break
            }
            newSize = CGSize(width: sizeMM.width * applied, height: sizeMM.height * applied)
        }

        // Keep the opposite side fixed: left/top handles move the origin by the size change.
        if handle.xSign < 0 { result.x = max(0, element.x + sizeMM.width - newSize.width) }
        if handle.ySign < 0 { result.y = max(0, element.y + sizeMM.height - newSize.height) }
        return result
    }

    /// Continuous scale factor. Corners project the drag onto the element's diagonal, so moving
    /// diagonally changes size smoothly instead of flipping between the x and y changes.
    static func proportionalScale(dx: CGFloat, dy: CGFloat, handle: ResizeHandle, size: CGSize) -> CGFloat {
        let scale: CGFloat
        if handle.isCorner {
            scale = 1 + (dx * size.width + dy * size.height) / (size.width * size.width + size.height * size.height)
        } else if handle.xSign != 0 {
            scale = (size.width + dx) / size.width
        } else {
            scale = (size.height + dy) / size.height
        }
        return max(scale, minimumMM / min(size.width, size.height))
    }

    private static func value(_ mm: Double, _ rounds: Bool) -> Double {
        let clamped = max(minimumMM, mm)
        return rounds ? (clamped / stepMM).rounded() * stepMM : clamped
    }
}

/// Where "Align on Label" puts an element.
enum LabelAlignment: CaseIterable {
    case left, center, right, top, middle, bottom

    var title: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .top: "Top"
        case .middle: "Middle"
        case .bottom: "Bottom"
        }
    }

    var systemImage: String {
        switch self {
        case .left: "align.horizontal.left"
        case .center: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .middle: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }

    /// New top-left position for an element of `size` on a label of `label` (both mm).
    func position(for element: LabelElement, size: CGSize, label: CGSize) -> CGPoint {
        var x = element.x, y = element.y
        switch self {
        case .left: x = 0
        case .center: x = (label.width - size.width) / 2
        case .right: x = label.width - size.width
        case .top: y = 0
        case .middle: y = (label.height - size.height) / 2
        case .bottom: y = label.height - size.height
        }
        return CGPoint(x: max(0, (x * 10).rounded() / 10), y: max(0, (y * 10).rounded() / 10))
    }
}

/// Stacking order changes ("Arrange").
enum Arrangement: CaseIterable {
    case front, forward, backward, back

    var title: String {
        switch self {
        case .front: "Bring to Front"
        case .forward: "Bring Forward"
        case .backward: "Send Backward"
        case .back: "Send to Back"
        }
    }

    /// `elements` are stored back-to-front.
    func apply(to elements: inout [LabelElement], id: LabelElement.ID) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        let element = elements.remove(at: index)
        let target: Int = switch self {
        case .front: elements.count
        case .forward: min(index + 1, elements.count)
        case .backward: max(index - 1, 0)
        case .back: 0
        }
        elements.insert(element, at: target)
    }
}

enum ElementGeometry {
    @MainActor private static var cache: [LabelElement: CGSize] = [:]

    /// Rendered size of an element in mm (same view as the preview and print path). Cached per
    /// element value, so it's cheap to ask repeatedly (inspector, layers, warnings).
    @MainActor
    static func sizeMM(of element: LabelElement) -> CGSize {
        var key = element
        key.x = 0; key.y = 0; key.name = ""; key.isLocked = false   // position / name don't change the size
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: LabelElementView(element: key))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return .zero }
        let size = CGSize(width: Double(image.width) / dotsPerMM, height: Double(image.height) / dotsPerMM)
        if cache.count > 500 { cache.removeAll() }
        cache[key] = size
        return size
    }

    /// A fixed-height text box that cuts off lines (compared with the height the text would need).
    @MainActor
    static func hidesText(_ element: LabelElement) -> Bool {
        guard element.kind.isTextual, element.wrapsText, element.boxHeightMM > 0 else { return false }
        var free = element
        free.boxHeightMM = 0
        return sizeMM(of: free).height > sizeMM(of: element).height + 0.2
    }

    /// How far (mm) the element reaches past the label's edges; 0 when it's fully on the label.
    @MainActor
    static func overflowMM(of element: LabelElement, label: CGSize) -> Double {
        guard !element.isHidden else { return 0 }
        let size = sizeMM(of: element)
        let over = max(0, -element.x, -element.y, element.x + size.width - label.width, element.y + size.height - label.height)
        return over > 0.15 ? over : 0 // ignore sub-dot rounding
    }
}

extension LabelDocument {
    /// Elements that run off the label (id → overflow in mm).
    @MainActor
    var overflowingElements: [LabelElement.ID: Double] {
        let label = CGSize(width: widthMM, height: heightMM)
        var result: [LabelElement.ID: Double] = [:]
        for element in elements {
            let over = ElementGeometry.overflowMM(of: element, label: label)
            if over > 0 { result[element.id] = over }
        }
        return result
    }
}

/// Typed sizes from the inspector's W / H fields, and "fit on label" fixes.
enum ElementSizing {
    /// The element resized so its rendered width (or height) becomes `mm`, same rules as the handles.
    @MainActor
    static func setting(_ element: LabelElement, width mm: Double) -> LabelElement {
        let size = ElementGeometry.sizeMM(of: element)
        return ElementResize.resized(element, handle: .trailing, translationMM: CGSize(width: mm - size.width, height: 0), sizeMM: size)
    }

    @MainActor
    static func setting(_ element: LabelElement, height mm: Double) -> LabelElement {
        let size = ElementGeometry.sizeMM(of: element)
        return ElementResize.resized(element, handle: .bottom, translationMM: CGSize(width: 0, height: mm - size.height), sizeMM: size)
    }

    /// Scales the element down (never up) to fit inside the label minus `margin`, then moves it inside.
    @MainActor
    static func fittingOnLabel(_ element: LabelElement, label: CGSize, margin: Double = ElementDefaults.safeMarginMM) -> LabelElement {
        var result = element
        let size = ElementGeometry.sizeMM(of: element)
        let room = CGSize(width: label.width - 2 * margin, height: label.height - 2 * margin)
        if size.width > room.width || size.height > room.height {
            let scale = min(room.width / size.width, room.height / size.height)
            result = ElementResize.resized(element, handle: .bottomTrailing,
                                           translationMM: CGSize(width: size.width * (scale - 1), height: size.height * (scale - 1)),
                                           sizeMM: size, rounds: false)
        }
        let fitted = ElementGeometry.sizeMM(of: result)
        result.x = min(max(result.x, margin), max(margin, label.width - margin - fitted.width))
        result.y = min(max(result.y, margin), max(margin, label.height - margin - fitted.height))
        return result
    }

    /// Text that runs off the right edge: a text box from its left edge to the safe margin.
    static func textBox(_ element: LabelElement, label: CGSize, wraps: Bool) -> LabelElement {
        var result = element
        result.fitWidthMM = max(2, ((label.width - ElementDefaults.safeMarginMM - element.x) * 2).rounded(.down) / 2)
        result.wrapsText = wraps
        result.shrinksToFit = !wraps
        return result
    }
}

enum ElementDefaults {
    static let safeMarginMM = 1.0
}
