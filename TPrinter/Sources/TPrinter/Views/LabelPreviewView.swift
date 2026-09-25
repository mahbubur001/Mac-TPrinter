import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The canvas: the label shown on its roll — the liner strip with the previous and next die-cut
/// labels ghosted above and below, gaps to scale. Elements can be selected, dragged and nudged.
struct LabelPreviewView: View {
    let document: LabelDocument
    let selectedID: LabelElement.ID?
    var onSelect: (LabelElement.ID?) -> Void
    /// Called once when a drag ends (or per arrow key), with the new top-left position in mm.
    var onMove: (LabelElement.ID, CGPoint) -> Void
    /// Image files dropped on the canvas.
    var onDropImage: (URL) -> Void = { _ in }
    /// Zoom relative to "fit" (1 = fit). Owned by the editor toolbar.
    @Binding var zoom: CGFloat
    var showsMargin = true
    var snapsToGuides = true
    /// Live text for the status strip while dragging / resizing (nil when idle).
    var onStatus: (String?) -> Void = { _ in }
    /// Multi-select: the other selected elements (besides `selectedID`), ⇧/⌘-click to add or remove,
    /// dragging / nudging moves them together, and a drag on empty label space selects by box.
    var alsoSelected: Set<LabelElement.ID> = []
    var onToggleSelect: (LabelElement.ID) -> Void = { _ in }
    var onMoveGroup: (Set<LabelElement.ID>, CGSize) -> Void = { _, _ in }
    var onBoxSelect: ([LabelElement.ID]) -> Void = { _ in }

    @EnvironmentObject private var session: LabelSession
    @State private var drag: ActiveDrag?
    @State private var resize: ActiveResize?
    @State private var editing: InlineEdit?
    @FocusState private var editorFocused: Bool
    @State private var elementSizes: [LabelElement.ID: CGSize] = [:]
    /// Snap guides shown while dragging, in mm (vertical lines at x, horizontal at y).
    @State private var guidesX: [Double] = []
    @State private var guidesY: [Double] = []
    @State private var isDropTarget = false
    /// Box selection in progress, in printer dots.
    @State private var box: CGRect?
    /// Arrow keys only act while the canvas has focus, so they never fight with text fields.
    @FocusState private var isFocused: Bool

    private struct ActiveDrag {
        let id: LabelElement.ID
        let start: CGPoint    // mm, where it was when the drag began
        var position: CGPoint // mm
        var delta: CGSize { CGSize(width: position.x - start.x, height: position.y - start.y) }
    }

    private var selection: Set<LabelElement.ID> {
        var ids = alsoSelected
        if let selectedID { ids.insert(selectedID) }
        return ids
    }

    /// The elements a drag of `id` moves: the whole selection when `id` is part of it.
    private func moving(_ id: LabelElement.ID) -> Set<LabelElement.ID> {
        selection.count > 1 && selection.contains(id) ? selection : [id]
    }

    /// Double-click editing of an element's content, right on the canvas.
    private struct InlineEdit {
        let id: LabelElement.ID
        var text: String
    }

    private struct ActiveResize {
        let startSize: CGSize // mm, when the drag began
        var element: LabelElement
    }

    /// On-screen size of a resize handle, in points (independent of zoom).
    private static let handlePoints: CGFloat = 9

    private static let space = "labelCanvas"
    static let zoomSteps: [CGFloat] = [0.5, 0.75, 1, 1.5, 2, 3, 4]
    /// Safe margin guide, mm from each edge.
    static let safeMarginMM = 1.0
    /// How close (mm) an edge must come to a guide to snap to it.
    private static let snapDistanceMM = 0.6

    /// The document as it should look right now, including an in-progress drag.
    private var displayed: LabelDocument {
        var copy = document
        if let resize, let index = copy.elements.firstIndex(where: { $0.id == resize.element.id }) {
            copy.elements[index] = resize.element
        }
        if let drag {
            let group = moving(drag.id)
            for index in copy.elements.indices where group.contains(copy.elements[index].id) {
                if copy.elements[index].id == drag.id {
                    copy.elements[index].x = drag.position.x
                    copy.elements[index].y = drag.position.y
                } else if !copy.elements[index].isLocked {
                    copy.elements[index].x = max(0, copy.elements[index].x + drag.delta.width)
                    copy.elements[index].y = max(0, copy.elements[index].y + drag.delta.height)
                }
            }
        }
        return copy
    }

