import SwiftUI

/// Settings › Media: the media library grouped by category on the left, the selected media on the
/// right (a to-scale drawing, size presets, separation, print defaults) with a pinned save bar.
struct MediaSettings: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @State private var category: String?
    @State private var query = ""
    @State private var editing: Media?
    @State private var isNew = false
    @State private var confirmsDelete = false

    private var shown: [Media] {
        library.media(inCategory: category).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
                || $0.sizeText.localizedCaseInsensitiveContains(query)
        }
    }

    /// Shown media grouped by category, in library order.
    private var groups: [(name: String, media: [Media])] {
        var order: [String] = [], byName: [String: [Media]] = [:]
        for media in shown {
            let key = media.category.isEmpty ? "Other" : media.category
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(media)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }

    private var saved: Media? { editing.flatMap { item in library.media.first { $0.id == item.id } } }
    private var isDirty: Bool { isNew || (editing != nil && editing != saved) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            libraryColumn
                .frame(width: 290)
            if editing != nil {
                MediaEditor(media: Binding($editing)!, isNew: isNew, categories: library.categories, isDirty: isDirty,
                            isInUse: editing?.name == session.document.mediaName && !isNew) { item in
                    library.save(item)
                    editing = item
                    isNew = false
                } onDelete: {
                    confirmsDelete = true
                } onRevert: {
                    if isNew { editing = library.media.first; isNew = false } else { editing = saved }
                } onDuplicate: {
                    guard var copy = editing else { return }
                    copy.id = UUID()
                    copy.name = uniqueName("\(copy.name) copy")
                    editing = copy
                    isNew = true
                } onNewLabel: {
                    guard let media = editing else { return }
                    var arrangement = LabelArrangement()
                    arrangement.columns = max(media.labelsAcross, 1)
                    arrangement.spacingHorizontalMM = media.labelsAcross > 1 ? 2 : 0
                    session.newDocument(media: media, arrangement: arrangement)
                } onAlignmentTest: {
                    guard let media = editing else { return }
                    bluetooth.send(LabelPrintService.alignmentJob(for: LabelDocument(media: media)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            if session.requestsNewMedia { startNew(); session.requestsNewMedia = false }
            else if editing == nil, let first = library.media.first { select(first) }
        }
        .onChange(of: session.requestsNewMedia) { _, requested in
            if requested { startNew(); session.requestsNewMedia = false }
        }
        .sheet(isPresented: $confirmsDelete) {
            ModernDialog(icon: "trash.fill", tone: .danger, title: "Delete “\(editing?.name ?? "")”?",
                         message: "Templates made for it keep their size.",
                         primary: .init("Delete Media", role: .destructive) {
                             if let id = editing?.id { library.delete(id) }
                             editing = library.media.first
                             isNew = false
                         })
        }
    }

    // MARK: Library

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Library").font(.headline)
                Text("\(library.media.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { startNew() } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name or size", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            FlowLayout(spacing: 6) {
                chip("All", count: library.media.count, color: nil, isOn: category == nil) { category = nil }
                ForEach(library.categories, id: \.self) { name in
                    chip(name, count: library.media(inCategory: name).count, color: CategoryStyle(name).color, isOn: category == name) {
                        category = category == name ? nil : name
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle().fill(CategoryStyle(group.name).color).frame(width: 7, height: 7)
                                Text(group.name.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.5)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.bottom, 2)
                            ForEach(group.media) { mediaRow($0) }
                        }
                    }
                    if shown.isEmpty {
                        Text("No media match.").foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func chip(_ title: String, count: Int, color: Color?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 6, height: 6) }
                Text(title)
                Text("\(count)").foregroundStyle(isOn ? Color.accentColor.opacity(0.8) : Color.secondary)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.accentColor : .primary)
            .background(isOn ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? .clear : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func mediaRow(_ media: Media) -> some View {
        let isOn = editing?.id == media.id && !isNew
        let inUse = media.name == session.document.mediaName
        return Button { select(media) } label: {
            HStack(spacing: 10) {
                MediaThumbnail(media: media)
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.name).fontWeight(.semibold).lineLimit(1)
                    Text(media.detailText).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 4)
                if inUse {
                    Label("In use", systemImage: "circle.fill")
                        .labelStyle(InUseLabelStyle())
                }
            }
            .padding(8)
            .background(isOn ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 1.5))
            .shadow(color: .black.opacity(isOn ? 0.06 : 0), radius: 3, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ media: Media) { editing = media; isNew = false }

    private func startNew() {
        editing = Media(name: "", category: category ?? library.categories.first ?? "General", widthMM: 40, heightMM: 25)
        isNew = true
    }

    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while library.media(named: name) != nil { name = "\(base) \(n)"; n += 1 }
        return name
    }
}

private struct InUseLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Theme.ledReady)
    }
}

