import AppKit
import SwiftUI

@main
struct TPrinterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window, one label session. No title bar: each screen draws its own header
        // (home header, new-label steps, the editor's floating bar).
        Window("TPrinter", id: "main") {
            ContentView()
                .environmentObject(appDelegate.bluetooth)
                .environmentObject(appDelegate.session)
                .environmentObject(appDelegate.library)
                .environmentObject(appDelegate.history)
                .environmentObject(appDelegate.notices)
                .environmentObject(appDelegate.printCenter)
                .environmentObject(appDelegate.batch)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            TemplateCommands(session: appDelegate.session)
            CommandGroup(before: .sidebar) {
                Button("Show Dashboard") { appDelegate.session.route = .home(.dashboard) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

/// File menu: New / Open / Open Recent / Save / Save As / Batch.
struct TemplateCommands: Commands {
    @ObservedObject var session: LabelSession

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Label…") { session.startNewLabel() }
                .keyboardShortcut("n")
            Button("Open Template…") { session.openWithPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(session.recentURLs, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { session.open(url) }
                }
                if !session.recentURLs.isEmpty { Divider() }
                Button("Clear Menu") { session.clearRecents() }
                    .disabled(session.recentURLs.isEmpty)
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Template") { session.save() }
                .keyboardShortcut("s")
            Button("Save Template As…") { session.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(after: .printItem) {
            Button("Batch Print from CSV…") { session.showBatch() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = LabelSession()
    let bluetooth = PrinterBluetoothManager()
    let library = MediaLibrary()
    let history = PrintHistory()
    let notices = NoticeCenter()
    lazy var printCenter = PrintCenter(printer: bluetooth, history: history, notices: notices)
    /// Batch state lives here so a loaded CSV survives switching tabs.
    let batch = BatchPrintModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) so the window comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Old thumbnails (templates edited or deleted long ago) shouldn't pile up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { ThumbnailCache.prune() }
    }

    /// Double-clicked `.tprlabel` files in Finder, or `open file.tprlabel`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == LabelTemplate.fileExtension }) else { return }
        session.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