    var body: some View {
        GeometryReader { proxy in
            let width = CGFloat(document.widthDots)
            let height = CGFloat(document.heightDots)
            // Fit the whole strip — label + 2 mm liner each side, gaps and neighbour slivers — with
            // breathing room, so the roll is centred and never clipped.
            let stripWidth = width + 4 * dotsPerMM
            let stripHeight = height * 1.32 + 2 * max(document.gapMM, 0.5) * dotsPerMM
            let fit = max(min((proxy.size.width - 96) / stripWidth, (proxy.size.height - 120) / stripHeight, 6), 0.1)
            let scale = fit * zoom

            ScrollView([.horizontal, .vertical]) {
                roll(scale: scale)
                    .padding(32)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .scrollIndicators(zoom > 1 ? .automatic : .never)
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
                images.forEach(onDropImage)
                return !images.isEmpty
            } isTargeted: { isDropTarget = $0 }
        }
    }

    // MARK: - Roll

    private func roll(scale: CGFloat) -> some View {
        let labelWidth = CGFloat(document.widthDots) * scale
        let labelHeight = CGFloat(document.heightDots) * scale
        let gap = max(document.gapMM * dotsPerMM * scale, 2)
        let margin = 2 * dotsPerMM * scale
        let corner = Theme.labelCornerMM * dotsPerMM * scale
        // Just a sliver of the neighbours: enough to read "roll", not enough to compete with the label.
        let ghostHeight = min(labelHeight * 0.16, 36)

        return VStack(spacing: gap) {
            ghostLabel(width: labelWidth, height: ghostHeight, corner: corner, fadesUp: true)
            activeLabel(scale: scale, corner: corner)
            ghostLabel(width: labelWidth, height: ghostHeight, corner: corner, fadesUp: false)
        }
        .padding(.horizontal, margin)
        .background(Theme.liner)
        // Millimetre rulers printed on the liner, along the label's top and left edges.
        .overlay(alignment: .topLeading) {
            LinerRulers(widthMM: document.widthMM, heightMM: document.heightMM, pointsPerMM: dotsPerMM * scale,
                        origin: CGPoint(x: margin, y: ghostHeight + gap), gap: gap, margin: margin)
                .allowsHitTesting(false)
        }
        // Straight, clean ends: fading into the dark desk looked muddy.
        .clipShape(Rectangle())
    }

    private func ghostLabel(width: CGFloat, height: CGFloat, corner: CGFloat, fadesUp: Bool) -> some View {
        UnevenRoundedRectangle(cornerRadii: fadesUp
            ? .init(bottomLeading: corner, bottomTrailing: corner)
            : .init(topLeading: corner, topTrailing: corner))
            .fill(Theme.paper.opacity(0.7))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }

