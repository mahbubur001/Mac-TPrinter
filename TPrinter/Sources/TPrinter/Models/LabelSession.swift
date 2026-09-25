import AppKit
import Foundation
import UniformTypeIdentifiers

/// The label being edited, the template file it belongs to, and New / Open / Save.
///
/// The working copy is autosaved to UserDefaults on every change, so quitting never loses edits:
/// the next launch restores the document, its file, and the "Edited" state.
///
/// Every change to `document` is undoable through `undoManager` (the window's, set by ContentView).
/// Rapid changes with the same action name (typing, stepper clicks, arrow nudges) coalesce into one step.
@MainActor
final class LabelSession: ObservableObject {
    @Published var document: LabelDocument {
        didSet {
            guard document != oldValue else { return }
            if !isReplacingDocument { registerUndo(restoring: oldValue) }
            isDirty = document != baseline
            autosave()
        }
    }
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var recentURLs: [URL] = []
    /// Bumped whenever a different document is loaded, so views can reset selection.
    @Published private(set) var generation = 0
    @Published var errorMessage: String?
    /// Which screen the window shows.
    @Published var route: AppRoute = .home(.dashboard) {
        didSet { if case .home(let tab) = route { lastHomeTab = tab } }
    }
    /// The tab the editor / new-label flow was opened from; Back returns there.
    private(set) var lastHomeTab: HomeTab = .dashboard

    /// Leaves the editor or new-label flow for the tab the user came from.
    func goBack() { route = .home(lastHomeTab) }
    /// Section shown when the Settings tab opens.
    @Published var settingsSection: SettingsSection = .media
    /// Set by "Define media": Settings › Media opens with a new, empty media.
    @Published var requestsNewMedia = false
    /// The home screens (tabs). Shown at launch; opening or creating a label switches to the editor.
    var showsDashboard: Bool {
        get { if case .home = route { true } else { false } }
        set { route = newValue ? .home(.dashboard) : .editor }
    }

    /// Opens the Batch tab (File › Batch Print from CSV…).
    func showBatch() { route = .home(.batch) }

    /// Starts the new-label flow: choose media, then arrangement, then the editor.
    func startNewLabel() { route = .newLabel }

    /// Folder the Templates tab lists and Save starts in.
    var templatesFolder: URL {
        get { defaults.string(forKey: Keys.templatesFolder).map { URL(fileURLWithPath: $0) } ?? AppStorageLocation.defaultTemplatesFolder }
        set { defaults.set(newValue.path, forKey: Keys.templatesFolder); objectWillChange.send() }
    }
    /// The layer being renamed in the sidebar (set by "Rename…" anywhere).
    @Published var renamingElementID: LabelElement.ID?

    private var isReplacingDocument = false
    /// The document as last opened/saved/created; "Edited" means `document != baseline`, so undoing
    /// back to it clears the flag.
    private var baseline: LabelDocument

    weak var undoManager: UndoManager?
    /// Changes closer together than this, with the same action name, become one undo step.
    static let undoCoalescingInterval: TimeInterval = 1.0
    var now: () -> Date = Date.init
    private var pendingActionName: String?
    private var lastUndo: (name: String, date: Date)?

