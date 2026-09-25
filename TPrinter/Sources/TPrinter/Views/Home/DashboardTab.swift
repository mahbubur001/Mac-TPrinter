import SwiftUI

/// Printer (status, details, search & connect), quick actions, recent work.
struct DashboardTab: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var history: PrintHistory
    @EnvironmentObject private var printCenter: PrintCenter
    @EnvironmentObject private var notices: NoticeCenter
    @State private var searching = false
    @State private var recents: [TemplateFile] = []
    @State private var confirmsCalibration = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                printerPanel
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick actions").font(.title3.weight(.semibold))
                    quickActions
                }
                recentWork
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 110) // room for the floating tab bar
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: session.recentURLs) { recents = session.recentURLs.prefix(5).map(TemplateFile.load) }
        .calibrationDialog(isPresented: $confirmsCalibration, document: session.document,
                           printerReady: bluetooth.connection.isReady) { bluetooth.send($0) }
    }

    // MARK: Printer

    private var printerPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                printerGlyph
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(bluetooth.connection.isReady ? "Rongta \(bluetooth.displayName)" : bluetooth.displayName)
                            .font(.system(size: 19, weight: .semibold))
                        StatusPill(state: bluetooth.ledState, text: bluetooth.statusText)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                        GridRow {
                            detailLabel("Connection"); detailLabel("Media loaded"); detailLabel("Resolution"); detailLabel("Printed today")
                        }
                        GridRow {
                            Text(bluetooth.connectionKind).fontWeight(.medium)
                            Text(session.document.mediaTitle).fontWeight(.medium)
                            Text("203 dpi, 8 dots/mm").fontWeight(.medium).monospacedDigit()
                            Text("\(history.labelsPrintedToday) label\(history.labelsPrintedToday == 1 ? "" : "s")")
                                .fontWeight(.medium).monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        searching.toggle()
                        if searching {
                            bluetooth.refreshClassicPrinters()
                            bluetooth.startScan()
                        } else {
                            bluetooth.stopScan()
                        }
                    } label: {
                        Label(searching ? "Hide Printers" : "Search Printers", systemImage: "magnifyingglass")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { bluetooth.send(LabelPrintService.testJob()) } label: { Text("Test Print").frame(minWidth: 130) }
                        .disabled(!printCenter.canPrint)
                    if bluetooth.connection.isReady {
                        Button("Disconnect") { bluetooth.disconnect() }.buttonStyle(.link)
                    }
                }
                .controlSize(.large)
            }
            if searching {
                Divider()
                PrinterChooser()
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.07)))
        .animation(.easeOut(duration: 0.2), value: searching)
    }

    private var printerGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05))
            Image(systemName: "printer.fill").font(.system(size: 30)).foregroundStyle(.secondary)
            Circle().fill(bluetooth.connection.isReady ? Theme.ledReady : Theme.ledOff)
                .frame(width: 9, height: 9).offset(x: 22, y: -18)
        }
        .frame(width: 76, height: 64)
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
            QuickActionTile(title: "New label", detail: "Choose media, then design", systemImage: "plus.rectangle", tint: .blue) {
                session.startNewLabel()
            }
            QuickActionTile(title: "Quick print", detail: "Print a saved template now", systemImage: "printer", tint: .orange) {
                quickPrint()
            }
            QuickActionTile(title: "Batch from CSV", detail: "One label per row, with fields", systemImage: "tablecells", tint: .purple) {
                session.showBatch()
            }
            QuickActionTile(title: "Define media", detail: "Add a paper roll size", systemImage: "rectangle.split.1x2", tint: .teal) {
                session.settingsSection = .media
                session.requestsNewMedia = true
                session.route = .home(.settings)
            }
            QuickActionTile(title: "Print an image", detail: "PNG, JPEG or PDF as a label", systemImage: "photo", tint: .pink) {
                imageLabel()
            }
            QuickActionTile(title: "Open template", detail: "Browse .tprlabel files", systemImage: "folder", tint: .indigo) {
                session.openWithPanel()
            }
            QuickActionTile(title: "Alignment test", detail: "Check the print sits on the label", systemImage: "viewfinder", tint: .green) {
                bluetooth.send(LabelPrintService.alignmentJob(for: session.document))
            }
            QuickActionTile(title: "Calibrate sensor", detail: "Measure gaps or black marks", systemImage: "ruler", tint: .yellow) {
                confirmsCalibration = true
            }
        }
    }

    /// Picks a template file and prints it as saved, without opening the editor.
    private func quickPrint() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tprinterLabel]
        panel.directoryURL = session.templatesFolder
        panel.message = "Choose a template to print"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard printCenter.canPrint else {
            notices.post(.warning, "Connect a printer first", "Quick print needs a connected printer.")
            return
        }
        do {
            let document = try LabelTemplate.decode(Data(contentsOf: url))
            printCenter.printLabel(document, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            session.errorMessage = "Couldn't open “\(url.lastPathComponent)”. \(error.localizedDescription)"
        }
    }

    /// A new label (same media as the current one) holding just the chosen image, fitted.
    private func imageLabel() {
        guard let url = ImageImport.chooseFile() else { return }
        var document = session.document
        document.elements = []
        document.copies = 1
        guard let element = try? ImageImport.element(from: url, label: CGSize(width: document.widthMM, height: document.heightMM)) else {
            session.errorMessage = "“\(url.lastPathComponent)” isn't an image TPrinter can read."
            return
        }
        document.elements = [element]
        session.newDocument(size: nil)
        session.perform("Add Image") { $0 = document }
    }

    // MARK: Recent

    private var recentWork: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent work").font(.title3.weight(.semibold))
                Spacer()
                if !recents.isEmpty {
                    Button("See All Templates") { session.route = .home(.templates) }.buttonStyle(.link)
                }
            }
            if recents.isEmpty {
                HStack(spacing: 12) {
                    Button("Continue Current Label") { session.continueEditing() }
                    Text("Templates you save (⌘S) appear here.").foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(recents) { file in
                        RecentTemplateRow(file: file) { session.open(file.url) }
                    }
                }
            }
        }
    }
}
