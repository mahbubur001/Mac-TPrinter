import AppKit
import SwiftUI

/// Label editor, docked so nothing covers the label:
/// top bar · tool rail | layers (optional) | canvas + floating element bar + align bar | properties panel.
struct EditorView: View {
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var printCenter: PrintCenter
    @Binding var selectedID: LabelElement.ID?
    @AppStorage("editorShowsInspector") private var showsInspector = true
    @AppStorage("editorShowsLayers") private var showsLayers = false
    @AppStorage("editorShowsMargin") private var showsMargin = true
    @AppStorage("editorSnaps") private var snaps = true
    @AppStorage("warnOverflow") private var warnOverflow = true
    @State private var zoom: CGFloat = 1
    @State private var liveStatus: String?
    @State private var errorMessage: String?
    @State private var confirmsOverflowPrint = false
    @State private var panelMode: LabelInspectorView.Mode = .element
    /// Multi-select: selected elements besides `selectedID` (the primary one the panel edits).
    @State private var alsoSelected: Set<LabelElement.ID> = []
    /// Set while the editor itself changes the primary selection, so the extras survive it.
    @State private var keepsExtras = false

    private var selectedIndex: Int? { session.document.elements.firstIndex { $0.id == selectedID } }

    /// Everything selected (primary + extras) that still exists.
    private var selection: Set<LabelElement.ID> {
        var ids = alsoSelected
        if let selectedID { ids.insert(selectedID) }
        let existing = Set(session.document.elements.map(\.id))
        return ids.intersection(existing)
    }

    private func select(_ ids: [LabelElement.ID]) {
        keepsExtras = true
        alsoSelected = Set(ids.dropLast())
        selectedID = ids.last
    }

    /// The selection as a set for the layers list. A newly added row becomes the primary element
    /// (the one the properties panel edits); otherwise the current primary stays if still selected.
    private var layerSelection: Binding<Set<LabelElement.ID>> {
        Binding {
            selection
        } set: { ids in
            let added = ids.subtracting(selection)
            let primary = added.count == 1 ? added.first : (selectedID.flatMap { ids.contains($0) ? $0 : nil }
                ?? session.document.elements.last { ids.contains($0.id) }?.id)
            let others = session.document.elements.map(\.id).filter { ids.contains($0) && $0 != primary }
            select(others + (primary.map { [$0] } ?? []))
        }
    }