/// A media's label shape, to scale, on its liner (library rows).
struct MediaThumbnail: View {
    let media: Media
    var box = CGSize(width: 44, height: 36)

    var body: some View {
        let factor = min((box.width - 10) / max(media.widthMM, 1), (box.height - 8) / max(media.heightMM, 1))
        RoundedRectangle(cornerRadius: 7)
            .fill(Theme.liner)
            .frame(width: box.width, height: box.height)
            .overlay {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Theme.paper)
                    .frame(width: max(media.widthMM * factor, 5), height: max(media.heightMM * factor, 4))
                    .shadow(color: .black.opacity(0.15), radius: 0.5)
            }
    }
}

// MARK: - Editor

/// Create / edit one media. Used by Settings › Media and the new-label flow (where only `onSave` is set).
struct MediaEditor: View {
    @Binding var media: Media
    let isNew: Bool
    let categories: [String]
    var isDirty = false
    var isInUse = false
    var onSave: (Media) -> Void
    var onDelete: (() -> Void)? = nil
    var onRevert: (() -> Void)? = nil
    var onDuplicate: (() -> Void)? = nil
    var onNewLabel: (() -> Void)? = nil
    var onAlignmentTest: (() -> Void)? = nil
    @State private var addingCategory = false
    @State private var newCategory = ""

    private var unit: MeasureUnit { MeasureUnit.current }

    private var canSave: Bool {
        !media.name.trimmingCharacters(in: .whitespaces).isEmpty && media.widthMM > 0 && media.heightMM > 0
    }

