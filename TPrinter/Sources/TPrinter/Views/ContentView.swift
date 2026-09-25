import SwiftUI

/// Root: home tabs, the new-label flow, or the full-page editor — plus app-wide alerts, undo wiring,
/// appearance and printer notifications.
struct ContentView: View {
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var notices: NoticeCenter
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @State private var selectedID: LabelElement.ID?

    var body: some View {
        Group {
            switch session.route {
            case .home(let tab): HomeView(tab: tab)
            case .newLabel: NewLabelFlow()
            case .editor: EditorView(selectedID: $selectedID)
            }
        }
        .ignoresSafeArea(.container, edges: .top) // content runs under the hidden title bar
        .animation(.easeOut(duration: 0.18), value: session.route)
        .modifier(TemplateErrorAlert(message: $session.errorMessage))
        .sheet(item: $session.discardPrompt) { prompt in
            ModernDialog(icon: "", title: "Unsaved Changes",
                         message: "You have unsaved changes in “\(prompt.name)”. Do you want to save before "
                            + (prompt.leavesEditor ? "exiting?" : "continuing?"),
                         primary: .init("Save") { session.answerDiscardPrompt(save: true) },
                         secondary: .init(prompt.leavesEditor ? "Exit Without Saving" : "Don't Save", role: .destructive) {
                             session.answerDiscardPrompt(save: false)
                         },
                         onCancel: { session.answerDiscardPrompt(save: nil) },
                         textButtons: true)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $session.showsPDFLabels) { PDFLabelsSheet() }
        .sheet(item: $session.savePrompt) { prompt in
            SaveTemplateDialog(prompt: prompt)
        }
        .modifier(SessionSync(session: session, undoManager: undoManager, selectedID: $selectedID))
        .onAppear { AppAppearance.apply(appearance) }
        .onChange(of: appearance) { _, new in AppAppearance.apply(new) }
        .onChange(of: bluetooth.connection) { old, new in
            switch (old.isReady, new) {
            case (false, .ready(let name)): notices.post(.info, "Printer connected", "\(name) is ready", topic: .printer)
            case (true, .idle), (true, .failed): notices.post(.warning, "Printer disconnected", bluetooth.displayName, topic: .printer)
            default: break
            }
        }
    }
}

private struct TemplateErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.noticeDialog("Something went wrong", message: $message)
    }
}

/// Hands the window's undo manager to the session and keeps the selection valid.
private struct SessionSync: ViewModifier {
    let session: LabelSession
    let undoManager: UndoManager?
    @Binding var selectedID: LabelElement.ID?

    func body(content: Content) -> some View {
        content
            .onAppear { session.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in session.undoManager = manager }
            .onChange(of: session.generation) { _, _ in selectedID = nil }
            // Undo can remove the selected element (e.g. undoing "Add Element").
            .onChange(of: session.document.elements.map(\.id)) { _, ids in
                if let id = selectedID, !ids.contains(id) { selectedID = nil }
            }
    }
}

/// "Save Template": a name, saved in the templates folder (or anywhere via Choose Location…).
private struct SaveTemplateDialog: View {
    let prompt: LabelSession.SavePrompt
    @EnvironmentObject private var session: LabelSession
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The file it will become, e.g. "HAWAS ICE 2" when "HAWAS ICE" is taken.
    private var finalName: String {
        guard !trimmed.isEmpty else { return "" }
        return TemplateFiles.uniqueURL(named: trimmed.replacingOccurrences(of: "/", with: "-"), in: session.templatesFolder)
            .deletingPathExtension().lastPathComponent
    }

    var body: some View {
        ModernDialog(icon: "square.and.arrow.down.fill", tone: .info,
                     title: prompt.isCopy ? "Save a Copy" : "Save Template",
                     message: "Saved in your templates folder, so it's always listed under Templates.",
                     primary: .init("Save", isDisabled: trimmed.isEmpty) { session.saveInTemplatesFolder(named: trimmed) },
                     secondary: .init("Choose Location…") { session.saveWithPanel() },
                     onCancel: { session.savePrompt = nil }) {
            VStack(alignment: .leading, spacing: 6) {
                DialogTextField(placeholder: "Template name", text: $name) {
                    if !trimmed.isEmpty { session.saveInTemplatesFolder(named: trimmed) }
                }
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text(session.templatesFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                    if !finalName.isEmpty, finalName != trimmed {
                        Text("· saves as “\(finalName)”").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { name = prompt.suggestedName }
    }
}
