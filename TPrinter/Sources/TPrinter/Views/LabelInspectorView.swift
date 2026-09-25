import SwiftUI

/// The editor's properties panel: the selected element's settings ("Text Properties" …) or the
/// page & media / print settings, with a search box and category tabs over collapsible sections.
struct LabelInspectorView: View {
    enum Mode: String { case element, page }

    @Binding var document: LabelDocument
    @Binding var selectedID: LabelElement.ID?
    @Binding var mode: Mode
    var onClose: () -> Void
    @EnvironmentObject private var session: LabelSession
    @State private var query = ""
    @State private var category: InspectorSections.Category = .all
    @FocusState private var searchFocused: Bool

    private var selectedIndex: Int? { document.elements.firstIndex(where: { $0.id == selectedID }) }
    private var selectedKind: LabelElementKind? { selectedIndex.map { document.elements[$0].kind } }
    /// Nothing selected: the panel shows the page & media settings.
    private var showsElement: Bool { mode == .element && selectedIndex != nil }

    /// Sections this panel can show right now, and those left after search / category filtering.
    private var titles: [String] { InspectorSections.titles(for: showsElement ? selectedKind : nil) }
    private var filter: InspectorFilter { InspectorFilter(query: query, category: category) }
    private var categories: [(InspectorSections.Category, Int)] {
        let searched = InspectorFilter(query: query, category: .all)
        let visible = titles.filter(searched.shows)
        var result: [(InspectorSections.Category, Int)] = [(.all, visible.count)]
        for cat in InspectorSections.Category.allCases where cat != .all {
            let count = visible.filter { InspectorSections.info($0).category == cat }.count
            if count > 0 { result.append((cat, count)) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            categoryTabs
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if showsElement, let index = selectedIndex {
                        ElementPanel(element: $document.elements[index],
                                     label: CGSize(width: document.widthMM, height: document.heightMM),
                                     selectedID: $selectedID)
                            .id(selectedID)
                    } else {
                        if mode == .element { nothingSelected }
                        LabelPanel(document: $document)
                        PrintPanel(document: $document)
                    }
                    if titles.filter(filter.shows).isEmpty {
                        Text("No settings match “\(query)”.").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
                .padding(12)
                .environment(\.inspectorFilter, filter)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: selectedID) { _, id in if id != nil { mode = .element } }
        .onChange(of: mode) { _, _ in category = .all }
        .onChange(of: selectedKind) { _, _ in category = .all }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: showsElement ? (selectedKind?.systemImage ?? "square") : "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(showsElement ? "\(selectedKind?.title ?? "Element") Properties" : "Page & Media")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Picker("", selection: $mode) {
                Image(systemName: "square.on.square").tag(Mode.element).help("Element properties")
                Image(systemName: "doc.text").tag(Mode.page).help("Page, media and print settings")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.borderless)
                .help("Close the properties panel")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(showsElement ? "Search all settings… (font, size, align)" : "Search settings… (gap, copies, darkness)", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            } else {
                Text("⌘F").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? Color.accentColor : .clear, lineWidth: 1.5))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(categories, id: \.0) { cat, count in
                    let isOn = category == cat
                    Button { category = cat } label: {
                        HStack(spacing: 5) {
                            Image(systemName: cat.icon).font(.system(size: 10, weight: .semibold))
                            Text(cat.title).font(.system(size: 11, weight: .semibold))
                            Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(isOn ? Color.accentColor.opacity(0.8) : Color.secondary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(isOn ? Color.accentColor : .primary)
                        .background(isOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.never)
        .padding(.bottom, 8)
    }

    private var nothingSelected: some View {
        Label("Select an element on the label to edit it, or add one with + on the left.", systemImage: "cursorarrow.click.2")
            .font(.callout).foregroundStyle(.secondary)
            .padding(.bottom, 2)
    }
}

// MARK: - Shared building blocks

/// Rounded, collapsible section of the properties panel. Its category and search keywords come from
/// `InspectorSections`, so the panel's search box and category tabs can show just the matching ones.
struct InspectorGroup<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content
    @Environment(\.inspectorFilter) private var filter
    @AppStorage("inspectorCollapsed") private var collapsedList = ""

    private var info: InspectorSections.Info { InspectorSections.info(title) }
    private var isCollapsed: Bool { filter.query.isEmpty && collapsedList.split(separator: "|").contains(Substring(title)) }

    var body: some View {
        if filter.shows(title) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: info.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    trailing
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                if !isCollapsed {
                    content
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
        }
    }

    private func toggle() {
        var titles = collapsedList.split(separator: "|").map(String.init)
        if let index = titles.firstIndex(of: title) { titles.remove(at: index) } else { titles.append(title) }
        withAnimation(.easeOut(duration: 0.15)) { collapsedList = titles.joined(separator: "|") }
    }
}

/// Which panel sections exist, their category tab, icon and the settings they hold (for search).
enum InspectorSections {
    enum Category: String, CaseIterable, Identifiable {
        case all, data, typography, appearance, layout, element, page, printing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .data: "Data"
            case .typography: "Typography"
            case .appearance: "Appearance"
            case .layout: "Position"
            case .element: "Element"
            case .page: "Page"
            case .printing: "Printing"
            }
        }
        var icon: String {
            switch self {
            case .all: "square.grid.2x2"
            case .data: "cylinder.split.1x2"
            case .typography: "textformat"
            case .appearance: "paintpalette"
            case .layout: "arrow.up.and.down.and.arrow.left.and.right"
            case .element: "square.on.square"
            case .page: "doc"
            case .printing: "printer"
            }
        }
    }

    struct Info {
        let category: Category
        let icon: String
        let keywords: String
    }

    private static let table: [String: Info] = [
        "Content": Info(category: .data, icon: "text.cursor", keywords: "text value static link url wifi contact phone field column csv"),
        "Data": Info(category: .data, icon: "barcode", keywords: "barcode value type code 128 ean upc code 39 itf codabar"),
        "Date": Info(category: .data, icon: "calendar", keywords: "format pattern days today expiry best before"),
        "Counter": Info(category: .data, icon: "number", keywords: "next step digits prefix suffix reset serial number"),
        "Picture": Info(category: .data, icon: "photo", keywords: "file replace crop trim image"),
        "Icon": Info(category: .data, icon: "star", keywords: "symbol choose icon"),
        "Font": Info(category: .typography, icon: "textformat", keywords: "family size weight bold italic underline strikethrough case upper lower"),
        "Paragraph": Info(category: .typography, icon: "text.alignleft", keywords: "align alignment line letter spacing text box wrap shrink width"),
        "Effect": Info(category: .appearance, icon: "circle.lefthalf.filled", keywords: "white on black invert background outline box border color colour"),
        "Bars": Info(category: .appearance, icon: "barcode.viewfinder", keywords: "height bar width module quiet zone"),
        "Number": Info(category: .appearance, icon: "textformat.123", keywords: "show number text position above below size"),
        "Code": Info(category: .appearance, icon: "qrcode", keywords: "error correction size"),
        "Printing": Info(category: .appearance, icon: "circle.dotted", keywords: "photo line art darkness threshold invert dither"),
        "Style": Info(category: .appearance, icon: "paintbrush", keywords: "weight filled"),
        "Shape": Info(category: .appearance, icon: "square.on.circle", keywords: "rectangle rounded ellipse line width height length"),
        "Stroke": Info(category: .appearance, icon: "pencil.line", keywords: "filled line width corner radius dashed border"),
        "Position & size": Info(category: .layout, icon: "arrow.up.left.and.arrow.down.right", keywords: "x y width height size rotation rotate"),
        "Align on label": Info(category: .layout, icon: "align.horizontal.center", keywords: "align center left right top bottom middle front back forward backward arrange"),
        "Element": Info(category: .element, icon: "square.on.square", keywords: "lock hide duplicate delete copy paste style"),
        "Media": Info(category: .page, icon: "doc", keywords: "media label size width height gap black mark continuous roll paper category group"),
        "Arrangement": Info(category: .page, icon: "square.grid.3x2", keywords: "labels across columns rows spacing margin"),
        "Guides": Info(category: .page, icon: "ruler", keywords: "safe margin snap guides rulers"),
        "Print": Info(category: .printing, icon: "printer", keywords: "copies method image native tspl darkness speed density"),
        "Printer": Info(category: .printing, icon: "printer.dotmatrix", keywords: "test print alignment calibrate sensor"),
        "Before printing": Info(category: .printing, icon: "exclamationmark.triangle", keywords: "warn overflow off label"),
    ]

    static func info(_ title: String) -> Info { table[title] ?? Info(category: .element, icon: "square", keywords: "") }

    /// The sections shown for an element kind (nil = the page / print settings), in panel order.
    static func titles(for kind: LabelElementKind?) -> [String] {
        let common = ["Position & size", "Align on label", "Element"]
        guard let kind else { return ["Media", "Arrangement", "Guides", "Print", "Printer", "Before printing"] }
        let own: [String] = switch kind {
        case .text: ["Content", "Font", "Paragraph", "Effect"]
        case .date: ["Date", "Font", "Paragraph", "Effect"]
        case .counter: ["Counter", "Font", "Paragraph", "Effect"]
        case .barcode: ["Data", "Bars", "Number"]
        case .qrCode: ["Content", "Code"]
        case .image: ["Picture", "Printing"]
        case .icon: ["Style", "Icon"]
        case .shape: ["Shape", "Stroke"]
        }
        return own + common
    }
}

/// The properties panel's search text and category tab, read by every `InspectorGroup`.
struct InspectorFilter {
    var query = ""
    var category: InspectorSections.Category = .all