    /// Common sizes (mm): label sizes, then shipping sizes in inches.
    private static let presets: [(w: Double, h: Double, title: String?)] = [
        (30, 15, nil), (40, 30, nil), (50, 30, nil), (60, 40, nil), (50.8, 76.2, "2 × 3 in"), (76.2, 76.2, "3 × 3 in"), (101.6, 152.4, "4 × 6 in"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            identityCard.frame(maxWidth: .infinity)
                            sizeCard.frame(maxWidth: .infinity)
                        }
                        VStack(spacing: 14) { identityCard; sizeCard }
                    }
                    separationCard
                    printingCard
                }
                .padding(.bottom, 12)
            }
            footer
        }
    }

    // MARK: Hero

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) { drawing.frame(width: 320); heroInfo }
            VStack(alignment: .leading, spacing: 14) { drawing; heroInfo }
        }
        .padding(16)
        .modifier(MediaCard())
    }

    private var drawing: some View {
        MediaDimensionView(media: media, unit: unit)
            .frame(height: 230)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }

    private var heroInfo: some View {
        let style = CategoryStyle(media.category.isEmpty ? "Other" : media.category)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(media.category.isEmpty ? "Other" : media.category)
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(style.color, in: RoundedRectangle(cornerRadius: 5))
                if isInUse { Label("Loaded in the editor", systemImage: "circle.fill").labelStyle(InUseLabelStyle()) }
                if isNew { Text("NEW").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.accentColor) }
            }
            Text(media.name.isEmpty ? "Untitled media" : media.name)
                .font(.system(size: 21, weight: .bold))
                .lineLimit(2)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    fact("Label", unit.size(media.widthMM, media.heightMM))
                    fact("Separation", media.separation == .continuous ? "Continuous"
                         : "\(unit.length(media.gapMM)) \(media.separation == .gap ? "gap" : "mark")")
                }
                GridRow {
                    fact("Per row", "\(media.labelsAcross) label\(media.labelsAcross == 1 ? "" : "s")")
                    fact("Print", "Darkness \(media.defaultDarkness) · speed \(media.defaultSpeed)")
                }
            }
            if !isNew, onNewLabel != nil || onAlignmentTest != nil || onDuplicate != nil {
                HStack(spacing: 8) {
                    if let onNewLabel { Button(action: onNewLabel) { Label("New Label", systemImage: "plus.square") } }
                    if let onAlignmentTest { Button(action: onAlignmentTest) { Label("Alignment Test", systemImage: "viewfinder") } }
                    if let onDuplicate { Button(action: onDuplicate) { Label("Duplicate", systemImage: "plus.square.on.square") } }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.uppercased()).font(.system(size: 9.5, weight: .bold)).kerning(0.4).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13.5, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Cards

    private var identityCard: some View {
        card("Name & category", icon: "pencil") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("", text: $media.name, prompt: Text("e.g. Product 40 × 25"))
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Category").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(allCategories, id: \.self) { name in
                        let isOn = media.category.caseInsensitiveCompare(name) == .orderedSame
                        Button { media.category = name } label: {
                            Text(name)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .foregroundStyle(isOn ? .white : .primary)
                                .background(isOn ? CategoryStyle(name).color : Color.primary.opacity(0.06), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if addingCategory {
                        TextField("New category", text: $newCategory)
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                            .onSubmit {
                                let clean = newCategory.trimmingCharacters(in: .whitespaces)
                                if !clean.isEmpty { media.category = clean }
                                addingCategory = false; newCategory = ""
                            }
                    } else {
                        Button { addingCategory = true } label: {
                            Label("New", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var allCategories: [String] {
        var seen = Set<String>()
        return (categories + [media.category]).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private var sizeCard: some View {
        card("Label size", icon: "arrow.up.left.and.arrow.down.right") {
            ValueStepper(title: "Width", value: $media.widthMM, range: 5...120, step: 1)
            ValueStepper(title: "Height", value: $media.heightMM, range: 5...300, step: 1)
            HStack {
                Text("Common sizes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { let width = media.widthMM; media.widthMM = media.heightMM; media.heightMM = width } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Swap width and height (for rolls that feed the other way)")
            }
            FlowLayout(spacing: 6) {
                ForEach(Self.presets, id: \.w) { preset in
                    let isOn = abs(media.widthMM - preset.w) < 0.05 && abs(media.heightMM - preset.h) < 0.05
                    Button {
                        media.widthMM = preset.w
                        media.heightMM = preset.h
                    } label: {
                        Text(preset.title ?? unit.size(preset.w, preset.h))
                            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .foregroundStyle(isOn ? Color.accentColor : .secondary)
                            .background(isOn ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? .clear : Color.primary.opacity(0.15),
                                                                                   style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var separationCard: some View {
        card("How labels are separated", icon: "line.3.horizontal") {
            HStack(spacing: 10) {
                ForEach(MediaSeparation.allCases) { separation in
                    SeparationTile(separation: separation, isOn: media.separation == separation) { media.separation = separation }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                ValueStepper(title: media.separation == .blackMark ? "Mark height" : "Gap", value: $media.gapMM, range: 0...10, step: 0.5)
                    .disabled(media.separation == .continuous)
                    .opacity(media.separation == .continuous ? 0.4 : 1)
                ValueStepper(title: "Labels across", value: $media.labelsAcross.asDouble, range: 1...4, step: 1, unit: nil)
            }
        }
    }

    private var printingCard: some View {
        card("Printing defaults", icon: "circle.lefthalf.filled", note: "New labels made for this media start with these.") {
            HStack {
                Text("Material")
                Spacer()
                Picker("", selection: $media.material) {
                    ForEach(MediaMaterial.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Darkness")
                    Spacer()
                    Text("\(media.defaultDarkness) of 15").fontWeight(.semibold).monospacedDigit()
                }
                Slider(value: $media.defaultDarkness.asDouble, in: 0...15, step: 1)
                HStack(spacing: 3) {
                    ForEach(1...15, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level <= media.defaultDarkness ? Color.primary.opacity(0.15 + Double(level) * 0.045) : Color.primary.opacity(0.07))
                            .frame(height: 10)
                    }
                }
            }
            HStack {
                Text("Speed")
                Spacer()
                Picker("", selection: $media.defaultSpeed) {
                    ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("in/s").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(_ title: String, icon: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                Text(title).font(.system(size: 13, weight: .semibold))
                if let note { Text("· \(note)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MediaCard())
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !isNew, let onDelete {
                Button("Delete…", role: .destructive, action: onDelete).foregroundStyle(.red)
            }
            Spacer()
            if isDirty && !isNew {
                HStack(spacing: 6) {
                    Circle().fill(Theme.ledBusy).frame(width: 7, height: 7)
                    Text("Unsaved changes").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let onRevert, isDirty {
                Button(isNew ? "Cancel" : "Revert", action: onRevert)
            }
            Button(isNew ? "Add Media" : "Save Changes") { onSave(media) }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || (!isDirty && !isNew))
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct MediaCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Gap / black mark / continuous, each as a small picture of the liner.
private struct SeparationTile: View {
    let separation: MediaSeparation
    let isOn: Bool
    var action: () -> Void

    private var detail: String {
        switch separation {
        case .gap: "Die-cut labels with space between"
        case .blackMark: "Printed mark on the back of the liner"
        case .continuous: "One long strip, receipt style"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Canvas { context, size in
                    let liner = CGRect(x: size.width / 2 - 17, y: 0, width: 34, height: size.height)
                    context.fill(Path(liner), with: .color(Theme.liner))
                    let paper = GraphicsContext.Shading.color(Theme.paper)
                    if separation == .continuous {
                        context.fill(Path(liner.insetBy(dx: 3, dy: 0)), with: paper)
                        var cut = Path(); cut.move(to: CGPoint(x: liner.minX + 3, y: size.height / 2)); cut.addLine(to: CGPoint(x: liner.maxX - 3, y: size.height / 2))
                        context.stroke(cut, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    } else {
                        let top = CGRect(x: liner.minX + 3, y: 2, width: 28, height: size.height / 2 - 5)
                        let bottom = CGRect(x: liner.minX + 3, y: size.height / 2 + 3, width: 28, height: size.height / 2 - 5)
                        context.fill(Path(roundedRect: top, cornerRadius: 2), with: paper)
                        context.fill(Path(roundedRect: bottom, cornerRadius: 2), with: paper)
                        if separation == .blackMark {
                            context.fill(Path(CGRect(x: liner.maxX - 4, y: size.height / 2 - 4, width: 4, height: 8)), with: .color(.black))
                        }
                    }
                }
                .frame(width: 60, height: 40)
                Text(separation.title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 118)
            .background(isOn ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isOn ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isOn ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The media drawn to scale on its liner, with dimension lines for width, height and gap / mark.
struct MediaDimensionView: View {
    let media: Media
    let unit: MeasureUnit

    var body: some View {
        Canvas { context, size in
            let across = Double(max(media.labelsAcross, 1))
            let gapMM = media.separation == .continuous ? 0 : media.gapMM
            let rowMM = media.widthMM * across + (across - 1) * 2
            // Fixed room for the measurements: gap label on the left, height label on the right.
            let left: Double = 92, right: Double = 74
            let k = min((size.width - left - right - 20) / rowMM, (size.height - 56) / (media.heightMM * 1.8 + gapMM * 2))
            let labelW = media.widthMM * k, labelH = media.heightMM * k
            let gap = media.separation == .continuous ? 0 : max(gapMM * k, 3)
            let linerW = rowMM * k + 20
            let x0 = left + (size.width - left - right - linerW) / 2, top = (size.height - 14) / 2 - labelH / 2
            context.fill(Path(CGRect(x: x0, y: 0, width: linerW, height: size.height - 14)), with: .color(Theme.liner))
            let paper = GraphicsContext.Shading.color(Theme.paper)
            for column in 0..<Int(across) {
                let lx = x0 + 10 + Double(column) * (labelW + 2 * k)
                if media.separation == .continuous {
                    context.fill(Path(CGRect(x: lx, y: 0, width: labelW, height: size.height - 14)), with: paper)
                } else {
                    context.fill(Path(roundedRect: CGRect(x: lx, y: top - gap - labelH, width: labelW, height: labelH), cornerRadius: 4),
                                 with: .color(Theme.paper.opacity(0.7)))
                    context.fill(Path(roundedRect: CGRect(x: lx, y: top + labelH + gap, width: labelW, height: labelH), cornerRadius: 4),
                                 with: .color(Theme.paper.opacity(0.7)))
                    context.fill(Path(roundedRect: CGRect(x: lx, y: top, width: labelW, height: labelH), cornerRadius: 4), with: paper)
                    context.stroke(Path(roundedRect: CGRect(x: lx, y: top, width: labelW, height: labelH), cornerRadius: 4),
                                   with: .color(.black.opacity(0.15)), lineWidth: 0.5)
                }
            }
            if media.separation == .blackMark {
                for y in [top - gap / 2, top + labelH + gap / 2] {
                    context.fill(Path(CGRect(x: x0 + linerW - 8, y: y - 5, width: 6, height: 10)), with: .color(.black))
                }
            }
            let accent = GraphicsContext.Shading.color(.accentColor)
            func line(_ a: CGPoint, _ b: CGPoint) {
                var path = Path(); path.move(to: a); path.addLine(to: b)
                context.stroke(path, with: accent, lineWidth: 1.2)
            }
            func label(_ text: String, at point: CGPoint, anchor: UnitPoint) {
                context.draw(Text(text).font(.system(size: 11, weight: .bold)).foregroundColor(.accentColor), at: point, anchor: anchor)
            }
            // Width, above the label.
            let wx = x0 + 10, wy = top - 12
            line(CGPoint(x: wx, y: wy), CGPoint(x: wx + labelW, y: wy))
            line(CGPoint(x: wx, y: wy - 4), CGPoint(x: wx, y: wy + 4))
            line(CGPoint(x: wx + labelW, y: wy - 4), CGPoint(x: wx + labelW, y: wy + 4))
            label(unit.length(media.widthMM), at: CGPoint(x: wx + labelW / 2, y: wy - 3), anchor: .bottom)
            // Height, right of the liner.
            let hx = x0 + linerW + 12
            line(CGPoint(x: hx, y: top), CGPoint(x: hx, y: top + labelH))
            line(CGPoint(x: hx - 4, y: top), CGPoint(x: hx + 4, y: top))
            line(CGPoint(x: hx - 4, y: top + labelH), CGPoint(x: hx + 4, y: top + labelH))
            label(unit.length(media.heightMM), at: CGPoint(x: hx + 6, y: top + labelH / 2), anchor: .leading)
            // Gap / mark, left of the liner.
            if media.separation != .continuous {
                let gx = x0 - 10
                line(CGPoint(x: gx, y: top + labelH), CGPoint(x: gx, y: top + labelH + gap))
                label("\(unit.length(media.gapMM)) \(media.separation == .gap ? "gap" : "mark")",
                      at: CGPoint(x: gx - 4, y: top + labelH + gap / 2), anchor: .trailing)
            }
            context.draw(Text("Drawn to scale · paper feeds down").font(.system(size: 10)).foregroundColor(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height - 2), anchor: .bottom)
        }
        .accessibilityLabel("\(media.name), \(media.detailText)")
    }
}
