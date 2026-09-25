import SwiftUI
import UniformTypeIdentifiers

/// All templates: the templates folder plus recently opened files. Search, filter by media
/// category, sort, grid or list, and file actions (import, duplicate, export, rename, trash).
struct TemplatesTab: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var printCenter: PrintCenter
    @EnvironmentObject private var notices: NoticeCenter
    @EnvironmentObject private var library: MediaLibrary
    @State private var recategorizing: TemplateFile?
    @State private var newCategory = ""
    @AppStorage("templatesLayout") private var layout = Layout.grid.rawValue
    @AppStorage("templatesSort") private var sort = Sort.recent.rawValue
    @State private var files: [TemplateFile] = []
    @State private var query = ""
    @State private var category: String?
    @State private var renaming: TemplateFile?
    @State private var renameText = ""
    @State private var trashing: TemplateFile?
    @State private var isDropTarget = false

    enum Layout: String { case grid, list }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recently edited", name = "Name", size = "Label size"
        var id: String { rawValue }
    }

    // MARK: Data

    private var categories: [(name: String, count: Int)] {
        var counts: [String: Int] = [:], order: [String] = []
        for file in files {
            guard let name = file.document?.mediaCategory, !name.isEmpty else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    private var shown: [TemplateFile] {
        let filtered = files.filter { file in
            let name = file.url.deletingPathExtension().lastPathComponent
            let matchesQuery = query.isEmpty || name.localizedCaseInsensitiveContains(query)
                || (file.document?.mediaTitle.localizedCaseInsensitiveContains(query) ?? false)
            let matchesCategory = category == nil || file.document?.mediaCategory.caseInsensitiveCompare(category!) == .orderedSame
            return matchesQuery && matchesCategory
        }
        switch Sort(rawValue: sort) ?? .recent {
        case .recent: return filtered.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .name: return filtered.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        case .size: return filtered.sorted { area($0) < area($1) }
        }
    }

    private func area(_ file: TemplateFile) -> Double {
        guard let d = file.document else { return .infinity }
        return d.widthMM * d.heightMM
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                categoryChips
                toolbar
                if !outsideFolder.isEmpty { outsideBanner }
                if shown.isEmpty {
                    emptyState
                } else {
                    ForEach(sections, id: \.name) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 110)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(Label("Drop templates to import", systemImage: "square.and.arrow.down").font(.title3.weight(.semibold)))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let templates = urls.filter { $0.pathExtension == LabelTemplate.fileExtension }
            guard !templates.isEmpty else { return false }
            importFiles(templates)
            return true
        } isTargeted: { isDropTarget = $0 }
        .task(id: session.recentURLs) { reload() }
        .sheet(isPresented: Binding(presenting: $renaming)) {
            let trimmed = renameText.trimmingCharacters(in: .whitespaces)
            let unchanged = trimmed == renaming?.url.deletingPathExtension().lastPathComponent
            ModernDialog(icon: "pencil", tone: .info, title: "Rename template",
                         message: "The file is renamed in Finder too.",
                         primary: .init("Rename", isDisabled: trimmed.isEmpty || unchanged) { if let file = renaming { rename(file) } },
                         onCancel: { renaming = nil }) {
                DialogTextField(placeholder: "Template name", text: $renameText) {
                    if let file = renaming, !trimmed.isEmpty, !unchanged { rename(file) }
                }
            }
        }
        .sheet(isPresented: Binding(presenting: $recategorizing)) {
            let trimmed = newCategory.trimmingCharacters(in: .whitespaces)
            ModernDialog(icon: "tag.fill", tone: .info, title: "New category",
                         message: "“\(recategorizing?.url.deletingPathExtension().lastPathComponent ?? "")” moves to this category.",
                         primary: .init("Set Category", isDisabled: trimmed.isEmpty) {
                             if let file = recategorizing { setCategory(trimmed, of: file) }
                         },
                         onCancel: { recategorizing = nil }) {
                DialogTextField(placeholder: "e.g. Perfume, Shipping, Price", text: $newCategory) {
                    if let file = recategorizing, !trimmed.isEmpty { setCategory(trimmed, of: file); recategorizing = nil }
                }
            }
        }
        .sheet(isPresented: Binding(presenting: $trashing)) {
            ModernDialog(icon: "trash.fill", tone: .danger,
                         title: "Move “\(trashing?.url.deletingPathExtension().lastPathComponent ?? "")” to the Trash?",
                         message: "You can put it back from the Trash in Finder.",
                         primary: .init("Move to Trash", role: .destructive) { if let file = trashing { trash(file) } },
                         onCancel: { trashing = nil })
        }
    }

    private var header: some View {
        ZStack {
            Text("Templates").font(.system(size: 22, weight: .semibold))
            HStack(spacing: 10) {
                Spacer()
                Button { chooseImport() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Import .tprlabel files into your templates folder")
                Menu {
                    Button("Open Other File…") { session.openWithPanel() }
                    Button("Show Templates Folder") {
                        try? FileManager.default.createDirectory(at: session.templatesFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(session.templatesFolder)
                    }
                    Button("Change Templates Folder…") { session.settingsSection = .files; session.route = .home(.settings) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { session.startNewLabel() } label: { Image(systemName: "plus").font(.system(size: 17, weight: .medium)) }
                    .help("New label")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15))
        }
        .frame(height: 30)
    }

    /// Centred category chips with each category's icon and colour.
    private var categoryChips: some View {
        let chips = HStack(spacing: 8) {
            CategoryChip(title: "All", count: files.count, style: .all, isOn: category == nil) { category = nil }
            ForEach(categories, id: \.name) { item in
                CategoryChip(title: item.name, count: item.count, style: CategoryStyle(item.name), isOn: category == item.name) {
                    category = category == item.name ? nil : item.name
                }
            }
        }
        .padding(.vertical, 2)
        // Centred when they fit, scrolling sideways when there are many categories.
        return ViewThatFits(in: .horizontal) {
            chips.frame(maxWidth: .infinity)
            ScrollView(.horizontal) { chips }.scrollIndicators(.never)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name or media", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 260)
            Spacer()
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(Sort(rawValue: sort)?.rawValue ?? "Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Picker("Layout", selection: $layout) {
                Image(systemName: "square.grid.2x2").tag(Layout.grid.rawValue).help("Grid")
                Image(systemName: "list.bullet").tag(Layout.list.rawValue).help("List")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Sections

    /// Templates grouped by media category (in first-seen order), uncategorised last as "Other".
    private var sections: [(name: String, files: [TemplateFile])] {
        var groups: [String: [TemplateFile]] = [:], order: [String] = []
        for file in shown {
            let name = file.document?.mediaCategory.trimmingCharacters(in: .whitespaces) ?? ""
            let key = name.isEmpty ? "Other" : name
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        let sorted = order.filter { $0 != "Other" } + (order.contains("Other") ? ["Other"] : [])
        return sorted.map { ($0, groups[$0] ?? []) }
    }

    private func sectionView(_ section: (name: String, files: [TemplateFile])) -> some View {
        let style = CategoryStyle(section.name)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: style.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.color)
                    .frame(width: 28, height: 28)
                    .background(style.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                Text(section.name).font(.title3.weight(.bold))
                Text("\(section.files.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(style.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(style.color.opacity(0.14), in: Capsule())
            }
            if layout == Layout.list.rawValue {
                listView(section.files)
            } else {
                gridView(section.files, style: style)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Layouts

    private func gridView(_ files: [TemplateFile], style: CategoryStyle) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 210), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
            ForEach(files) { file in
                TemplateTile(file: file, style: style, canPrint: printCenter.canPrint) { session.open(file.url) } print: {
                    printFile(file)
                } trash: { trashing = file } categoryMenu: { categoryMenu(file) }
                    .contextMenu { actionsMenu(file) }
            }
        }
    }

    private func listView(_ files: [TemplateFile]) -> some View {
        VStack(spacing: 0) {
            ForEach(files) { file in
                TemplateRow(file: file, canPrint: printCenter.canPrint) { session.open(file.url) } print: {
                    printFile(file)
                } menu: { actionsMenu(file) }
                    .contextMenu { actionsMenu(file) }
                if file.id != files.last?.id { Divider().padding(.leading, 96) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: files.isEmpty ? "rectangle.stack.badge.plus" : "magnifyingglass")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(files.isEmpty ? "No templates yet" : "No templates match").font(.title3.weight(.semibold))
            Text(files.isEmpty
                 ? "Design a label and save it (⌘S), or import .tprlabel files. You can also drop files here."
                 : "Try another name, or show all categories.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if files.isEmpty {
                HStack {
                    Button("Import…") { chooseImport() }
                    Button("New Label") { session.startNewLabel() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            } else {
                Button("Clear Filters") { query = ""; category = nil }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: Actions

    @ViewBuilder
    private func actionsMenu(_ file: TemplateFile) -> some View {
        Button("Open") { session.open(file.url) }
        Button("Print") { printFile(file) }.disabled(!printCenter.canPrint || file.document == nil)
        Divider()
        Button("Duplicate") {
            run {
                let copy = try TemplateFiles.duplicate(file.url)
                // The copy sits next to the original, which may be outside the templates folder: add it
                // to recents so it's always listed (this also reloads via the recents change).
                session.addRecent(copy)
                reload()
                notices.post(.info, "Duplicated", copy.deletingPathExtension().lastPathComponent)
            }
        }
        Button("Rename…") { renameText = file.url.deletingPathExtension().lastPathComponent; renaming = file }
        Menu("Category") { categoryMenu(file) }
        Menu("Export") {
            Button("Template File…") { run { try TemplateFiles.exportTemplate(file.url) } }
            Button("Image (PNG)…") {
                guard let document = file.document else { return }
                run { try TemplateFiles.exportImage(document, name: file.url.deletingPathExtension().lastPathComponent) }
            }
            .disabled(file.document == nil)
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        if !session.isInTemplatesFolder(file.url) {
            Button("Move to Templates Folder") { moveIntoFolder([file.url]) }
        }
        Divider()
        if session.recentURLs.contains(file.url) {
            Button("Remove from Recents") { session.removeRecent(file.url); reload() }
        }
        Button("Move to Trash…", role: .destructive) { trashing = file }
    }

    /// Templates listed from recents that live somewhere else (Downloads, Desktop …).
    private var outsideFolder: [URL] { files.map(\.url).filter { !session.isInTemplatesFolder($0) } }

    private var outsideBanner: some View {
        let count = outsideFolder.count
        let places = Set(outsideFolder.map { $0.deletingLastPathComponent().lastPathComponent }).sorted().joined(separator: ", ")
        return HStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) template\(count == 1 ? " is" : "s are") outside your templates folder")
                    .font(.callout.weight(.semibold))
                Text("In \(places). Move \(count == 1 ? "it" : "them") in to keep everything together and backed up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(count == 1 ? "Move to Templates Folder" : "Move All to Templates Folder") { moveIntoFolder(outsideFolder) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.3)))
    }

    private func moveIntoFolder(_ urls: [URL]) {
        run {
            let moved = try session.moveToTemplatesFolder(urls)
            reload()
            if !moved.isEmpty {
                notices.post(.success, "Moved \(moved.count) template\(moved.count == 1 ? "" : "s")",
                             "Now in \(session.templatesFolder.lastPathComponent)")
            }
        }
    }

    /// Every category in use: media categories plus those templates already have.
    private var knownCategories: [String] {
        var seen = Set<String>()
        return (library.categories + files.compactMap { $0.document?.mediaCategory })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    @ViewBuilder
    private func categoryMenu(_ file: TemplateFile) -> some View {
        let current = file.document?.mediaCategory ?? ""
        ForEach(knownCategories, id: \.self) { name in
            Button {
                setCategory(name, of: file)
            } label: {
                if current.caseInsensitiveCompare(name) == .orderedSame { Label(name, systemImage: "checkmark") } else { Text(name) }
            }
        }
        Divider()
        Button("New Category…") { newCategory = ""; recategorizing = file }
        if !current.isEmpty {
            Button("No Category (Other)") { setCategory("", of: file) }
        }
    }

    private func setCategory(_ category: String, of file: TemplateFile) {
        run {
            try session.setCategory(category, of: file.url)
            reload()
        }
    }

    private func printFile(_ file: TemplateFile) {
        guard let document = file.document else { return }
        printCenter.printLabel(document, name: file.url.deletingPathExtension().lastPathComponent)
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tprinterLabel]
        panel.allowsMultipleSelection = true
        panel.message = "Choose templates to copy into \(session.templatesFolder.lastPathComponent)"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    private func importFiles(_ urls: [URL]) {
        run {
            let imported = try TemplateFiles.importFiles(urls, into: session.templatesFolder)
            reload()
            if !imported.isEmpty {
                notices.post(.success, "Imported \(imported.count) template\(imported.count == 1 ? "" : "s")",
                             imported.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", "))
            }
        }
    }

    private func rename(_ file: TemplateFile) {
        renaming = nil
        run {
            let renamed = try TemplateFiles.rename(file.url, to: renameText)
            session.templateMoved(from: file.url, to: renamed)
            reload()
        }
    }

    private func trash(_ file: TemplateFile) {
        trashing = nil
        run {
            try TemplateFiles.moveToTrash(file.url)
            session.removeRecent(file.url)
            reload()
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { session.errorMessage = error.localizedDescription }
    }

    private func reload() {
        let folder = session.templatesFolder
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // iCloud Drive keeps not-yet-downloaded files as ".Name.tprlabel.icloud": ask for them, they
        // show up on the next reload.
        for placeholder in contents where placeholder.pathExtension == "icloud" && placeholder.lastPathComponent.hasPrefix(".") {
            let name = String(placeholder.deletingPathExtension().lastPathComponent.dropFirst())
            try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(name))
        }
        let inFolder = contents.filter { $0.pathExtension == LabelTemplate.fileExtension }
        var seen = Set<String>()
        let urls = (inFolder + session.recentURLs)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
        files = urls.map(TemplateFile.load)
    }
}

// MARK: - Tiles

/// Grid card: the label on a grey tray with its category badge, delete button, name, size and element
/// count, and an Edit button in the category's colour. Right-click for every file action.
private struct TemplateTile<CategoryMenu: View>: View {
    let file: TemplateFile
    let style: CategoryStyle
    let canPrint: Bool
    var open: () -> Void
    var print: () -> Void
    var trash: () -> Void
    @ViewBuilder var categoryMenu: () -> CategoryMenu
    @State private var hovering = false

    private var name: String { file.url.deletingPathExtension().lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.top, 10)
            HStack(spacing: 6) {
                Button(action: open) {
                    Text("Edit").font(.callout.weight(.medium)).frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(style.color)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(style.color.opacity(0.8)))
                        .contentShape(Rectangle())
                }
                Button(action: print) {
                    Image(systemName: "printer").font(.system(size: 12, weight: .medium)).frame(width: 30, height: 26)
                        .foregroundStyle(canPrint ? style.color : Color.secondary)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder((canPrint ? style.color : Color.secondary).opacity(0.5)))
                        .contentShape(Rectangle())
                }
                .disabled(!canPrint || file.document == nil)
                .help(canPrint ? "Print" : "Connect a printer to print")
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? style.color.opacity(0.6) : Color.primary.opacity(0.07),
                                                                  lineWidth: hovering ? 1.5 : 1))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 10 : 3, y: hovering ? 4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .help(file.url.path)
    }

    private var detail: String {
        guard let document = file.document else { return "Can't read this file" }
        let count = document.elements.count
        return "\(document.widthMM.formatted())×\(document.heightMM.formatted())mm  •  \(count) element\(count == 1 ? "" : "s")"
    }

    private var preview: some View {
        let box = CGSize(width: 180, height: 132)
        return ZStack {
            Color.primary.opacity(0.06)
            if let document = file.document {
                LabelThumbnail(document: document, maxSize: CGSize(width: box.width - 28, height: box.height - 36))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .padding(.top, 8)
            } else {
                Image(systemName: "questionmark.square.dashed").font(.title).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: box.height)
        .overlay(alignment: .topLeading) {
            // Click the badge to move the template to another category.
            Menu { categoryMenu() } label: {
                HStack(spacing: 4) {
                    Label(style.title, systemImage: style.icon)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .heavy)).opacity(0.8)
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(style.color, in: RoundedRectangle(cornerRadius: 5))
            }
            // .button + .plain draws the label as designed (borderlessButton recolours it in light mode).
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Change category")
            .padding(7)
        }
        .overlay(alignment: .topTrailing) {
            if let document = file.document, !LabelFields.names(in: document).isEmpty {
                Text("CSV")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
                    .padding(7)
                    .help("Has {{fields}} for batch printing")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: trash) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.red, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            }
            .buttonStyle(.plain)
            .help("Move to Trash")
            .padding(7)
        }
    }
}

/// List row: thumbnail, name, media, edited, actions.
private struct TemplateRow<MenuContent: View>: View {
    let file: TemplateFile
    let canPrint: Bool
    var open: () -> Void
    var print: () -> Void
    @ViewBuilder var menu: () -> MenuContent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let document = file.document {
                    LabelThumbnail(document: document, maxSize: CGSize(width: 62, height: 40))
                        .frame(width: 70, height: 48)
                        .background(Theme.liner, in: RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.liner.opacity(0.4)).frame(width: 70, height: 48)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(file.url.deletingPathExtension().lastPathComponent).font(.headline)
                    if let document = file.document, !LabelFields.names(in: document).isEmpty { FieldsBadge() }
                }
                Text(file.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let document = file.document { MediaBadge(text: document.mediaTitle) }
            Text(file.modified?.formatted(.relative(presentation: .named)) ?? "").font(.callout).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            HStack(spacing: 4) {
                Button(action: print) { Image(systemName: "printer") }
                    .disabled(!canPrint || file.document == nil)
                    .help("Print")
                Menu { menu() } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.45)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}

private struct MediaBadge: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "rectangle.split.1x2")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

private struct FieldsBadge: View {
    var body: some View {
        Text("CSV").font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.purple.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.purple)
            .help("Has {{fields}} for batch printing")
    }
}

/// Capsule filter button ("All 3", "Product 2" …).
struct FilterChip: View {
    let title: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(isOn ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Icon and colour for a media category. Known names get a fitting symbol; others get a stable colour.
struct CategoryStyle {
    let title: String
    let icon: String
    let color: Color

    static let all = CategoryStyle(title: "All", icon: "square.grid.3x3.fill", color: .accentColor)

    init(title: String, icon: String, color: Color) {
        self.title = title; self.icon = icon; self.color = color
    }

    init(_ category: String) {
        let key = category.lowercased()
        let known: [(words: [String], icon: String, color: Color)] = [
            (["cargo", "shipping", "parcel", "delivery", "kargo"], "truck.box.fill", .blue),
            (["product", "ürün", "retail"], "archivebox.fill", .green),
            (["barcode", "sku", "inventory"], "barcode", .orange),
            (["price", "fiyat", "tag"], "tag.fill", .red),
            (["warehouse", "depo", "storage"], "house.fill", .brown),
            (["picking", "order", "list"], "checklist", .purple),
            (["food", "kitchen", "date"], "fork.knife", .orange),
            (["jewelry", "jewellery", "ring"], "sparkles", .pink),
            (["perfume", "fragrance", "cosmetic"], "drop.fill", .indigo),
            (["custom"], "paintbrush.pointed.fill", .gray),
            (["other"], "square.stack.fill", .gray),
        ]
        if let match = known.first(where: { entry in entry.words.contains { key.contains($0) } }) {
            self.init(title: category, icon: match.icon, color: match.color)
        } else {
            let palette: [Color] = [.teal, .mint, .cyan, .indigo, .pink, .orange]
            let index = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
            self.init(title: category, icon: "tag.fill", color: palette[index])
        }
    }
}

/// Capsule category button with icon: filled when selected.
private struct CategoryChip: View {
    let title: String
    let count: Int
    let style: CategoryStyle
    let isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Image(systemName: style.icon).foregroundStyle(isOn ? .white : style.color)
                Text(title).font(.callout.weight(.medium))
                Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(isOn ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 13).padding(.vertical, 6)
            .foregroundStyle(isOn ? .white : .primary)
            .background(isOn ? style.color : Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? .clear : (hovering ? style.color.opacity(0.6) : Color.primary.opacity(0.15))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