    private func activeLabel(scale: CGFloat, corner: CGFloat) -> some View {
        let width = CGFloat(document.widthDots)
        let height = CGFloat(document.heightDots)
        return ZStack(alignment: .topLeading) {
            LabelRenderView(document: displayed, paper: Theme.paper)
            // Empty label space: drag to select every element the box touches.
            Color.clear
                .contentShape(Rectangle())
                .gesture(boxGesture)
            if showsMargin {
                let inset = Self.safeMarginMM * dotsPerMM
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1 / scale, dash: [4 / scale, 3 / scale]))
                    .frame(width: width - 2 * inset, height: height - 2 * inset)
                    .offset(x: inset, y: inset)
                    .allowsHitTesting(false)
            }
            selectionOverlay(scale: scale)
            guides(scale: scale, width: width, height: height)
            if let box {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.1))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1 / scale, dash: [4 / scale, 2 / scale])))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        // Gesture translations are measured here, before scaling, so they are in printer dots.
        .coordinateSpace(name: Self.space)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: width * scale, height: height * scale, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay {
            RoundedRectangle(cornerRadius: corner).strokeBorder(Theme.linerEdge, lineWidth: 0.5)
        }
        // The editor lives outside the scaled content so it's a normal, crisp text field.
        .overlay(alignment: .topLeading) { inlineEditor(scale: scale) }
        .overlay {
            if document.elements.isEmpty { emptyHint }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(nil) }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { nudge($0) }
        .accessibilityLabel("Label, \(document.elements.count) elements")
    }

    private var emptyHint: some View {
        Text("Add text, a barcode, a QR code, an image or an icon from the toolbar. You can also drop an image here.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(12)
            .allowsHitTesting(false)
    }

    // MARK: - Guides

    private func guides(scale: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(guidesX, id: \.self) { x in
                Rectangle().fill(Color.pink).frame(width: 1 / scale, height: height).offset(x: x * dotsPerMM)
            }
            ForEach(guidesY, id: \.self) { y in
                Rectangle().fill(Color.pink).frame(width: width, height: 1 / scale).offset(y: y * dotsPerMM)
            }
        }
        .allowsHitTesting(false)
    }

    /// Nudges a dragged position onto the label's edges / centre and other elements' edges / centres
    /// when within `snapDistanceMM`, and records the guides to draw.
    /// Pointer travel (points) before pressing on an element becomes a move.
    static let dragThreshold: CGFloat = 5

    private func snapped(_ position: CGPoint, size: CGSize, id: LabelElement.ID) -> CGPoint {
        guard snapsToGuides, !NSEvent.modifierFlags.contains(.option) else {
            guidesX = []; guidesY = []
            return position
        }
        var xs: [Double] = [0, document.widthMM / 2, document.widthMM]
        var ys: [Double] = [0, document.heightMM / 2, document.heightMM]
        for other in document.elements where other.id != id && !other.isHidden {
            let s = sizeMM(of: other.id)
            xs += [other.x, other.x + s.width / 2, other.x + s.width]
            ys += [other.y, other.y + s.height / 2, other.y + s.height]
        }
        func snap(_ start: Double, _ length: Double, to lines: [Double]) -> (Double, Double?) {
            let edges = [start, start + length / 2, start + length]
            var best: (delta: Double, line: Double)?
            for (i, edge) in edges.enumerated() {
                for line in lines where abs(edge - line) < Self.snapDistanceMM {
                    let delta = line - edge
                    if best == nil || abs(delta) < abs(best!.delta) { best = (delta, line) }
                    _ = i
                }
            }
            guard let best else { return (start, nil) }
            return (start + best.delta, best.line)
        }
        let (x, gx) = snap(position.x, size.width, to: xs)
        let (y, gy) = snap(position.y, size.height, to: ys)
        guidesX = gx.map { [$0] } ?? []
        guidesY = gy.map { [$0] } ?? []
        return CGPoint(x: x, y: y)
    }

    // MARK: - Selection, drag, nudge

    @ViewBuilder
    private func selectionOverlay(scale: CGFloat) -> some View {
        let overflowing = displayed.overflowingElements
        return ForEach(displayed.elements.filter { !$0.isHidden }) { element in
            let isSelected = selection.contains(element.id) || element.id == drag?.id || element.id == resize?.element.id
            LabelElementView(element: element)
                .opacity(0)
                .onGeometryChange(for: CGSize.self, of: \.size) { elementSizes[element.id] = $0 }
                .contentShape(Rectangle())
                .overlay {
                    if overflowing[element.id] != nil {
                        // Runs off the label: the part outside won't print.
                        Rectangle().stroke(Color.red, lineWidth: 2 / scale).padding(-2 / scale).allowsHitTesting(false)
                    } else if isSelected {
                        Rectangle()
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2 / scale, dash: [6 / scale, 3 / scale]))
                            .padding(-2 / scale)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Fixed-height text box cutting off lines: a badge on the canvas only (never printed).
                    if ElementGeometry.hidesText(element) {
                        HiddenTextBadge(scale: scale)
                            .offset(x: 7 / scale, y: 7 / scale)
                            .help("Some text is hidden: make the box taller, or turn off Fixed height")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if element.isLocked, isSelected {
                        Image(systemName: "lock.fill").font(.system(size: 10 / scale)).foregroundStyle(Color.accentColor)
                            .padding(3 / scale).background(.white, in: Circle()).offset(x: 8 / scale, y: -8 / scale)
                            .allowsHitTesting(false)
                    }
                }
                .contextMenu { ElementContextMenu(element: element, session: session, select: onSelect) }
                .onHover { inside in
                    guard drag == nil, resize == nil else { return } // an active gesture owns the cursor
                    (inside && !element.isLocked ? NSCursor.openHand : NSCursor.arrow).set()
                }
                // Double-click edits the content in place; declared first so it wins over the single click.
                .onTapGesture(count: 2) { beginEditing(element) }
                .onTapGesture {
                    let flags = NSEvent.modifierFlags
                    if flags.contains(.shift) || flags.contains(.command) {
                        onToggleSelect(element.id)
                        isFocused = true
                    } else {
                        select(element.id)
                    }
                }
                .gesture(dragGesture(for: element), including: element.isLocked ? .none : .all)
                .overlay {
                    if isSelected, selection.count <= 1, drag == nil, !element.isLocked, editing?.id != element.id {
                        resizeHandles(for: element, scale: scale)
                    }
                }
                .offset(x: element.x * dotsPerMM, y: element.y * dotsPerMM)
        }
    }

    // MARK: - Resize

    /// Eight handles. Each one's hover and drag area is only the handle itself, so dragging anywhere
    /// else on the selected element still moves it.
    private func resizeHandles(for element: LabelElement, scale: CGFloat) -> some View {
        let side = Self.handlePoints / scale
        let inset = 2 / scale
        return ZStack {
            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                Rectangle()
                    .fill(.white)
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5 / scale))
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard drag == nil, resize == nil else { return }
                        resizeCursor(for: handle, inside: inside)
                    }
                    .highPriorityGesture(resizeGesture(for: element, handle: handle))
                    .accessibilityLabel("Resize")
                    // Centre the handle on its edge / corner of the selection outline.
                    .offset(x: handle.xSign * (side / 2 + inset), y: handle.ySign * (side / 2 + inset))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handle.alignment)
            }
        }
    }

    private func resizeGesture(for element: LabelElement, handle: ResizeHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let original = document.elements.first(where: { $0.id == element.id }) else { return }
                let start = resize?.startSize ?? sizeMM(of: element.id)
                let translation = CGSize(width: value.translation.width / dotsPerMM, height: value.translation.height / dotsPerMM)
                let updated = ElementResize.resized(original, handle: handle, translationMM: translation, sizeMM: start,
                                                    rounds: !NSEvent.modifierFlags.contains(.option))
                resize = ActiveResize(startSize: start, element: updated)
                let size = ElementGeometry.sizeMM(of: updated)
                onStatus(String(format: "%.1f × %.1f mm   Hold ⌥ to resize freely", size.width, size.height))
            }
            .onEnded { _ in
                if let resize, resize.element != document.elements.first(where: { $0.id == resize.element.id }) {
                    session.updateElement(resize.element, actionName: "Resize")
                }
                resize = nil
                onStatus(nil)
                NSCursor.arrow.set()
            }
    }

    private func resizeCursor(for handle: ResizeHandle, inside: Bool) {
        guard inside else { return NSCursor.arrow.set() }
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch handle {
            case .topLeading: .topLeft
            case .top: .top
            case .topTrailing: .topRight
            case .trailing: .right
            case .bottomTrailing: .bottomRight
            case .bottom: .bottom
            case .bottomLeading: .bottomLeft
            case .leading: .left
            }
            NSCursor.frameResize(position: position, directions: .all).set()
        } else {
            (handle.isCorner ? NSCursor.crosshair : handle.xSign != 0 ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        }
    }

    // MARK: - Inline editing

    private func beginEditing(_ element: LabelElement) {
        guard [.text, .barcode, .qrCode].contains(element.kind) else { return }
        select(element.id)
        editing = InlineEdit(id: element.id, text: element.content)
        editorFocused = true
    }

    private func commitEditing() {
        guard let edit = editing else { return }
        editing = nil
        guard var element = document.elements.first(where: { $0.id == edit.id }), element.content != edit.text else { return }
        element.content = edit.text
        session.updateElement(element, actionName: element.kind == .text ? "Edit Text" : "Edit \(element.kind.title)")
    }

    @ViewBuilder
    private func inlineEditor(scale: CGFloat) -> some View {
        if let edit = editing, let element = document.elements.first(where: { $0.id == edit.id }) {
            if element.kind == .text {
                multilineEditor(edit: edit, element: element, scale: scale)
            } else {
                TextField("Value", text: Binding { editing?.text ?? "" } set: { editing?.text = $0 })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(minWidth: max(sizeMM(of: element.id).width * dotsPerMM * scale, 120), alignment: .leading)
                    .fixedSize()
                    .modifier(InlineEditorChrome())
                    .focused($editorFocused)
                    .onSubmit(commitEditing)
                    .onExitCommand { editing = nil } // Esc: cancel
                    .onChange(of: editorFocused) { _, focused in if !focused { commitEditing() } }
                    .offset(x: element.x * dotsPerMM * scale - 4, y: element.y * dotsPerMM * scale - 2)
            }
        }
    }

    /// Text: Return adds a line, ⌘Return or clicking elsewhere finishes, Esc cancels.
    private func multilineEditor(edit: InlineEdit, element: LabelElement, scale: CGFloat) -> some View {
        let fontSize = max(TextFit.fontSizeMM(for: element) * dotsPerMM * scale, 11)
        let nsFont = TextFit.nsFont(for: element, sizeDots: fontSize)
        let lines = edit.text.components(separatedBy: .newlines)
        let widest = lines.map { NSAttributedString(string: $0, attributes: [.font: nsFont]).size().width }.max() ?? 0
        let lineHeight = ceil(nsFont.ascender - nsFont.descender + nsFont.leading)
        let width = max(widest + 24, sizeMM(of: element.id).width * dotsPerMM * scale, 120)
        return VStack(alignment: .trailing, spacing: 3) {
            TextEditor(text: Binding { editing?.text ?? "" } set: { editing?.text = $0 })
                .font(TextFit.font(for: element, sizeDots: fontSize))
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .foregroundStyle(.black)
                .frame(width: width, height: CGFloat(lines.count) * lineHeight + 8)
                .padding(.horizontal, 2)
                .modifier(InlineEditorChrome())
                .focused($editorFocused)
                .onExitCommand { editing = nil } // Esc: cancel
                .onChange(of: editorFocused) { _, focused in if !focused { commitEditing() } }
            Button("Done  ⌘↩", action: commitEditing)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
        }
        .offset(x: element.x * dotsPerMM * scale - 4, y: element.y * dotsPerMM * scale - 4)
    }

    private func select(_ id: LabelElement.ID?) {
        onSelect(id)
        isFocused = true
    }

    private func sizeMM(of id: LabelElement.ID) -> CGSize {
        let dots = elementSizes[id] ?? .zero
        return CGSize(width: dots.width / dotsPerMM, height: dots.height / dotsPerMM)
    }

    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard drag == nil, let id = selectedID, let element = document.elements.first(where: { $0.id == id }), !element.isLocked else { return .ignored }
        let (dx, dy): (Double, Double) = switch press.key {
        case .leftArrow: (-1, 0)
        case .rightArrow: (1, 0)
        case .upArrow: (0, -1)
        default: (0, 1)
        }
        let step = ElementDragMath.nudgeStepMM(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
        if selection.count > 1 {
            onMoveGroup(selection, CGSize(width: dx * step, height: dy * step))
            return .handled
        }
        let position = ElementDragMath.nudged(CGPoint(x: element.x, y: element.y), dx: dx, dy: dy, stepMM: step,
                                              sizeMM: sizeMM(of: id),
                                              labelMM: CGSize(width: document.widthMM, height: document.heightMM))
        onMove(id, position)
        return .handled
    }

    private var boxGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                box = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                             width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                isFocused = true
            }
            .onEnded { _ in
                guard let box else { return }
                self.box = nil
                let area = CGRect(x: box.minX / dotsPerMM, y: box.minY / dotsPerMM, width: box.width / dotsPerMM, height: box.height / dotsPerMM)
                let hits = document.elements.filter { element in
                    !element.isHidden && area.intersects(CGRect(origin: CGPoint(x: element.x, y: element.y), size: sizeMM(of: element.id)))
                }
                onBoxSelect(hits.map(\.id))
            }
    }

    private func dragGesture(for element: LabelElement) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                // A click with a little wobble isn't a move: without this, snapping would shift the
                // element to a nearby guide and mark the label as edited.
                if drag == nil, hypot(value.translation.width, value.translation.height) < Self.dragThreshold {
                    if !selection.contains(element.id) { select(element.id) }
                    return
                }
                if drag == nil {
                    if !selection.contains(element.id) { select(element.id) }
                    NSCursor.closedHand.set()
                }
                // Always measure from the committed position so the element tracks the pointer exactly.
                guard let original = document.elements.first(where: { $0.id == element.id }) else { return }
                let size = sizeMM(of: element.id)
                let position = snapped(ElementDragMath.position(
                    start: CGPoint(x: original.x, y: original.y),
                    translationDots: value.translation,
                    sizeMM: size,
                    labelMM: CGSize(width: document.widthMM, height: document.heightMM),
                    snaps: !NSEvent.modifierFlags.contains(.option)
                ), size: size, id: element.id)
                drag = ActiveDrag(id: element.id, start: CGPoint(x: original.x, y: original.y), position: position)
                onStatus(String(format: "x %.1f mm, y %.1f mm   Hold ⌥ to move freely", position.x, position.y))
            }
            .onEnded { _ in
                if let drag, abs(drag.delta.width) > 0.001 || abs(drag.delta.height) > 0.001 {
                    let group = moving(drag.id)
                    if group.count > 1 { onMoveGroup(group, drag.delta) } else { onMove(drag.id, drag.position) }
                }
                drag = nil
                guidesX = []; guidesY = []
                onStatus(nil)
                NSCursor.openHand.set()
            }
    }
}

