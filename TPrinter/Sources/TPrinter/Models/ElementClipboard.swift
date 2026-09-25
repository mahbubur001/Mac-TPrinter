import AppKit
import Foundation

/// Copy / paste of label elements and of an element's style, through the system pasteboard, so it
/// works within a label, across templates and after reopening the app.
enum ElementClipboard {
    static let elementsType = NSPasteboard.PasteboardType("net.restobox.tprinter.elements")
    static let styleType = NSPasteboard.PasteboardType("net.restobox.tprinter.element-style")

    // MARK: Elements

    /// Puts the element on the pasteboard (plus its text, for pasting into other apps).
    static func copy(_ elements: [LabelElement], to pasteboard: NSPasteboard = .general) {
        guard !elements.isEmpty, let data = try? JSONEncoder().encode(elements) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: elementsType)
        let text = elements.map(\.displayText).filter { !$0.isEmpty }.joined(separator: "\n")
        if !text.isEmpty { pasteboard.setString(text, forType: .string) }
    }

    static func elements(from pasteboard: NSPasteboard = .general) -> [LabelElement]? {
        guard let data = pasteboard.data(forType: elementsType),
              let elements = try? JSONDecoder().decode([LabelElement].self, from: data), !elements.isEmpty else { return nil }
        return elements
    }

    static func hasElements(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: [elementsType]) != nil
    }

    /// Copies ready to add to `document`: new ids, nudged 1 mm when they'd land exactly on an
    /// existing element (pasting into the same label), and kept on the label.
    static func pasteable(_ elements: [LabelElement], into document: LabelDocument) -> [LabelElement] {
        let occupied = Set(document.elements.map { PositionKey(x: $0.x, y: $0.y, kind: $0.kind) })
        let overlaps = elements.contains { occupied.contains(PositionKey(x: $0.x, y: $0.y, kind: $0.kind)) }
        return elements.map { element in
            var copy = element
            copy.id = UUID()
            copy.isLocked = false
            if overlaps { copy.x += 1; copy.y += 1 }
            copy.x = min(max(copy.x, 0), max(document.widthMM - 2, 0))
            copy.y = min(max(copy.y, 0), max(document.heightMM - 2, 0))
            return copy
        }
    }

    private struct PositionKey: Hashable {
        let x: Int, y: Int, kind: LabelElementKind
        init(x: Double, y: Double, kind: LabelElementKind) {
            self.x = Int((x * 10).rounded()); self.y = Int((y * 10).rounded()); self.kind = kind
        }
    }

    // MARK: Style

    static func copyStyle(of element: LabelElement, to pasteboard: NSPasteboard = .general) {
        guard let data = try? JSONEncoder().encode(element) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: styleType)
    }

    static func style(from pasteboard: NSPasteboard = .general) -> LabelElement? {
        pasteboard.data(forType: styleType).flatMap { try? JSONDecoder().decode(LabelElement.self, from: $0) }
    }
}

extension LabelElement {
    /// Whether `source`'s style can be pasted onto this element: same kind, or text-like to text-like.
    func acceptsStyle(of source: LabelElement) -> Bool {
        source.kind == kind || (source.kind.isTextual && kind.isTextual)
    }

    /// This element with `source`'s look (font, sizes, effects, rotation …) but its own content,
    /// position, name, picture and counter value.
    func applyingStyle(of source: LabelElement) -> LabelElement {
        guard acceptsStyle(of: source) else { return self }
        if source.kind != kind { return applyingTextStyle(of: source) }
        var result = source
        result.id = id
        result.kind = kind
        result.name = name
        result.content = content
        result.x = x
        result.y = y
        result.isLocked = isLocked
        result.isHidden = isHidden
        result.imageData = imageData
        result.cropX = cropX; result.cropY = cropY; result.cropWidth = cropWidth; result.cropHeight = cropHeight
        result.counterNext = counterNext
        return result
    }

    private func applyingTextStyle(of source: LabelElement) -> LabelElement {
        var result = self
        result.fontFamily = source.fontFamily
        result.fontSizeMM = source.fontSizeMM
        result.bold = source.bold
        result.fontWeight = source.fontWeight
        result.italic = source.italic
        result.underline = source.underline
        result.strikethrough = source.strikethrough
        result.textCase = source.textCase
        result.textAlignment = source.textAlignment
        result.lineSpacingMM = source.lineSpacingMM
        result.letterSpacingMM = source.letterSpacingMM
        result.wrapsText = source.wrapsText
        result.shrinksToFit = source.shrinksToFit
        result.fitWidthMM = source.fitWidthMM
        result.invertsText = source.invertsText
        result.outlined = source.outlined
        result.rotation = source.rotation
        return result
    }
}