    /// ⇧/⌘-click: add the element to the selection, or take it out.
    private func toggleSelection(_ id: LabelElement.ID) {
        var ids = selection
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        let ordered = session.document.elements.map(\.id).filter { ids.contains($0) && $0 != id } + (ids.contains(id) ? [id] : [])
        select(ordered)
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(zoom: $zoom, onPrint: requestPrint)
            Divider()
            HStack(spacing: 0) {
                EditorRail(selectedID: $selectedID, selection: selection, onSelect: select, showsLayers: $showsLayers, showsInspector: $showsInspector,
                           showsMargin: $showsMargin, snaps: $snaps,
                           onInsert: insert, onPrint: requestPrint, onPageSettings: showPageSettings)
                    .zIndex(1) // tips draw over the canvas
                Divider()
                if showsLayers {
                    LayersPanel(selection: layerSelection)
                        .frame(width: 230)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                canvasColumn
                if showsInspector {
                    Divider()
                    LabelInspectorView(document: $session.document, selectedID: $selectedID, mode: $panelMode) {
                        withAnimation(.easeOut(duration: 0.2)) { showsInspector = false }
                    }
                    .frame(width: 330)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showsLayers)
            .animation(.easeOut(duration: 0.2), value: showsInspector)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDeleteCommand(perform: deleteSelected)
        // Edit › Copy / Cut / Paste when no text field is being edited (text fields handle them first).
        .onCommand(#selector(NSText.copy(_:))) { session.copyElements(selection) }
        .onCommand(#selector(NSText.cut(_:))) {
            session.copyElements(selection)
            session.deleteElements(selection)
            select([])
        }
        .onCommand(#selector(NSText.paste(_:))) { select(session.pasteAllElements()) }
        .onCommand(#selector(NSResponder.selectAll(_:))) { select(session.document.elements.filter { !$0.isHidden }.map(\.id)) }
        .onChange(of: selectedID) { _, new in
            // A plain selection change (layers list, inspector …) drops the extras.
            if keepsExtras { keepsExtras = false } else { alsoSelected = [] }
            if let new { alsoSelected.remove(new) }
        }
        .noticeDialog("Print failed", icon: "printer.fill", tone: .danger, message: $errorMessage)
        .sheet(isPresented: $confirmsOverflowPrint) {
            ModernDialog(icon: "exclamationmark.triangle.fill", tone: .warning, title: "Some content runs off the label",
                         message: "The parts outside the label won't print. Use Shrink to Fit or Fit on Label to fix it.",
                         primary: .init("Print Anyway") { printLabel() },
                         cancelTitle: "Review") { selectedID = session.document.overflowingElements.keys.first }
        }
    }

    // MARK: Canvas column

    private var canvasColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                LabelPreviewView(document: session.document, selectedID: selectedID, onSelect: { id in select(id.map { [$0] } ?? []) },
                                 onMove: moveElement, onDropImage: insertImage, zoom: $zoom,
                                 showsMargin: showsMargin, snapsToGuides: snaps, onStatus: { liveStatus = $0 },
                                 alsoSelected: alsoSelected, onToggleSelect: toggleSelection,
                                 onMoveGroup: { ids, delta in session.moveElements(ids, by: delta) },
                                 onBoxSelect: select)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onKeyPress(characters: CharacterSet(charactersIn: "tbqisdn")) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        switch press.characters {
                        case "t": insert(.text)
                        case "b": insert(.barcode)
                        case "q": insert(.qrCode)
                        case "i": insert(.image)
                        case "s": insert(.shape)
                        case "d": insert(.date)
                        case "n": insert(.counter)
                        default: return .ignored
                        }
                        return .handled
                    }
                if selection.count > 1 {
                    MultiSelectionBar(selection: selection) { select([]) }
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let index = selectedIndex {
                    ElementQuickBar(element: $session.document.elements[index],
                                    label: CGSize(width: session.document.widthMM, height: session.document.heightMM)) {
                        panelMode = .element
                        withAnimation(.easeOut(duration: 0.2)) { showsInspector = true }
                    }
                    .id(selectedID)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: selectedID)
            Divider()
            EditorArrangeBar(selectedID: $selectedID, selection: selection, liveStatus: liveStatus)
        }
    }

    // MARK: Actions

    private func showPageSettings() {
        panelMode = .page
        withAnimation(.easeOut(duration: 0.2)) { showsInspector = true }
    }

    private func insert(_ kind: LabelElementKind) {
        if kind == .image {
            if let url = ImageImport.chooseFile() { insertImage(url) }
            return
        }
        let element = LabelElement.make(kind)
        session.perform("Add \(kind.title)") { $0.elements.append(element) }
        selectedID = element.id
    }

    private func insertImage(_ url: URL) {
        do {
            let element = try ImageImport.element(from: url, label: CGSize(width: session.document.widthMM, height: session.document.heightMM))
            session.perform("Add Image") { $0.elements.append(element) }
            selectedID = element.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveElement(_ id: LabelElement.ID, to position: CGPoint) {
        session.perform("Move") { document in
            guard let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
            document.elements[index].x = position.x
            document.elements[index].y = position.y
        }
    }

    private func deleteSelected() {
        session.deleteElements(selection)
        select([])
    }

    private func requestPrint() {
        if warnOverflow, !session.document.overflowingElements.isEmpty {
            confirmsOverflowPrint = true
        } else {
            printLabel()
        }
    }

    private func printLabel() {
        printCenter.printLabel(session.document, name: session.displayName) { error in
            session.advanceCounters(by: bluetooth.lastQueueDone)
            if let error, error != "stopped" { errorMessage = error }
        }
    }
}

// MARK: - Top bar

/// Back, the label's name centred (with * while unsaved), printer, undo / redo, zoom, save and print.
private struct EditorTopBar: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var printCenter: PrintCenter
    @Environment(\.undoManager) private var undoManager
    @Binding var zoom: CGFloat
    var onPrint: () -> Void

    private var title: String {
        let d = session.document
        return "\(session.displayName) (\(MeasureUnit.current.compactSize(d.widthMM, d.heightMM)))\(session.isDirty ? "*" : "")"
    }

    var body: some View {
        ZStack {
            // The empty space drags the window (no title bar).
            WindowDragArea()
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 420)
                .help(session.isDirty ? "Unsaved changes" : "Saved")
                .allowsHitTesting(false)
            HStack(spacing: 10) {
                Button { session.leaveEditor() } label: {
                    Image(systemName: "arrow.left").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 28)
                }
                .focusable(false)
                .hoverTip("Back to \(session.lastHomeTab.title)", edge: .top)
                Spacer()
                if let queue = bluetooth.queueProgress {
                    ProgressView(value: Double(queue.done), total: Double(queue.total)).frame(width: 70)
                    Button { bluetooth.stopQueue() } label: { Image(systemName: "stop.circle") }.help("Stop printing")
                }
                Menu { PrinterChooserMenu() } label: {
                    StatusPill(state: bluetooth.ledState, text: bluetooth.connection.isReady ? bluetooth.displayName : bluetooth.statusText)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Printer")
                Divider().frame(height: 18)
                iconButton("arrow.uturn.backward", tip: undoManager?.undoMenuItemTitle ?? "Undo", shortcut: "⌘Z") { undoManager?.undo() }
                    .disabled(!(undoManager?.canUndo ?? false))
                iconButton("arrow.uturn.forward", tip: undoManager?.redoMenuItemTitle ?? "Redo", shortcut: "⇧⌘Z") { undoManager?.redo() }
                    .disabled(!(undoManager?.canRedo ?? false))
                zoomControl
                iconButton("square.and.arrow.down", tip: "Save", shortcut: "⌘S") { session.save() }
                Button(action: onPrint) { Label("Print", systemImage: "printer.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!printCenter.canPrint)
                    .keyboardShortcut("p")
            }
            .padding(.leading, trafficLightInset)
            .padding(.trailing, 12)
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .frame(height: 48)
        .background(.bar)
    }

    private func iconButton(_ symbol: String, tip: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28) }
            .hoverTip(tip, shortcut: shortcut, edge: .top)
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 24, height: 24) }
                .disabled(zoom <= LabelPreviewView.zoomSteps.first!)
                .keyboardShortcut("-", modifiers: .command)
            Button { withAnimation(.easeOut(duration: 0.15)) { zoom = 1 } } label: {
                Group {
                    if zoom == 1 { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") } else { Text("\(Int(zoom * 100))%").monospacedDigit() }
                }
                .frame(minWidth: 40)
            }
            .keyboardShortcut("0", modifiers: .command)
            .hoverTip("Fit to window", shortcut: "⌘0", edge: .top)
            Button { step(1) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                .disabled(zoom >= LabelPreviewView.zoomSteps.last!)
                .keyboardShortcut("=", modifiers: .command)
        }
        .padding(.horizontal, 2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private func step(_ direction: Int) {
        let steps = LabelPreviewView.zoomSteps
        let index = steps.firstIndex(of: zoom) ?? steps.firstIndex(of: 1)!
        withAnimation(.easeOut(duration: 0.15)) { zoom = steps[min(max(index + direction, 0), steps.count - 1)] }
    }
}

// MARK: - Tool rail

/// Left rail: add, file and page tools on top; element tools and the properties toggle at the bottom.
private struct EditorRail: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var printCenter: PrintCenter
    @Binding var selectedID: LabelElement.ID?
    let selection: Set<LabelElement.ID>
    var onSelect: ([LabelElement.ID]) -> Void
    @Binding var showsLayers: Bool
    @Binding var showsInspector: Bool
    @Binding var showsMargin: Bool
    @Binding var snaps: Bool
    var onInsert: (LabelElementKind) -> Void
    var onPrint: () -> Void
    var onPageSettings: () -> Void

    private static let addable: [(LabelElementKind, String)] = [
        (.text, "T"), (.barcode, "B"), (.qrCode, "Q"), (.image, "I"), (.icon, ""), (.shape, "S"), (.date, "D"), (.counter, "N"),
    ]

    private var selected: LabelElement? { session.document.elements.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 4) {
            addMenu
            railDivider
            RailButton(symbol: "folder", tip: "Open Template…", shortcut: "⌘O") { session.openWithPanel() }
            RailButton(symbol: "square.and.arrow.down", tip: "Save", shortcut: "⌘S") { session.save() }
            RailButton(symbol: "square.and.pencil", tip: "Save As…", shortcut: "⇧⌘S") { session.saveAs() }
            RailButton(symbol: "printer.fill", tip: "Print", shortcut: "⌘P", tint: .red, isDisabled: !printCenter.canPrint, action: onPrint)
            railDivider
            RailButton(symbol: "slider.horizontal.3", tip: "Page and Media Settings", tint: .accentColor, action: onPageSettings)
            RailButton(symbol: "tablecells.badge.ellipsis", tip: "Batch Print from CSV", tint: .green) { session.showBatch() }
            RailButton(symbol: "grid", tip: showsMargin ? "Hide Safe-Margin Guide" : "Show Safe-Margin Guide", isOn: showsMargin) { showsMargin.toggle() }
            RailButton(symbol: "square.and.line.vertical.and.square", tip: snaps ? "Turn Snapping Off" : "Turn Snapping On", isOn: snaps) { snaps.toggle() }
            Spacer(minLength: 8)
            elementTools
            railDivider
            RailButton(symbol: "gearshape.fill", tip: showsInspector ? "Hide Properties" : "Show Properties", isOn: showsInspector, prominent: true) {
                withAnimation(.easeOut(duration: 0.2)) { showsInspector.toggle() }
            }
            .padding(.bottom, 4)
        }
        .padding(.vertical, 10)
        .focusEffectDisabled()
        .frame(width: 56)
        .background(.bar)
    }

    private var railDivider: some View { Divider().frame(width: 30).padding(.vertical, 5) }

    private var addMenu: some View {
        Menu {
            ForEach(Self.addable, id: \.0) { kind, key in
                Button { onInsert(kind) } label: {
                    Label(key.isEmpty ? kind.title : "\(kind.title)   \(key)", systemImage: kind.systemImage)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverTip("Add Element", shortcut: "T B Q I S D N")
    }

    @ViewBuilder
    private var elementTools: some View {
        let hasSelection = !selection.isEmpty
        let many = selection.count > 1
        RailButton(symbol: "plus.square.on.square", tip: many ? "Duplicate \(selection.count) Elements" : "Duplicate", shortcut: "⌘D", isDisabled: !hasSelection) {
            onSelect(session.duplicateElements(selection))
        }
        RailButton(symbol: "arrow.up", tip: "Bring Forward", isDisabled: !hasSelection) {
            if let id = selectedID { session.arrange(id, .forward) }
        }
        RailButton(symbol: "arrow.down", tip: "Send Backward", isDisabled: !hasSelection) {
            if let id = selectedID { session.arrange(id, .backward) }
        }
        RailButton(symbol: "square.3.layers.3d", tip: showsLayers ? "Hide Layers" : "Show Layers", isOn: showsLayers) {
            showsLayers.toggle()
        }
        let hidden = selected?.isHidden == true, locked = selected?.isLocked == true
        RailButton(symbol: hidden ? "eye.slash" : "eye", tip: hidden ? "Show" : "Hide (won't print)",
                   isOn: hidden, isDisabled: !hasSelection) {
            session.setFlag(\.isHidden, to: !hidden, for: selection, actionName: hidden ? "Show" : "Hide")
        }
        RailButton(symbol: locked ? "lock.fill" : "lock.open", tip: locked ? "Unlock" : "Lock Position and Size",
                   isOn: locked, isDisabled: !hasSelection) {
            session.setFlag(\.isLocked, to: !locked, for: selection, actionName: locked ? "Unlock" : "Lock")
        }
        RailButton(symbol: "trash", tip: many ? "Delete \(selection.count) Elements" : "Delete", shortcut: "⌫", tint: .red, isDisabled: !hasSelection) {
            session.deleteElements(selection)
            onSelect([])
        }
    }
}

/// One square rail icon with a hover tip. `isOn` shows a toggle's state; `prominent` is the filled
/// accent style (properties toggle).
private struct RailButton: View {
    let symbol: String
    let tip: String
    var shortcut: String?
    var tint: Color = .primary
    var isOn = false
    var isDisabled = false
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 38, height: 34)
                .background(background, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .onHover { hovering = $0 }
        .hoverTip(tip, shortcut: shortcut)
    }

    private var foreground: Color {
        if prominent { return isOn ? .white : .accentColor }
        return isOn ? .accentColor : (tint == .primary ? .secondary : tint)
    }

    private var background: Color {
        if prominent { return isOn ? .accentColor : Color.accentColor.opacity(0.14) }
        if isOn { return Color.accentColor.opacity(0.16) }
        return hovering && !isDisabled ? Color.primary.opacity(0.07) : .clear
    }
}

// MARK: - Align / arrange bar

/// Bottom bar: align on label, fit, rotate and stacking order for the selection, then status.
private struct EditorArrangeBar: View {
    @EnvironmentObject private var session: LabelSession
    @Binding var selectedID: LabelElement.ID?
    let selection: Set<LabelElement.ID>
    let liveStatus: String?

    private var selected: LabelElement? { session.document.elements.first { $0.id == selectedID } }
    private var many: Bool { selection.count > 1 }
    private var label: CGSize { CGSize(width: session.document.widthMM, height: session.document.heightMM) }

    var body: some View {
        HStack(spacing: 6) {
            section("ALIGN") {
                ForEach(LabelAlignment.allCases, id: \.self) { alignment in
                    barButton(alignment.systemImage, tip: many ? "Align \(alignment.title) Edges" : "Align \(alignment.title) on Label") {
                        if many { return session.alignElements(selection, alignment) }
                        guard let element = selected else { return }
                        session.align(element.id, alignment, elementSize: ElementGeometry.sizeMM(of: element))
                    }
                }
            }
            section("DIST") {
                barButton("distribute.horizontal.center", tip: "Distribute Horizontally (3+ selected)") {
                    session.distributeElements(selection, .horizontal)
                }
                barButton("distribute.vertical.center", tip: "Distribute Vertically (3+ selected)") {
                    session.distributeElements(selection, .vertical)
                }
            }
            .disabled(selection.count < 3)
            section("SIZE") {
                barButton("arrow.down.right.and.arrow.up.left", tip: "Fit on Label") {
                    guard let element = selected else { return }
                    session.updateElement(ElementSizing.fittingOnLabel(element, label: label), actionName: "Fit on Label")
                }
                barButton("rotate.right", tip: "Rotate 90°") {
                    guard var element = selected else { return }
                    element.rotation = (element.rotation + 90) % 360
                    session.updateElement(element, actionName: "Rotate")
                }
            }
            section("ARRANGE") {
                barButton("square.3.layers.3d.top.filled", tip: "Bring to Front") { if let id = selectedID { session.arrange(id, .front) } }
                barButton("square.3.layers.3d.bottom.filled", tip: "Send to Back") { if let id = selectedID { session.arrange(id, .back) } }
            }
            .disabled(selected == nil)
            Spacer(minLength: 8)
            status
        }
        .disabled(false)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.bar)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).kerning(0.6).fixedSize().padding(.trailing, 3)
            content()
        }
        .padding(.horizontal, 6)
        .disabled(selection.isEmpty)
        .overlay(alignment: .trailing) { Divider().frame(height: 16).offset(x: 6) }
    }

    private func barButton(_ symbol: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .hoverTip(tip, edge: .top)
    }

    @ViewBuilder
    private var status: some View {
        let overflowCount = session.document.overflowingElements.count
        if overflowCount > 0 {
            Button { selectedID = session.document.overflowingElements.keys.first } label: {
                Label("\(overflowCount) off the label", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Show the element that runs off the label")
        }
        Text(liveStatus ?? summary)
            .foregroundStyle(liveStatus == nil ? Color.secondary : Color.accentColor)
            .lineLimit(1)
            .font(.callout.monospacedDigit())
    }

    private var summary: String {
        if many { return "\(selection.count) selected  ·  ⇧-click to add or remove" }
        guard let element = selected else {
            let count = session.document.elements.count
            return count == 0 ? "Empty label: press + to add an element" : "\(count) element\(count == 1 ? "" : "s")"
        }
        let size = ElementGeometry.sizeMM(of: element)
        let unit = MeasureUnit.current
        return "x \(unit.number(element.x))  y \(unit.number(element.y))  ·  \(unit.size(size.width, size.height))"
    }
}

// MARK: - Layers panel

private struct LayersPanel: View {
    @EnvironmentObject private var session: LabelSession
    @Binding var selection: Set<LabelElement.ID>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if selection.count > 1 {
                    Text("\(selection.count) selected").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                } else {
                    Text("\(session.document.elements.count)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            LayersList(document: $session.document, selection: $selection)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Label").font(.caption.weight(.semibold))
                Text("\(MeasureUnit.current.size(session.document.widthMM, session.document.heightMM)), \(MeasureUnit.current.length(session.document.gapMM)) \(session.document.separation.title.lowercased())")
                    .font(.caption).foregroundStyle(.secondary)
                Text(session.document.mediaTitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Printer choices as menu items (editor toolbar).
struct PrinterChooserMenu: View {
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager

    var body: some View {
        ForEach(bluetooth.visibleClassicPrinters) { printer in
            Button {
                bluetooth.connectClassic(printer.id)
            } label: {
                if printer.id == bluetooth.connectedClassicAddress { Label(printer.name, systemImage: "checkmark") } else { Text(printer.name) }
            }
        }
        if bluetooth.visibleClassicPrinters.isEmpty { Text("No paired printer") }
        Divider()
        Button("Refresh Printers") { bluetooth.refreshClassicPrinters() }
        if bluetooth.connection.isReady { Button("Disconnect") { bluetooth.disconnect() } }
    }
}

extension View {
    /// Frosted floating panel (used by a few overlays).
    func floatingPanel() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }
}