    func shows(_ title: String) -> Bool {
        let info = InspectorSections.info(title)
        guard category == .all || info.category == category else { return false }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return q.split(separator: " ").allSatisfy { word in
            title.localizedCaseInsensitiveContains(word) || info.keywords.localizedCaseInsensitiveContains(word)
        }
    }
}

private struct InspectorFilterKey: EnvironmentKey {
    static let defaultValue = InspectorFilter()
}

extension EnvironmentValues {
    var inspectorFilter: InspectorFilter {
        get { self[InspectorFilterKey.self] }
        set { self[InspectorFilterKey.self] = newValue }
    }
}

/// "X  12.5 mm" compact number field.
struct MMField: View {
    let label: String
    @Binding var value: Double
    var unit = "mm"
    var range: ClosedRange<Double> = -500...500

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .onSubmit { value = min(max(value, range.lowerBound), range.upperBound) }
            Text(unit).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Label on the left, control on the right.
struct InspectorRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 24)
    }
}

// MARK: - Element

private struct ElementPanel: View {
    @Binding var element: LabelElement
    let label: CGSize
    @Binding var selectedID: LabelElement.ID?
    @EnvironmentObject private var session: LabelSession

    var body: some View {
        header
        let overflow = ElementGeometry.overflowMM(of: element, label: label)
        if overflow > 0 { overflowCard(overflow) }
        switch element.kind {
        case .text: TextPanel(element: $element, label: label)
        case .barcode: BarcodePanel(element: $element)
        case .qrCode: QRPanel(element: $element)
        case .image: ImagePanel(element: $element, label: label)
        case .icon: IconPanel(element: $element)
        case .shape: ShapePanel(element: $element)
        case .date:
            DatePanel(element: $element)
            TextPanel(element: $element, label: label, showsContent: false)
        case .counter:
            CounterPanel(element: $element)
            TextPanel(element: $element, label: label, showsContent: false)
        }
        positionGroup
        arrangeGroup
        elementGroup
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: element.kind.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            TextField("Name", text: $element.name, prompt: Text(automaticName))
                .textFieldStyle(.plain)
                .font(.headline)
            Text(element.kind.title).font(.caption.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }

    private var automaticName: String {
        var unnamed = element
        unnamed.name = ""
        return unnamed.layerName
    }

    private func overflowCard(_ overflow: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Runs off the label by \(overflow.formatted(.number.precision(.fractionLength(1)))) mm", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.red)
            Text("The part outside the label won't print.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if element.kind.isTextual {
                    Button("Shrink to Fit") { element = ElementSizing.textBox(element, label: label, wraps: false) }
                        .buttonStyle(.borderedProminent)
                    Button("Wrap Lines") { element = ElementSizing.textBox(element, label: label, wraps: true) }
                } else {
                    Button("Fit on Label") { element = ElementSizing.fittingOnLabel(element, label: label) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.3)))
    }

