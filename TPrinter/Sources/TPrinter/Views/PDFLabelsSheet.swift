import SwiftUI
import UniformTypeIdentifiers

/// "Print PDF Labels": courier parcel labels (Steadfast …) or any PDF / images, one page per label,
/// fitted to the chosen media and printed in one go.
struct PDFLabelsSheet: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var printCenter: PrintCenter
    @Environment(\.dismiss) private var dismiss

    @State private var urls: [URL] = []
    @State private var pages: [PDFLabels.Page] = []
    @State private var fromPage = 1
    @State private var toPage = 1
    @State private var copies = 1
    @State private var isDropTarget = false
    @State private var isPrinting = false
    @State private var status: String?
    @AppStorage("pdfLabels.media") private var mediaName = ""
    @AppStorage("pdfLabels.rotates") private var rotates = true
    @AppStorage("pdfLabels.trims") private var trims = true
    @AppStorage("pdfLabels.lineArt") private var lineArt = true
    @AppStorage("pdfLabels.threshold") private var threshold = 0.6
    @AppStorage("pdfLabels.margin") private var marginMM = 1.0
    /// PDFs from a print window print straight away (with the saved settings) instead of waiting.
    @AppStorage("pdfLabels.autoPrint") private var autoPrint = false
    @State private var autoPrintPending = false

    private var options: PDFLabels.Options {
        PDFLabels.Options(rotates: rotates, trims: trims, lineArt: lineArt, threshold: threshold, marginMM: marginMM)
    }

    /// The chosen media; defaults to the first one big enough for a parcel label.
    private var media: Media? {
        library.media(named: mediaName)
            ?? library.media.first { $0.widthMM >= 70 && $0.heightMM >= 70 }
            ?? library.media.first
    }

    private var selectedPages: [PDFLabels.Page] {
        guard !pages.isEmpty else { return [] }
        let from = min(max(fromPage, 1), pages.count), to = min(max(toPage, from), pages.count)
        return Array(pages[(from - 1)..<to])
    }

    private var labelCount: Int { selectedPages.count * copies }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView { settings.padding(18) }
                    .frame(width: 300)
                Divider()
                preview
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: urls) { _, new in
            pages = PDFLabels.pages(in: new)
            fromPage = 1
            toPage = max(pages.count, 1)
            if autoPrintPending {
                autoPrintPending = false
                if printCenter.canPrint, media != nil, !isPrinting { printAll() }
            }
        }
        .onAppear(perform: takeIncoming)
        .onChange(of: session.incomingPDFs) { _, _ in takeIncoming() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Print PDF Labels").font(.title3.weight(.semibold))
                Text("Courier parcel labels (Steadfast and others) or any PDF or image. Every page prints as one label.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let queue = bluetooth.queueProgress, isPrinting {
                ProgressView(value: Double(queue.done), total: Double(max(queue.total, 1))).frame(width: 160)
                Text("Printing \(min(queue.done + 1, queue.total)) of \(queue.total)…").monospacedDigit()
            } else if let status {
                Text(status).foregroundStyle(.secondary)
            } else if !bluetooth.connection.isReady {
                Label("Connect a printer to print", systemImage: "printer").foregroundStyle(.orange)
            }
            Spacer()
            if isPrinting {
                Button("Stop", role: .destructive) { bluetooth.stopQueue() }
            } else {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    printAll()
                } label: {
                    Label(labelCount == 0 ? "Print" : "Print \(labelCount) Label\(labelCount == 1 ? "" : "s")", systemImage: "printer.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(labelCount == 0 || media == nil || !printCenter.canPrint)
            }
        }
        .font(.callout)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: Settings

    @ViewBuilder
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Files") {
                if urls.isEmpty {
                    dropZone
                } else {
                    ForEach(urls, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(systemName: url.pathExtension.lowercased() == "pdf" ? "doc.fill" : "photo.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                let count = pages.filter { $0.url == url }.count
                                Text(count == 0 ? "Can't read this file" : "\(count) page\(count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(count == 0 ? .red : .secondary)
                            }
                            Spacer()
                            Button { urls.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                    }
                    Button { choose() } label: { Label("Add Files…", systemImage: "plus") }
                }
            }

            section("Label") {
                Picker("Media", selection: Binding(get: { media?.name ?? "" }, set: { mediaName = $0 })) {
                    ForEach(library.media) { Text($0.name).tag($0.name) }
                }
                if let media {
                    Text("\(media.widthMM.formatted()) × \(media.heightMM.formatted()) mm, \(media.gapMM.formatted()) mm \(media.separation.title.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                    if media.widthMM < 50 || media.heightMM < 50 {
                        Label("Small for a courier label. Add your parcel roll in Settings › Media.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Button("Manage Media…") {
                    session.settingsSection = .media
                    session.route = .home(.settings)
                    dismiss()
                }
                .buttonStyle(.link).font(.caption)
            }

            section("Fit") {
                Toggle("Rotate pages to fit the label", isOn: $rotates)
                Toggle("Trim white page margins", isOn: $trims)
                HStack {
                    Text("Margin")
                    Spacer()
                    Stepper(value: $marginMM, in: 0...10, step: 0.5) { Text("\(marginMM.formatted()) mm").monospacedDigit() }
                }
            }
            .toggleStyle(.switch).controlSize(.small)

            section("Print") {
                Picker("", selection: $lineArt) {
                    Text("Sharp black").tag(true)
                    Text("Photo").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack {
                    Text("Darkness")
                    Slider(value: $threshold, in: 0.2...0.95)
                }
                if pages.count > 1 {
                    HStack {
                        Text("Pages")
                        Spacer()
                        Stepper(value: $fromPage, in: 1...max(pages.count, 1)) { Text("\(fromPage)").monospacedDigit() }
                        Text("to")
                        Stepper(value: $toPage, in: 1...max(pages.count, 1)) { Text("\(toPage)").monospacedDigit() }
                    }
                }
                HStack {
                    Text("Copies of each")
                    Spacer()
                    Stepper(value: $copies, in: 1...20) { Text("\(copies)").monospacedDigit() }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.5).foregroundStyle(.secondary)
            content()
        }
    }

    private var dropZone: some View {
        Button { choose() } label: {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                Text("Choose PDF or Images…").fontWeight(.semibold)
                Text("or drop files here").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Color.accentColor.opacity(isDropTarget ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: Preview

    private var preview: some View {
        Group {
            if pages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                    Text("Add a courier label PDF to see how each page prints.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let media {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { number, page in
                            PDFPageCell(page: page, number: number + 1, media: media, options: options,
                                        isIncluded: number + 1 >= fromPage && number + 1 <= toPage)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasDesk)
        .dropDestination(for: URL.self) { dropped, _ in
            let usable = dropped.filter { ["pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            add(usable)
            return !usable.isEmpty
        } isTargeted: { isDropTarget = $0 }
    }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose courier label PDFs or images"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// PDFs handed over by a print window (PDF ▾ › Print with TPrinter).
    private func takeIncoming() {
        guard !session.incomingPDFs.isEmpty else { return }
        let incoming = session.incomingPDFs
        session.incomingPDFs = []
        autoPrintPending = autoPrint && !isPrinting
        status = autoPrint ? nil : "Received \(incoming.map(\.lastPathComponent).joined(separator: ", ")) from the print window."
        add(incoming)
    }

    private func add(_ new: [URL]) {
        urls += new.filter { !urls.contains($0) }
    }

    private struct UnreadablePage: LocalizedError {
        let title: String
        var errorDescription: String? { "Couldn't read “\(title)”." }
    }

    private func printAll() {
        guard let media else { return }
        let chosen = selectedPages, copies = copies, options = options
        guard let first = chosen.first, let sample = PDFLabels.document(for: first, media: media, options: options) else {
            status = "Couldn't read the first page."
            return
        }
        isPrinting = true
        status = nil
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "\(urls.count) PDF files"
        printCenter.printLabels(count: chosen.count * copies, name: name, sample: sample) { index in
            let page = chosen[index / copies]
            guard let document = PDFLabels.document(for: page, media: media, options: options) else { throw UnreadablePage(title: page.title) }
            return document
        } completion: { printed, error in
            isPrinting = false
            switch error {
            case nil: status = "Printed \(printed) label\(printed == 1 ? "" : "s")."
            case "stopped": status = "Stopped after \(printed) label\(printed == 1 ? "" : "s")."
            case let message?: status = "Stopped: \(message)"
            }
        }
    }
}

/// One page as it will print, with its number; dimmed when outside the chosen page range.
private struct PDFPageCell: View {
    let page: PDFLabels.Page
    let number: Int
    let media: Media
    let options: PDFLabels.Options
    let isIncluded: Bool
    @State private var document: LabelDocument?
    @State private var failed = false

    private struct Key: Equatable {
        let page: PDFLabels.Page
        let media: Media
        let options: PDFLabels.Options
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.liner.opacity(0.5))
                if let document {
                    LabelThumbnail(document: document, maxSize: CGSize(width: 150, height: 150))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                } else if failed {
                    Label("Can't read", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 170)
            Text("\(number). \(page.title)").font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .opacity(isIncluded ? 1 : 0.35)
        .task(id: Key(page: page, media: media, options: options)) {
            document = PDFLabels.document(for: page, media: media, options: options)
            failed = document == nil
        }
    }
}
