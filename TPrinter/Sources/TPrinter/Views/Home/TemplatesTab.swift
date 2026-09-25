import SwiftUI
import UniformTypeIdentifiers

/// All templates: the templates folder plus recently opened files. A "continue" card for the open
/// label, search, category chips, sort / grouping, grid or list, hover Print / Edit, and actions on
/// several templates at once (print, category, export, trash).
struct TemplatesTab: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var printCenter: PrintCenter
    @EnvironmentObject private var notices: NoticeCenter
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var history: PrintHistory
    @State private var recategorizing: TemplateFile?
    @State private var newCategory = ""
    @AppStorage("templatesLayout") private var layout = Layout.grid.rawValue
    @AppStorage("templatesSort") private var sort = Sort.recent.rawValue
    @AppStorage("templatesGrouping") private var groupsByCategory = true
    @State private var files: [TemplateFile] = []
    @State private var query = ""
    @State private var category: String?
    @State private var renaming: TemplateFile?
    @State private var renameText = ""
    @State private var trashing: TemplateFile?
    @State private var trashesSelection = false
    @State private var selection: Set<URL> = []
    @State private var isDropTarget = false
    @FocusState private var searchFocused: Bool

    enum Layout: String { case grid, list }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recently edited", printed = "Most printed", name = "Name", size = "Label size"
        var id: String { rawValue }
    }

    // MARK: Data

    private func name(_ file: TemplateFile) -> String { file.url.deletingPathExtension().lastPathComponent }

    private var categories: [(name: String, count: Int)] {
        var counts: [String: Int] = [:], order: [String] = []
        for file in files {
            guard let name = file.document?.mediaCategory, !name.isEmpty else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    /// Labels printed per template name, from the print history.
    private var printCounts: [String: Int] {
        history.records.reduce(into: [:]) { counts, record in
            if record.result == .printed { counts[record.templateName, default: 0] += record.labels }
        }
    }

    private var shown: [TemplateFile] {
        let counts = printCounts
        let filtered = files.filter { file in
            let matchesQuery = query.isEmpty || name(file).localizedCaseInsensitiveContains(query)
                || (file.document?.mediaTitle.localizedCaseInsensitiveContains(query) ?? false)
                || (file.document.map { MeasureUnit.current.size($0.widthMM, $0.heightMM).localizedCaseInsensitiveContains(query) } ?? false)
                || (file.document.map { LabelFields.names(in: $0).contains { $0.localizedCaseInsensitiveContains(query) } } ?? false)
            let matchesCategory = category == nil || file.document?.mediaCategory.caseInsensitiveCompare(category!) == .orderedSame
            return matchesQuery && matchesCategory
        }
        switch Sort(rawValue: sort) ?? .recent {
        case .recent: return filtered.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .printed: return filtered.sorted { counts[name($0), default: 0] > counts[name($1), default: 0] }
        case .name: return filtered.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        case .size: return filtered.sorted { area($0) < area($1) }
        }
    }

    private func area(_ file: TemplateFile) -> Double {
        guard let d = file.document else { return .infinity }
        return d.widthMM * d.heightMM
    }

    /// Templates grouped by category (first-seen order), uncategorised last as "Other".
    private var sections: [(name: String, files: [TemplateFile])] {
        guard groupsByCategory else { return [("", shown)] }
        var groups: [String: [TemplateFile]] = [:], order: [String] = []
        for file in shown {
            let key = file.document?.mediaCategory.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Other"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        let sorted = order.filter { $0 != "Other" } + (order.contains("Other") ? ["Other"] : [])
        return sorted.map { ($0, groups[$0] ?? []) }
    }

    private var selectedFiles: [TemplateFile] { files.filter { selection.contains($0.url) } }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !outsideFolder.isEmpty { outsideBanner }
                continueCard
                toolbar
                if shown.isEmpty {
                    emptyState
                } else if layout == Layout.list.rawValue {
                    listView
                } else {
                    ForEach(Array(sections.enumerated()), id: \.element.name) { index, section in
                        gridSection(section, showsNewCard: index == 0)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 130)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                selectionBar
                    .padding(.bottom, 86)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: selection.isEmpty)
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
        .onChange(of: files) { _, new in selection = selection.intersection(Set(new.map(\.url))) }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
            Button("") { selection = [] }.keyboardShortcut(.cancelAction).hidden().disabled(selection.isEmpty)
        }
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
        .sheet(isPresented: $trashesSelection) {
            ModernDialog(icon: "trash.fill", tone: .danger,
                         title: "Move \(selection.count) template\(selection.count == 1 ? "" : "s") to the Trash?",
                         message: "You can put them back from the Trash in Finder.",
                         primary: .init("Move to Trash", role: .destructive) { trashSelection() })
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Templates").font(.system(size: 26, weight: .bold))
                    Text("\(files.count)").font(.system(size: 20, weight: .medium)).foregroundStyle(.tertiary)
                }
                Label(locationText, systemImage: AppStorageLocation.isInICloudDrive(session.templatesFolder) ? "icloud.fill" : "folder.fill")
                    .font(.callout).foregroundStyle(.secondary)
                    .labelStyle(TintedIconLabelStyle())
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search templates, sizes, fields", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if query.isEmpty {
                    Text("⌘F").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                } else {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(width: 300)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searchFocused ? Color.accentColor : Color.primary.opacity(0.1),
                                                                      lineWidth: searchFocused ? 1.5 : 1))
            Button { chooseImport() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Copy .tprlabel files into your templates folder")
            Menu {
                Button("Open Other File…") { session.openWithPanel() }
                Button("Show Templates Folder") {
                    try? FileManager.default.createDirectory(at: session.templatesFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(session.templatesFolder)
                }
                Button("Change Templates Folder…") { session.settingsSection = .files; session.route = .home(.settings) }
            } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden).fixedSize()
            Button { session.startNewLabel() } label: { Label("New Label", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }

    private var locationText: String {
        let folder = session.templatesFolder
        if AppStorageLocation.isInICloudDrive(folder) { return "iCloud Drive › \(folder.lastPathComponent)" }
        return folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: Continue

    @ViewBuilder
    private var continueCard: some View {
        let document = session.document
        if !document.elements.isEmpty, query.isEmpty, category == nil {
            let modified = session.fileURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
            let printed = printCounts[session.displayName, default: 0]
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.liner)
                    LabelThumbnail(document: document, maxSize: CGSize(width: 156, height: 74))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
                .frame(width: 180, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONTINUE WHERE YOU LEFT OFF").font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundStyle(Color.accentColor)
                    HStack(spacing: 6) {
                        Text(session.displayName).font(.system(size: 17, weight: .semibold))
                        if session.isDirty { Text("Edited").font(.caption.weight(.semibold)).foregroundStyle(Theme.ledBusy) }
                    }
                    Text([document.mediaTitle,
                          modified.map { "Edited \(RecentTemplateRow.edited($0))" },
                          printed > 0 ? "Printed \(printed)×" : nil]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { session.continueEditing() } label: { Label("Open", systemImage: "pencil") }
                    .controlSize(.large)
                Button { printCenter.printLabel(document, name: session.displayName) } label: { Label("Print", systemImage: "printer.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!printCenter.canPrint)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            FlowLayout(spacing: 6) {
                CategoryChip(title: "All", count: files.count, style: .all, isOn: category == nil) { category = nil }
                ForEach(categories, id: \.name) { item in
                    CategoryChip(title: item.name, count: item.count, style: CategoryStyle(item.name), isOn: category == item.name) {
                        category = category == item.name ? nil : item.name
                    }
                }
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(Sort(rawValue: sort)?.rawValue ?? "Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Picker("Group", selection: $groupsByCategory) {
                Text("By category").tag(true)
                Text("All").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(layout == Layout.list.rawValue)
            Picker("Layout", selection: $layout) {
                Image(systemName: "square.grid.2x2").tag(Layout.grid.rawValue).help("Grid")
                Image(systemName: "list.bullet").tag(Layout.list.rawValue).help("List")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    // MARK: Grid

    private func gridSection(_ section: (name: String, files: [TemplateFile]), showsNewCard: Bool) -> some View {
        let style = CategoryStyle(section.name.isEmpty ? "Other" : section.name)
        return VStack(alignment: .leading, spacing: 12) {
            if !section.name.isEmpty {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(style.color).frame(width: 10, height: 10)
                    Text(section.name).font(.system(size: 15, weight: .semibold))
                    Text("\(section.files.count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(section.files) { file in
                    TemplateGridCard(file: file, printed: printCounts[name(file), default: 0], canPrint: printCenter.canPrint,
                                     isSelected: selection.contains(file.url), isSelecting: !selection.isEmpty) {
                        tapped(file)
                    } onEdit: {
                        session.open(file.url)
                    } onToggle: {
                        toggle(file)
                    } onPrint: { copies in
                        printFile(file, copies: copies)
                    } menu: {
                        actionsMenu(file)
                    }
                    .contextMenu { actionsMenu(file) }
                }
                if showsNewCard, query.isEmpty {
                    NewTemplateCard { session.startNewLabel() }
                }
            }
        }
    }

    // MARK: List

    private var listView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 18)
                Text("Template").frame(maxWidth: .infinity, alignment: .leading)
                Text("Media").frame(width: 150, alignment: .leading)
                Text("Category").frame(width: 110, alignment: .leading)
                Text("Elements").frame(width: 64, alignment: .trailing)
                Text("Printed").frame(width: 60, alignment: .trailing)
                Text("Edited").frame(width: 130, alignment: .leading)
                Color.clear.frame(width: 96)
            }
            .font(.system(size: 10.5, weight: .bold)).textCase(.uppercase).kerning(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            ForEach(shown) { file in
                TemplateListRow(file: file, printed: printCounts[name(file), default: 0], canPrint: printCenter.canPrint,
                                isSelected: selection.contains(file.url)) {
                    tapped(file)
                } onEdit: {
                    session.open(file.url)
                } onToggle: {
                    toggle(file)
                } onPrint: { copies in
                    printFile(file, copies: copies)
                } menu: {
                    actionsMenu(file)
                }
                .contextMenu { actionsMenu(file) }
                if file.id != shown.last?.id { Divider().padding(.leading, 14) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    // MARK: Selection

    private func toggle(_ file: TemplateFile) {
        if selection.contains(file.url) { selection.remove(file.url) } else { selection.insert(file.url) }
    }

    /// Selecting: a click adds / removes; otherwise it opens the template.
    private func tapped(_ file: TemplateFile) {
        if !selection.isEmpty || NSEvent.modifierFlags.contains(.command) { toggle(file) } else { session.open(file.url) }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text("\(selection.count) selected").font(.system(size: 13, weight: .semibold)).padding(.leading, 6)
            Divider().frame(height: 18)
            Button { printSelection() } label: { Label("Print", systemImage: "printer.fill") }
                .disabled(!printCenter.canPrint)
            Menu {
                ForEach(knownCategories, id: \.self) { name in
                    Button(name) { selectedFiles.forEach { setCategory(name, of: $0) } }
                }
                Divider()
                Button("No Category (Other)") { selectedFiles.forEach { setCategory("", of: $0) } }
            } label: { Label("Category", systemImage: "tag") }
            .menuIndicator(.hidden).fixedSize()
            Button { exportSelection() } label: { Label("Export", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { trashesSelection = true } label: { Label("Trash", systemImage: "trash") }
            Divider().frame(height: 18)
            Button { selection = Set(shown.map(\.url)) } label: { Text("Select All") }
            Button { selection = [] } label: { Image(systemName: "xmark") }
                .help("Clear selection (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }

    private func printSelection() {
        let documents = selectedFiles.compactMap(\.document)
        guard let first = documents.first else { return }
        printCenter.printLabels(count: documents.count, name: "\(documents.count) templates", sample: first) { documents[$0] }
    }

    private func exportSelection() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \(selection.count) template\(selection.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run {
            for file in selectedFiles {
                try FileManager.default.copyItem(at: file.url, to: TemplateFiles.uniqueURL(named: name(file), in: folder))
            }
            notices.post(.success, "Exported \(selection.count) template\(selection.count == 1 ? "" : "s")", folder.lastPathComponent)
        }
    }

    private func trashSelection() {
        let urls = selectedFiles.map(\.url)
        selection = []
        run {
            for url in urls {
                try TemplateFiles.moveToTrash(url)
                session.removeRecent(url)
            }
            reload()
        }
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
        if session.recentURLs.contains(file.url) || session.isInTemplatesFolder(file.url) {
            Button("Batch Print from CSV…") { session.open(file.url); session.showBatch() }
        }
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

    private func printFile(_ file: TemplateFile, copies: Int = 1) {
        guard var document = file.document else { return }
        document.copies = copies
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


// MARK: - Cards

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Label with its icon in the accent colour and the text secondary.
private struct TintedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(Color.accentColor)
            configuration.title
        }
    }
}

/// Copies stepper + Print, shown from a card's Print button.
private struct QuickPrintPanel: View {
    let file: TemplateFile
    var onPrint: (Int) -> Void
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @Environment(\.dismiss) private var dismiss
    @State private var copies = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Print “\(file.url.deletingPathExtension().lastPathComponent)”").font(.headline).lineLimit(1)
            HStack {
                Text("Copies")
                Spacer()
                Stepper(value: $copies, in: 1...99) { Text("\(copies)").monospacedDigit().fontWeight(.semibold) }
            }
            HStack(spacing: 6) {
                StatusLED(state: bluetooth.connection.isReady ? .ready : .off)
                Text(bluetooth.connection.isReady ? bluetooth.displayName : "No printer connected")
                Spacer()
                if let document = file.document { Text(MeasureUnit.current.size(document.widthMM, document.heightMM)) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Button {
                onPrint(copies)
                dismiss()
            } label: {
                Label("Print \(copies) Label\(copies == 1 ? "" : "s")", systemImage: "printer.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!bluetooth.connection.isReady || file.document == nil)
        }
        .padding(14)
        .frame(width: 250)
    }
}

/// Grid card: the label on its roll (hover: Print / Edit), a selection tick, name + ⋯ menu, tags
/// (category, size, elements) and how often it was printed.
private struct TemplateGridCard<MenuContent: View>: View {
    let file: TemplateFile
    let printed: Int
    let canPrint: Bool
    let isSelected: Bool
    let isSelecting: Bool
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onToggle: () -> Void
    var onPrint: (Int) -> Void
    @ViewBuilder var menu: () -> MenuContent
    @State private var hovering = false
    @State private var showsPrint = false

    private var name: String { file.url.deletingPathExtension().lastPathComponent }
    private var style: CategoryStyle { CategoryStyle(file.document?.mediaCategory.isEmpty == false ? file.document!.mediaCategory : "Other") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Menu { menu() } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 24, height: 20).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("More")
                }
                HStack(spacing: 5) {
                    TagChip(text: style.title, color: style.color)
                    if let document = file.document {
                        TagChip(text: MeasureUnit.current.size(document.widthMM, document.heightMM))
                        TagChip(text: "\(document.elements.count) element\(document.elements.count == 1 ? "" : "s")")
                    }
                }
                HStack {
                    Text(printed > 0 ? "Printed \(printed)×" : "Not printed yet")
                    Spacer()
                    if let modified = file.modified { Text(RecentTemplateRow.edited(modified)) }
                }
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                                                  lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(hovering ? 0.13 : 0.05), radius: hovering ? 12 : 3, y: hovering ? 5 : 1)
        .offset(y: hovering ? -2 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onOpen)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .help(file.url.path)
    }

    private var preview: some View {
        ZStack {
            Theme.liner
            // The neighbouring labels on the roll, just peeking in.
            VStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.paper.opacity(0.55)).frame(height: 14).offset(y: -7)
                Spacer()
                RoundedRectangle(cornerRadius: 6).fill(Theme.paper.opacity(0.55)).frame(height: 14).offset(y: 7)
            }
            .padding(.horizontal, 18)
            if let document = file.document {
                LabelThumbnail(document: document, maxSize: CGSize(width: 190, height: 104), cornerRadius: 5)
                    .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
            } else {
                Label("Can't read this file", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            if hovering, !isSelecting {
                Color.black.opacity(0.32)
                HStack(spacing: 8) {
                    Button { showsPrint = true } label: { Label("Print", systemImage: "printer.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canPrint || file.document == nil)
                        .help(canPrint ? "Print with copies" : "Connect a printer to print")
                        .popover(isPresented: $showsPrint, arrowEdge: .bottom) { QuickPrintPanel(file: file, onPrint: onPrint) }
                    Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                .controlSize(.regular)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .transition(.opacity)
            }
        }
        .frame(height: 148)
        .clipped()
        .overlay(alignment: .topLeading) {
            if hovering || isSelecting || isSelected {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .background(Circle().fill(isSelected ? .white : .black.opacity(0.25)).padding(2))
                        .shadow(color: .black.opacity(0.25), radius: 2)
                }
                .buttonStyle(.plain)
                .padding(9)
                .help(isSelected ? "Deselect" : "Select (⌘-click)")
            }
        }
        .overlay(alignment: .topTrailing) {
            if let document = file.document, !LabelFields.names(in: document).isEmpty {
                Text("CSV").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.purple, in: RoundedRectangle(cornerRadius: 5))
                    .padding(9)
                    .help("Has {{fields}} for batch printing")
            }
        }
    }
}

/// Small rounded tag: "● Product", "30 × 15 mm".
private struct TagChip: View {
    let text: String
    var color: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Dashed "New label" card at the end of the grid; drop .tprlabel files anywhere to import.
private struct NewTemplateCard: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                Text("New label").font(.system(size: 13.5, weight: .semibold))
                Text("or drop .tprlabel files to import").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 238)
            .foregroundStyle(hovering ? Color.accentColor : .primary)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.18),
                                                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// List row: tick, thumbnail + name, media, category, elements, printed, edited, Print / Edit / ⋯.
private struct TemplateListRow<MenuContent: View>: View {
    let file: TemplateFile
    let printed: Int
    let canPrint: Bool
    let isSelected: Bool
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onToggle: () -> Void
    var onPrint: (Int) -> Void
    @ViewBuilder var menu: () -> MenuContent
    @State private var hovering = false
    @State private var showsPrint = false

    var body: some View {
        let style = CategoryStyle(file.document?.mediaCategory.isEmpty == false ? file.document!.mediaCategory : "Other")
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(hovering ? 1 : 0.4))
            }
            .buttonStyle(.plain).frame(width: 18)
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.liner)
                    if let document = file.document { LabelThumbnail(document: document, maxSize: CGSize(width: 56, height: 32)) }
                }
                .frame(width: 64, height: 40)
                Text(file.url.deletingPathExtension().lastPathComponent).fontWeight(.semibold).lineLimit(1)
                if let document = file.document, !LabelFields.names(in: document).isEmpty {
                    Text("CSV").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.purple, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.document?.mediaTitle ?? "—").foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .leading)
            TagChip(text: style.title, color: style.color).frame(width: 110, alignment: .leading)
            Text(file.document.map { "\($0.elements.count)" } ?? "—").frame(width: 64, alignment: .trailing)
            Text(printed > 0 ? "\(printed)×" : "—").frame(width: 60, alignment: .trailing)
            Text(file.modified.map { RecentTemplateRow.edited($0) } ?? "—").foregroundStyle(.secondary).lineLimit(1).frame(width: 130, alignment: .leading)
            HStack(spacing: 2) {
                Button { showsPrint = true } label: { Image(systemName: "printer") }
                    .disabled(!canPrint || file.document == nil)
                    .help("Print")
                    .popover(isPresented: $showsPrint, arrowEdge: .bottom) { QuickPrintPanel(file: file, onPrint: onPrint) }
                Button(action: onEdit) { Image(systemName: "pencil") }.help("Edit")
                Menu { menu() } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
            .frame(width: 96, alignment: .trailing)
            .opacity(hovering || isSelected ? 1 : 0.5)
        }
        .font(.callout).monospacedDigit()
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : (hovering ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
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