    private var positionGroup: some View {
        let size = ElementGeometry.sizeMM(of: element)
        return InspectorGroup(title: "Position & size") {
            HStack(spacing: 7) {
                MMField(label: "X", value: $element.x)
                MMField(label: "Y", value: $element.y)
            }
            HStack(spacing: 7) {
                MMField(label: "W", value: Binding(get: { (size.width * 10).rounded() / 10 },
                                                   set: { element = ElementSizing.setting(element, width: max($0, 1)) }))
                MMField(label: "H", value: Binding(get: { (size.height * 10).rounded() / 10 },
                                                   set: { element = ElementSizing.setting(element, height: max($0, 1)) }))
            }
            Text(sizeHint).font(.caption).foregroundStyle(.tertiary)
            InspectorRow(title: "Rotation") {
                Picker("", selection: $element.rotation) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }

    private var sizeHint: String {
        switch element.kind {
        case .image, .icon, .qrCode: "Keeps its proportions."
        case .text, .date, .counter: "Handles set the text box, not the font: text wraps to the width, and a set height hides what doesn't fit."
        case .barcode: "Width changes in whole bar steps."
        case .shape: element.shapeKind == .line ? "Width sets the length." : "Width and height stretch freely."
        }
    }

    private var arrangeGroup: some View {
        InspectorGroup(title: "Align on label") {
            HStack(spacing: 4) {
                ForEach(LabelAlignment.allCases, id: \.self) { alignment in
                    Button { session.align(element.id, alignment, elementSize: ElementGeometry.sizeMM(of: element)) } label: {
                        Image(systemName: alignment.systemImage).frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .help("Align \(alignment.title.lowercased())")
                }
            }
            .buttonStyle(.bordered)
            HStack(spacing: 4) {
                Button { session.arrange(element.id, .front) } label: { Label("Front", systemImage: "square.3.layers.3d.top.filled").frame(maxWidth: .infinity) }
                Button { session.arrange(element.id, .forward) } label: { Image(systemName: "chevron.up").frame(width: 22) }.help("Bring forward")
                Button { session.arrange(element.id, .backward) } label: { Image(systemName: "chevron.down").frame(width: 22) }.help("Send backward")
                Button { session.arrange(element.id, .back) } label: { Label("Back", systemImage: "square.3.layers.3d.bottom.filled").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var elementGroup: some View {
        InspectorGroup(title: "Element") {
            Toggle("Lock position and size", isOn: $element.isLocked)
            Toggle("Hide (don't print)", isOn: $element.isHidden)
            HStack {
                Button { selectedID = session.duplicateElement(element.id) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                }
                .keyboardShortcut("d", modifiers: .command)
                Button(role: .destructive) {
                    let id = element.id
                    selectedID = nil
                    session.deleteElement(id)
                } label: { Label("Delete", systemImage: "trash").frame(maxWidth: .infinity) }
            }
            HStack {
                Button { session.copyStyle(element.id) } label: {
                    Label("Copy Style", systemImage: "paintbrush").frame(maxWidth: .infinity)
                }
                .help("Copy this element's look (font, size, effects) to paste onto others, in any label")
                Button { session.pasteStyle(onto: element.id) } label: {
                    Label("Paste Style", systemImage: "paintbrush.pointed.fill").frame(maxWidth: .infinity)
                }
                .disabled(!(ElementClipboard.style().map(element.acceptsStyle(of:)) ?? false))
            }
            Text("⌘C / ⌘V copy and paste the whole element, also into another template.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: Text

private struct TextPanel: View {
    @Binding var element: LabelElement
    let label: CGSize
    /// Date and counter elements build their own text, so they only use the styling groups.
    var showsContent = true

    private enum BoxMode: String, CaseIterable { case auto = "Auto", wrap = "Wrap", shrink = "Shrink" }

    private var boxMode: Binding<BoxMode> {
        Binding {
            element.wrapsText ? .wrap : element.shrinksToFit ? .shrink : .auto
        } set: { mode in
            if mode != .auto, !element.wrapsText, !element.shrinksToFit {
                element.fitWidthMM = max(2, ((label.width - ElementDefaults.safeMarginMM - element.x) * 2).rounded(.down) / 2)
            }
            element.wrapsText = mode == .wrap
            element.shrinksToFit = mode == .shrink
        }
    }

    var body: some View {
        if showsContent {
            InspectorGroup(title: "Content") {
                TextEditor(text: $element.content)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 3).padding(.vertical, 4)
                    .frame(height: CGFloat(min(max(element.content.components(separatedBy: .newlines).count, 2), 6)) * 17 + 10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                Text("Return starts a new line. Type {{column}} to fill it from a CSV row when batch printing.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        InspectorGroup(title: "Font") {
            InspectorRow(title: "Family") {
                FontSearchPicker(selection: $element.fontFamily)
            }
            HStack(spacing: 7) {
                MMField(label: "Size", value: $element.fontSizeMM, range: 1...40)
                Picker("", selection: Binding(get: { element.resolvedWeight }, set: { element.fontWeight = $0; element.bold = $0.isBold })) {
                    ForEach(TextWeight.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            HStack(spacing: 6) {
                styleToggle("bold", isOn: Binding(get: { element.resolvedWeight.isBold },
                                                   set: { element.fontWeight = $0 ? .bold : .regular; element.bold = $0 }), help: "Bold")
                styleToggle("italic", isOn: $element.italic, help: "Italic")
                styleToggle("underline", isOn: $element.underline, help: "Underline")
                styleToggle("strikethrough", isOn: $element.strikethrough, help: "Strikethrough")
                Spacer()
                Picker("", selection: $element.textCase) {
                    ForEach(TextCase.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Letter case")
            }
        }
        InspectorGroup(title: "Paragraph") {
            InspectorRow(title: "Align") {
                Picker("", selection: $element.textAlignment) {
                    Image(systemName: "text.alignleft").tag(TextAlign.leading)
                    Image(systemName: "text.aligncenter").tag(TextAlign.center)
                    Image(systemName: "text.alignright").tag(TextAlign.trailing)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 7) {
                MMField(label: "Line", value: $element.lineSpacingMM, range: -5...20)
                MMField(label: "Letter", value: $element.letterSpacingMM, range: -2...10)
            }
            InspectorRow(title: "Text box") {
                Picker("", selection: boxMode) {
                    ForEach(BoxMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if element.wrapsText {
                HStack(spacing: 7) {
                    MMField(label: "Width", value: $element.fitWidthMM, range: 2...300)
                    if element.boxHeightMM > 0 {
                        MMField(label: "Height", value: $element.boxHeightMM, range: 1...300)
                    } else {
                        Text("Height: auto").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                Toggle("Fixed height (hide lines that don't fit)", isOn: Binding {
                    element.boxHeightMM > 0
                } set: { on in
                    element.boxHeightMM = on ? max(1.5, (ElementGeometry.sizeMM(of: element).height * 10).rounded() / 10) : 0
                })
                .toggleStyle(.switch).controlSize(.small)
                if hiddenText {
                    Label("Some text is hidden: the box is too small.", systemImage: "eye.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if element.shrinksToFit {
                MMField(label: "Box width", value: $element.fitWidthMM, range: 2...300)
                if element.shrinksToFit {
                    let used = TextFit.fontSizeMM(for: element)
                    Text(used < element.fontSizeMM ? "Shrunk to \(used.formatted(.number.precision(.fractionLength(1)))) mm to fit." : "Fits at full size.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        InspectorGroup(title: "Effect") {
            Toggle("White on black", isOn: $element.invertsText)
            Toggle("Outline box", isOn: $element.outlined)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    /// A fixed-height box cuts off lines: compare with the height the text would need.
    private var hiddenText: Bool { ElementGeometry.hidesText(element) }

    private func styleToggle(_ symbol: String, isOn: Binding<Bool>, help: String) -> some View {
        Toggle(isOn: isOn) { Image(systemName: symbol).frame(width: 18) }
            .toggleStyle(.button)
            .help(help)
    }
}

// MARK: Barcode

private struct BarcodePanel: View {
    @Binding var element: LabelElement

    var body: some View {
        InspectorGroup(title: "Data") {
            TextField("Barcode value", text: $element.content)
                .textFieldStyle(.roundedBorder)
            InspectorRow(title: "Type") {
                Picker("", selection: $element.barcodeType) {
                    ForEach(BarcodeType.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 150)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            } else {
                Text(element.barcodeType.hint + " {{column}} fields work here too.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        InspectorGroup(title: "Bars") {
            HStack(spacing: 7) {
                MMField(label: "Height", value: $element.barcodeHeightMM, range: 2...80)
                MMField(label: "Bar", value: Binding(get: { Double(element.barcodeModuleDots) },
                                                     set: { element.barcodeModuleDots = min(max(Int($0.rounded()), 1), 6) }),
                        unit: "dot", range: 1...6)
            }
            Toggle("Quiet zone (blank margin for scanners)", isOn: $element.barcodeQuietZone)
        }
        .toggleStyle(.switch).controlSize(.small)
        InspectorGroup(title: "Number") {
            Toggle("Show number", isOn: $element.showsBarcodeText)
            if element.showsBarcodeText {
                InspectorRow(title: "Position") {
                    Picker("", selection: $element.barcodeNumberPosition) {
                        ForEach(BarcodeNumberPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                MMField(label: "Size", value: $element.barcodeNumberSizeMM, range: 1...10)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
    }
}

extension BarcodePanel {
    /// Why the value can't be encoded as the chosen type (nil when it's fine or still a {{field}}).
    var problem: String? {
        guard element.barcodeType != .code128, !element.content.contains("{{") else { return nil }
        do { _ = try BarcodeEncoder.encode(element.content, as: element.barcodeType); return nil }
        catch { return error.localizedDescription }
    }
}

// MARK: Shape, date, counter

private struct ShapePanel: View {
    @Binding var element: LabelElement

    var body: some View {
        InspectorGroup(title: "Shape") {
            Picker("", selection: $element.shapeKind) {
                ForEach(ShapeKind.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 7) {
                MMField(label: element.shapeKind == .line ? "Length" : "W", value: $element.shapeWidthMM, range: 1...300)
                if element.shapeKind != .line {
                    MMField(label: "H", value: $element.shapeHeightMM, range: 1...300)
                }
            }
        }
        InspectorGroup(title: "Stroke") {
            if element.shapeKind != .line {
                Toggle("Filled", isOn: $element.shapeFilled)
            }
            if !element.shapeFilled || element.shapeKind == .line {
                HStack(spacing: 7) {
                    MMField(label: "Line", value: $element.lineWidthMM, range: 0.125...10)
                    if element.shapeKind == .rounded {
                        MMField(label: "Corner", value: $element.cornerRadiusMM, range: 0...50)
                    }
                }
                Toggle("Dashed", isOn: $element.dashed)
                if element.lineWidthMM < 0.25 {
                    Text("Lines thinner than 0.25 mm (2 dots) print faintly.").font(.caption).foregroundStyle(.orange)
                }
            } else if element.shapeKind == .rounded {
                MMField(label: "Corner", value: $element.cornerRadiusMM, range: 0...50)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
    }
}

private struct DatePanel: View {
    @Binding var element: LabelElement

    static let presets: [(format: String, title: String)] = [
        ("dd MMM yyyy", "25 Sep 2026"), ("dd/MM/yyyy", "25/09/2026"), ("yyyy-MM-dd", "2026-09-25"),
        ("MMM d, yyyy", "Sep 25, 2026"), ("dd.MM.yy", "25.09.26"), ("EEE dd MMM", "Fri 25 Sep"),
        ("HH:mm", "14:30"), ("dd MMM yyyy HH:mm", "25 Sep 2026 14:30"),
    ]

    var body: some View {
        InspectorGroup(title: "Date") {
            Text(element.displayText).font(.title3.weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
            InspectorRow(title: "Format") {
                Picker("", selection: $element.dateFormat) {
                    ForEach(Self.presets, id: \.format) { preset in
                        Text(element.formattedDateSample(preset.format)).tag(preset.format)
                    }
                    if !Self.presets.contains(where: { $0.format == element.dateFormat }) {
                        Text("Custom").tag(element.dateFormat)
                    }
                }
                .labelsHidden().frame(maxWidth: 170)
            }
            InspectorRow(title: "Pattern") {
                TextField("dd MMM yyyy", text: $element.dateFormat).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            InspectorRow(title: "Days from today") {
                Stepper(value: $element.dateOffsetDays, in: -3650...3650) {
                    Text(element.dateOffsetDays == 0 ? "Today" : "\(element.dateOffsetDays > 0 ? "+" : "")\(element.dateOffsetDays)")
                        .monospacedDigit()
                }
            }
            Text("Printed with the date of the day you print. Use days from today for best-before or expiry dates.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private extension LabelElement {
    func formattedDateSample(_ format: String) -> String {
        var copy = self
        copy.dateFormat = format
        return copy.formattedDate(Date())
    }
}

private struct CounterPanel: View {
    @Binding var element: LabelElement

    var body: some View {
        InspectorGroup(title: "Counter") {
            Text(element.displayText).font(.title3.weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                MMField(label: "Next", value: intBinding(\.counterNext), unit: "", range: -999_999...99_999_999)
                MMField(label: "Step", value: intBinding(\.counterStep), unit: "", range: -1000...1000)
            }
            InspectorRow(title: "Digits") {
                Stepper(value: $element.counterDigits, in: 1...10) { Text("\(element.counterDigits)").monospacedDigit() }
            }
            HStack(spacing: 7) {
                TextField("Prefix", text: $element.counterPrefix).textFieldStyle(.roundedBorder)
                TextField("Suffix", text: $element.counterSuffix).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Each printed label takes the next number; it carries on after printing.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Reset") { element.counterNext = 1 }.controlSize(.small)
            }
        }
    }

    private func intBinding(_ key: WritableKeyPath<LabelElement, Int>) -> Binding<Double> {
        Binding(get: { Double(element[keyPath: key]) }, set: { element[keyPath: key] = Int($0.rounded()) })
    }
}

// MARK: QR

private struct QRPanel: View {
    @Binding var element: LabelElement
    @State private var kind: QRContent.Kind = .text
    @State private var fields = QRContent()

    var body: some View {
        InspectorGroup(title: "Content") {
            Picker("", selection: $kind) {
                ForEach(QRContent.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch kind {
            case .link:
                TextField("https://…", text: $element.content).textFieldStyle(.roundedBorder)
            case .text:
                TextField("Text", text: $element.content, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
            case .wifi:
                TextField("Network name", text: $fields.ssid).textFieldStyle(.roundedBorder)
                TextField("Password", text: $fields.password).textFieldStyle(.roundedBorder)
                Picker("Security", selection: $fields.security) {
                    Text("WPA/WPA2").tag("WPA"); Text("WEP").tag("WEP"); Text("None").tag("nopass")
                }
            case .contact:
                TextField("Name", text: $fields.name).textFieldStyle(.roundedBorder)
                TextField("Phone", text: $fields.phone).textFieldStyle(.roundedBorder)
                TextField("Email", text: $fields.email).textFieldStyle(.roundedBorder)
            case .phone:
                TextField("Phone number", text: $fields.phone).textFieldStyle(.roundedBorder)
            }
        }
        .onAppear { (kind, fields) = QRContent.parse(element.content) }
        .onChange(of: fields) { _, new in
            if let composed = new.compose(kind) { element.content = composed }
        }
        .onChange(of: kind) { _, new in
            if let composed = fields.compose(new) { element.content = composed }
        }
        InspectorGroup(title: "Code") {
            InspectorRow(title: "Error correction") {
                Picker("", selection: $element.qrCorrection) {
                    ForEach(["L", "M", "Q", "H"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Text("Higher levels survive scratches and smudges but need more space.").font(.caption).foregroundStyle(.tertiary)
            MMField(label: "Size", value: $element.qrSizeMM, range: 4...100)
        }
    }
}

/// Helpers that build QR payloads for common content (Wi-Fi, contact, phone).
struct QRContent: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case link, text, wifi, contact, phone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .link: "Link"
            case .text: "Text"
            case .wifi: "Wi-Fi"
            case .contact: "Contact"
            case .phone: "Phone"
            }
        }
    }

    var ssid = "", password = "", security = "WPA", name = "", phone = "", email = ""

    /// The payload for structured kinds; nil for link / text (edited directly).
    func compose(_ kind: Kind) -> String? {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;") }
        switch kind {
        case .wifi: return "WIFI:T:\(security);S:\(esc(ssid));P:\(esc(password));;"
        case .contact: return "MECARD:N:\(esc(name));TEL:\(esc(phone));EMAIL:\(esc(email));;"
        case .phone: return "tel:\(phone)"
        case .link, .text: return nil
        }
    }

    static func parse(_ content: String) -> (Kind, QRContent) {
        var fields = QRContent()
        func value(_ key: String) -> String {
            guard let range = content.range(of: key + ":") else { return "" }
            return String(content[range.upperBound...].prefix { $0 != ";" })
        }
        if content.hasPrefix("WIFI:") {
            fields.ssid = value("S"); fields.password = value("P"); fields.security = value("T").isEmpty ? "WPA" : value("T")
            return (.wifi, fields)
        }
        if content.hasPrefix("MECARD:") {
            fields.name = value("N"); fields.phone = value("TEL"); fields.email = value("EMAIL")
            return (.contact, fields)
        }
        if content.hasPrefix("tel:") { fields.phone = String(content.dropFirst(4)); return (.phone, fields) }
        if content.hasPrefix("http://") || content.hasPrefix("https://") { return (.link, fields) }
        return (.text, fields)
    }
}

// MARK: Image & icon

private struct ImagePanel: View {
    @Binding var element: LabelElement
    let label: CGSize
    @State private var isCropping = false

    var body: some View {
        InspectorGroup(title: "Picture") {
            InspectorRow(title: "File") { Text(element.content).lineLimit(1).truncationMode(.middle) }
            HStack(spacing: 6) {
                Button { replace() } label: { Label("Replace…", systemImage: "photo.badge.arrow.down").frame(maxWidth: .infinity) }
                Button { isCropping = true } label: { Label("Crop…", systemImage: "crop").frame(maxWidth: .infinity) }
                    .disabled(element.imageData == nil)
            }
            if element.cropRect != nil {
                HStack {
                    Text("Cropped to \(Int(element.cropWidth * 100))% × \(Int(element.cropHeight * 100))%").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Crop") { element.setCrop(nil) }.controlSize(.small)
                }
            }
            Toggle("Trim empty margins", isOn: $element.trimsImage)
        }
        .toggleStyle(.switch).controlSize(.small)
        InspectorGroup(title: "Printing") {
            Picker("", selection: $element.dithers) {
                Text("Photo").tag(true)
                Text("Line art").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            InspectorRow(title: "Darkness") {
                Slider(value: $element.imageThreshold, in: 0.2...0.95).frame(width: 150)
            }
            Toggle("Invert (white on black)", isOn: $element.invertsImage)
            if element.imageWidthMM * dotsPerMM < 100 {
                Label("Only \(Int(element.imageWidthMM * dotsPerMM)) printer dots wide: fine detail may not print. Make it wider or darker.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .sheet(isPresented: $isCropping) {
            if let data = element.imageData {
                ImageCropSheet(data: data, crop: element.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)) { element.setCrop($0) }
            }
        }
    }

    private func replace() {
        guard let url = ImageImport.chooseFile(), let replacement = try? ImageImport.element(from: url, label: label) else { return }
        element.imageData = replacement.imageData
        element.content = replacement.content
        element.dithers = replacement.dithers
        element.imageThreshold = replacement.imageThreshold
        element.imageWidthMM = replacement.imageWidthMM
        element.setCrop(nil)
    }
}

private struct IconPanel: View {
    @Binding var element: LabelElement

    var body: some View {
        InspectorGroup(title: "Style") {
            InspectorRow(title: "Weight") {
                Picker("", selection: $element.iconWeight) {
                    ForEach(IconWeight.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Toggle("Filled", isOn: $element.iconFilled)
            MMField(label: "Size", value: $element.iconSizeMM, range: 2...80)
        }
        .toggleStyle(.switch).controlSize(.small)
        InspectorGroup(title: "Icon") {
            IconPicker(symbol: $element.content)
        }
    }
}

// MARK: - Label tab

private struct LabelPanel: View {
    @Binding var document: LabelDocument
    @EnvironmentObject private var library: MediaLibrary
    @AppStorage("editorShowsMargin") private var showsMargin = true
    @AppStorage("editorSnaps") private var snaps = true

    var body: some View {
        InspectorGroup(title: "Media") {
            Picker("Media", selection: Binding(get: { document.mediaName }, set: { apply($0) })) {
                if library.media(named: document.mediaName) == nil { Text(document.mediaTitle).tag(document.mediaName) }
                ForEach(library.media) { Text($0.name).tag($0.name) }
            }
            HStack(spacing: 6) {
                Text("Category").foregroundStyle(.secondary)
                TextField("None", text: $document.mediaCategory, prompt: Text("None (Other)"))
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(library.categories, id: \.self) { name in Button(name) { document.mediaCategory = name } }
                    Divider()
                    Button("None (Other)") { document.mediaCategory = "" }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Pick a category")
            }
            HStack(spacing: 7) {
                MMField(label: "W", value: $document.widthMM, range: 5...120)
                MMField(label: "H", value: $document.heightMM, range: 5...300)
            }
            HStack(spacing: 7) {
                MMField(label: "Gap", value: $document.gapMM, range: 0...10)
                Picker("", selection: $document.separation) {
                    ForEach(MediaSeparation.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
        }
        InspectorGroup(title: "Arrangement") {
            HStack(spacing: 7) {
                MMField(label: "Rows", value: $document.arrangement.rows.asDouble, unit: "", range: 1...10)
                MMField(label: "Cols", value: $document.arrangement.columns.asDouble, unit: "", range: 1...6)
            }
            HStack(spacing: 7) {
                MMField(label: "Left", value: $document.arrangement.marginLeftMM, range: 0...20)
                MMField(label: "Right", value: $document.arrangement.marginRightMM, range: 0...20)
            }
            HStack(spacing: 7) {
                MMField(label: "Top", value: $document.arrangement.marginTopMM, range: 0...20)
                MMField(label: "Bottom", value: $document.arrangement.marginBottomMM, range: 0...20)
            }
            HStack(spacing: 7) {
                MMField(label: "H gap", value: $document.arrangement.spacingHorizontalMM, range: 0...20)
                MMField(label: "V gap", value: $document.arrangement.spacingVerticalMM, range: 0...20)
            }
            Text("Printing repeats the label in every cell.").font(.caption).foregroundStyle(.tertiary)
        }
        InspectorGroup(title: "Guides") {
            Toggle("Safe margin (1 mm)", isOn: $showsMargin)
            Toggle("Snap to edges and centres", isOn: $snaps)
            Text("Hold ⌥ while dragging to move freely.").font(.caption).foregroundStyle(.tertiary)
        }
        .toggleStyle(.switch).controlSize(.small)
    }

    private func apply(_ name: String) {
        guard let media = library.media(named: name) else { return }
        document.mediaName = media.name
        document.mediaCategory = media.category
        document.widthMM = media.widthMM
        document.heightMM = media.heightMM
        document.gapMM = media.gapMM
        document.separation = media.separation
        document.density = media.defaultDarkness
        document.speed = media.defaultSpeed
    }
}

// MARK: - Print tab

private struct PrintPanel: View {
    @Binding var document: LabelDocument
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @AppStorage("warnOverflow") private var warnOverflow = true
    @State private var confirmsCalibration = false

    var body: some View {
        InspectorGroup(title: "Print") {
            MMField(label: "Copies", value: $document.copies.asDouble, unit: "", range: 1...999)
            InspectorRow(title: "Method") {
                Picker("", selection: $document.printMethod) {
                    ForEach(PrintMethod.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 180)
            }
            InspectorRow(title: "Darkness") {
                HStack {
                    Slider(value: $document.density.asDouble, in: 0...15, step: 1).frame(width: 120)
                    Text("\(document.density)").monospacedDigit().frame(width: 20)
                }
            }
            InspectorRow(title: "Speed") {
                Picker("", selection: $document.speed) {
                    ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Toggle("Rotate 180°", isOn: $document.flipped)
        }
        .toggleStyle(.switch).controlSize(.small)
        InspectorGroup(title: "Printer") {
            HStack {
                Text(bluetooth.displayName).fontWeight(.medium)
                Spacer()
                StatusPill(state: bluetooth.ledState, text: bluetooth.statusText)
            }
            HStack {
                Button("Test Print") { bluetooth.send(LabelPrintService.testJob()) }
                Button("Alignment Test") { bluetooth.send(LabelPrintService.alignmentJob(for: document)) }
            }
            .disabled(!bluetooth.connection.isReady)
            Button("Calibrate Label Sensor…") { confirmsCalibration = true }
                .disabled(!bluetooth.connection.isReady)
        }
        .controlSize(.small)
        InspectorGroup(title: "Before printing") {
            Toggle("Warn when content runs off the label", isOn: $warnOverflow)
        }
        .toggleStyle(.switch).controlSize(.small)
        .calibrationDialog(isPresented: $confirmsCalibration, document: document,
                           printerReady: bluetooth.connection.isReady) { bluetooth.send($0) }
    }
}

// MARK: - Icon picker

private struct IconPicker: View {
    @Binding var symbol: String
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search, or type any SF Symbol name", text: $query)
                .textFieldStyle(.roundedBorder)
            if query.isEmpty {
                ForEach(IconCatalog.groups) { group in
                    Text(group.name).font(.caption).foregroundStyle(.secondary)
                    grid(group.symbols)
                }
            } else {
                let results = IconCatalog.search(query)
                if results.isEmpty {
                    Text("No icon named “\(query)”. Symbol names look like “leaf” or “arrow.up”.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    grid(results)
                }
            }
        }
    }

    private func grid(_ symbols: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(symbols, id: \.self) { name in
                Button {
                    symbol = name
                } label: {
                    Image(systemName: name)
                        .font(.system(size: 16))
                        .frame(width: 34, height: 34)
                        .background(name == symbol ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if name == symbol {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
            }
        }
    }
}