/// Millimetre ticks printed on the liner along the label's top and left edges (numbers every 5 mm).
private struct LinerRulers: View {
    let widthMM: Double
    let heightMM: Double
    let pointsPerMM: CGFloat
    let origin: CGPoint
    let gap: CGFloat
    let margin: CGFloat

    var body: some View {
        Canvas { context, _ in
            let ink = GraphicsContext.Shading.color(Color.black.opacity(0.35))
            let showNumbers = pointsPerMM > 6 && gap > 12
            // Top edge: ticks point up from the label into the gap.
            for mm in 0...Int(widthMM) {
                let x = origin.x + CGFloat(mm) * pointsPerMM
                let major = mm % 5 == 0
                let length = min(gap * (major ? 0.55 : 0.28), major ? 10 : 5)
                context.fill(Path(CGRect(x: x - 0.5, y: origin.y - length, width: 1, height: length)), with: ink)
                if major, showNumbers, mm > 0 {
                    context.draw(Text("\(mm)").font(.system(size: 9, weight: .medium)).foregroundColor(.black.opacity(0.45)),
                                 at: CGPoint(x: x + 2, y: origin.y - length - 1), anchor: .bottomLeading)
                }
            }
            // Left edge: ticks point left from the label into the margin.
            for mm in 0...Int(heightMM) {
                let y = origin.y + CGFloat(mm) * pointsPerMM
                let major = mm % 5 == 0
                let length = min(margin * (major ? 0.55 : 0.28), major ? 10 : 5)
                context.fill(Path(CGRect(x: origin.x - length, y: y - 0.5, width: length, height: 1)), with: ink)
                if major, showNumbers, mm > 0 {
                    context.draw(Text("\(mm)").font(.system(size: 9, weight: .medium)).foregroundColor(.black.opacity(0.45)),
                                 at: CGPoint(x: origin.x - length - 2, y: y), anchor: .trailing)
                }
            }
        }
    }
}

/// White card with the accent outline that marks on-canvas editing.
private struct InlineEditorChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.white, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            .environment(\.colorScheme, .light)
    }
}

/// Orange "text cut off" marker drawn at a constant on-screen size, whatever the zoom.
private struct HiddenTextBadge: View {
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 2 / scale) {
            Image(systemName: "eye.slash.fill")
            Text("more")
        }
        .font(.system(size: 9 / scale, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5 / scale)
        .padding(.vertical, 2 / scale)
        .background(Color.orange, in: Capsule())
        .overlay(Capsule().strokeBorder(.white, lineWidth: 1 / scale))
        .shadow(color: .black.opacity(0.25), radius: 2 / scale, y: 1 / scale)
        .fixedSize()
        .accessibilityLabel("Some text is hidden")
    }
}