    private enum Keys {
        static let document = "labelDocument"
        static let fileURL = "labelFileURL"
        static let baseline = "labelBaseline"
        static let recents = "recentTemplates"
        static let templatesFolder = "templatesFolder"
    }
    private static let maxRecents = 30
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func stored(_ key: String) -> LabelDocument? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LabelDocument.self, from: $0) }
        }
        let restored = stored(Keys.document) ?? LabelDocument()
        document = restored
        baseline = stored(Keys.baseline) ?? restored
        fileURL = defaults.string(forKey: Keys.fileURL).map { URL(fileURLWithPath: $0) }
        isDirty = restored != baseline
        recentURLs = (defaults.stringArray(forKey: Keys.recents) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    // MARK: - Editing

    /// Applies a change as one named undo step ("Undo Move").
    func perform(_ actionName: String, _ change: (inout LabelDocument) -> Void) {
        pendingActionName = actionName
        defer { pendingActionName = nil }
        change(&document)
    }

    private func registerUndo(restoring previous: LabelDocument) {
        guard let undoManager else { return }
        let name = pendingActionName ?? "Edit Label"
        let isUndoOrRedo = undoManager.isUndoing || undoManager.isRedoing
        // `lastUndo` is cleared by undo/redo and when a document is loaded, so a match here means our
        // previous step is still the one on top. (Don't use `canUndo`: it's false inside an open group.)
        if !isUndoOrRedo, let lastUndo, lastUndo.name == name,
           now().timeIntervalSince(lastUndo.date) < Self.undoCoalescingInterval {
            // Part of the same burst: the existing step already restores the state before it.
            self.lastUndo = (name, now())
            return
        }
        // Our own group: in the app it nests inside the window's per-event group; without event
        // grouping (tests) it's a complete step. Coalesced changes register nothing, so no empty groups.
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in
            session.perform(name) { $0 = previous }
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        lastUndo = isUndoOrRedo ? nil : (name, now())
    }

    // MARK: - Commands

    /// - Parameter size: a blank label of this size (mm); nil = the default starter layout.
    func newDocument(size: CGSize? = nil) {
        whenChangesHandled { [self] in
            var document = LabelDocument()
            if let size {
                document.widthMM = size.width
                document.heightMM = size.height
                document.elements = []
            }
            replace(with: document, fileURL: nil)
        }
    }

    /// Finishes the new-label flow: a blank label for `media`, laid out as `arrangement`.
    func newDocument(media: Media, arrangement: LabelArrangement, printMethod: PrintMethod = .image) {
        whenChangesHandled { [self] in
            var document = LabelDocument(media: media, arrangement: arrangement)
            document.printMethod = printMethod
            replace(with: document, fileURL: nil)
        }
    }

    /// Opens a copy of a label (e.g. from History) as a new, unsaved label.
    func openCopy(of document: LabelDocument) {
        whenChangesHandled { [self] in
            replace(with: document, fileURL: nil)
            isDirty = true
            persistFileState()
        }
    }

    /// Leaves the home screens for the label that's already open.
    func continueEditing() { route = .editor }

    func openWithPanel() {
        whenChangesHandled { [self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.tprinterLabel]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = "Choose a label template"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            load(url)
        }
    }

    /// Opens a template chosen from Open Recent or double-clicked in Finder.
    func open(_ url: URL) {
        // The label that's already open (edited or not): just go back to it.
        if url.standardizedFileURL == fileURL?.standardizedFileURL { return continueEditing() }
        whenChangesHandled { [self] in load(url) }
    }

    /// Saves in place; a label that was never saved asks for a name (templates folder by default).
    /// Returns true only when it saved right away.
    @discardableResult
    func save() -> Bool {
        guard let fileURL else {
            requestSave()
            return false
        }
        return write(to: fileURL)
    }

    /// "Save As…": the name dialog, saving a new file in the templates folder.
    func saveAs() {
        requestSave(asCopy: true)
    }

    /// The "Save Template" dialog (shown by ContentView): name, then `saveInTemplatesFolder(named:)`.
    struct SavePrompt: Identifiable {
        let id = UUID()
        let suggestedName: String
        let isCopy: Bool
        /// Runs after a successful save (e.g. leaving the editor).
        var then: (() -> Void)?
    }

    @Published var savePrompt: SavePrompt?

    func requestSave(asCopy: Bool = false, then: (() -> Void)? = nil) {
        savePrompt = SavePrompt(suggestedName: asCopy ? "\(suggestedName) copy" : suggestedName, isCopy: asCopy, then: then)
    }

    /// The file name a new label starts with: its name, else its first text, else "Untitled".
    var suggestedName: String {
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        let text = document.elements.first { $0.kind == .text }?.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces) ?? ""
        let clean = String(text.filter { !"/:{}".contains($0) }.prefix(40)).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Untitled" : clean
    }

    /// Saves as `<name>.tprlabel` in the templates folder (`name 2` … if taken). Returns the file.
    @discardableResult
    func saveInTemplatesFolder(named name: String) -> URL? {
        let prompt = savePrompt
        savePrompt = nil
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return nil }
        let folder = templatesFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't create the templates folder. \(error.localizedDescription)"
            return nil
        }
        let url = TemplateFiles.uniqueURL(named: clean, in: folder)
        guard write(to: url) else { return nil }
        prompt?.then?()
        return url
    }

    /// "Choose Location…" in the save dialog: the system save panel, for saving somewhere else.
    func saveWithPanel() {
        let prompt = savePrompt
        savePrompt = nil
        if saveWithPanel(named: prompt?.suggestedName ?? displayName) { prompt?.then?() }
    }

    @discardableResult
    private func saveWithPanel(named name: String) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tprinterLabel]
        panel.nameFieldStringValue = "\(name).\(LabelTemplate.fileExtension)"
        let folder = templatesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? folder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    /// Moves template files into the templates folder (unique names), keeping recents and the open
    /// label pointing at them. Returns the new locations.
    @discardableResult
    func moveToTemplatesFolder(_ urls: [URL]) throws -> [URL] {
        let folder = templatesFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var moved: [URL] = []
        for url in urls where !isInTemplatesFolder(url) {
            let target = TemplateFiles.uniqueURL(named: url.deletingPathExtension().lastPathComponent, in: folder)
            try FileManager.default.moveItem(at: url, to: target)
            templateMoved(from: url, to: target)
            moved.append(target)
        }
        return moved
    }

    /// Moves every template in the templates folder to `newFolder` and makes it the templates folder
    /// (iCloud Drive and back). Recents and the open label follow; the old folder is removed if it's
    /// left empty. Returns how many templates moved.
    @discardableResult
    func relocateTemplatesFolder(to newFolder: URL) throws -> Int {
        let fm = FileManager.default
        let old = templatesFolder
        guard old.standardizedFileURL.path != newFolder.standardizedFileURL.path else { return 0 }
        try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
        // Built from the folder's own path (not the listing's URLs, which may spell it differently,
        // e.g. /private/var) so recents and the open label match and follow.
        let files = ((try? fm.contentsOfDirectory(atPath: old.path)) ?? [])
            .filter { $0.hasSuffix(".\(LabelTemplate.fileExtension)") }
            .map { old.appendingPathComponent($0) }
        var moved = 0
        for url in files {
            let target = TemplateFiles.uniqueURL(named: url.deletingPathExtension().lastPathComponent, in: newFolder)
            try fm.moveItem(at: url, to: target)
            templateMoved(from: url, to: target)
            moved += 1
        }
        templatesFolder = newFolder
        let left = ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).filter { $0 != ".DS_Store" }
        if left.isEmpty { try? fm.removeItem(at: old) }
        return moved
    }

    func isInTemplatesFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == templatesFolder.standardizedFileURL.path
    }

    /// A template file was renamed / moved on disk: keep recents and the open document pointing at it.
    func templateMoved(from old: URL, to new: URL) {
        recentURLs = recentURLs.map { $0.standardizedFileURL == old.standardizedFileURL ? new : $0 }
        saveRecents()
        if fileURL?.standardizedFileURL == old.standardizedFileURL {
            fileURL = new
            persistFileState()
        }
    }

    /// Puts a template at the top of the recents (e.g. a new duplicate), so it's listed everywhere.
    func addRecent(_ url: URL) { noteRecent(url) }

    func removeRecent(_ url: URL) {
        recentURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        saveRecents()
    }

    func clearRecents() {
        recentURLs = []
        defaults.removeObject(forKey: Keys.recents)
    }

    // MARK: - File I/O (internal for tests)

    func load(_ url: URL) {
        do {
            let loaded = try LabelTemplate.decode(Data(contentsOf: url))
            replace(with: loaded, fileURL: url)
            noteRecent(url)
        } catch {
            errorMessage = "Couldn't open “\(url.lastPathComponent)”. \(error.localizedDescription)"
            recentURLs.removeAll { $0 == url }
            saveRecents()
        }
    }

    @discardableResult
    func write(to url: URL) -> Bool {
        do {
            try LabelTemplate.encode(document).write(to: url, options: .atomic)
            fileURL = url
            baseline = document
            isDirty = false
            persistFileState()
            noteRecent(url)
            return true
        } catch {
            errorMessage = "Couldn't save “\(url.lastPathComponent)”. \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Internals

    private func replace(with document: LabelDocument, fileURL: URL?) {
        isReplacingDocument = true
        self.document = document
        isReplacingDocument = false
        self.fileURL = fileURL
        baseline = document
        isDirty = false
        generation += 1
        route = .editor
        undoManager?.removeAllActions(withTarget: self)
        lastUndo = nil
        autosave()
    }

    /// "Save changes?" for the open label, answered in the app's dialog (see `DiscardChangesDialog`).
    struct DiscardPrompt: Identifiable {
        let id = UUID()
        let name: String
        /// Leaving the editor: "Exit Without Saving" also throws the changes away.
        var leavesEditor = false
        let proceed: () -> Void
    }

    /// Back from the editor: asks first when there are unsaved changes.
    func leaveEditor() {
        guard isDirty else { return goBack() }
        discardPrompt = DiscardPrompt(name: displayName, leavesEditor: true) { [weak self] in self?.goBack() }
    }

    /// Back to the label as last opened / saved (no undo step: it's a discard).
    func revertToSaved() {
        isReplacingDocument = true
        document = baseline
        isReplacingDocument = false
        isDirty = false
        undoManager?.removeAllActions(withTarget: self)
        lastUndo = nil
        generation += 1
        autosave()
    }

    @Published var discardPrompt: DiscardPrompt?

    /// Runs `action` now when the label has no unsaved changes; otherwise asks first.
    func whenChangesHandled(_ action: @escaping () -> Void) {
        guard isDirty else { return action() }
        discardPrompt = DiscardPrompt(name: displayName, proceed: action)
    }

    /// The dialog's answer: save (then continue if saving worked), discard, or cancel.
    func answerDiscardPrompt(save shouldSave: Bool?) {
        guard let prompt = discardPrompt else { return }
        discardPrompt = nil
        switch shouldSave {
        case true?:
            if fileURL == nil {
                // Let the unsaved-changes sheet finish closing before the name dialog opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.requestSave(then: prompt.proceed) }
            } else if save() {
                prompt.proceed()
            }
        case false?:
            if prompt.leavesEditor { revertToSaved() }
            prompt.proceed()
        case nil: break
        }
    }

    private func noteRecent(_ url: URL) {
        recentURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentURLs.insert(url, at: 0)
        if recentURLs.count > Self.maxRecents { recentURLs.removeLast(recentURLs.count - Self.maxRecents) }
        saveRecents()
    }

    private func saveRecents() {
        defaults.set(recentURLs.map(\.path), forKey: Keys.recents)
    }

    private func autosave() {
        if let data = try? JSONEncoder().encode(document) { defaults.set(data, forKey: Keys.document) }
        persistFileState()
    }

    /// Changes a template's category on disk. If it's the open label, the editor follows without
    /// marking it edited (other unsaved changes stay unsaved).
    func setCategory(_ category: String, of url: URL) throws {
        let clean = category.trimmingCharacters(in: .whitespacesAndNewlines)
        try TemplateFiles.setCategory(clean, of: url)
        if url.standardizedFileURL == fileURL?.standardizedFileURL {
            isReplacingDocument = true
            document.mediaCategory = clean
            isReplacingDocument = false
            baseline.mediaCategory = clean
            isDirty = document != baseline
            persistFileState()
        }
        noteRecent(url)
    }

    private func persistFileState() {
        defaults.set(fileURL?.path, forKey: Keys.fileURL)
        if let data = try? JSONEncoder().encode(baseline) { defaults.set(data, forKey: Keys.baseline) }
    }
}

enum HomeTab: String, CaseIterable, Identifiable {
    /// Tab bar order: Dashboard sits in the middle.
    case templates, batch, dashboard, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .templates: "Templates"
        case .dashboard: "Dashboard"
        case .batch: "Batch"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .templates: "square.grid.2x2"
        case .dashboard: "rectangle.3.group"
        case .batch: "tablecells"
        case .history: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum AppRoute: Hashable {
    case home(HomeTab)
    case newLabel
    case editor
}
