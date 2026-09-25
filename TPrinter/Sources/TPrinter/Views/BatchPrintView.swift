import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// State for printing the open template once per CSV row. Owned by the app (not the tab) so a
/// loaded CSV survives switching tabs.
@MainActor
final class BatchPrintModel: ObservableObject {
    enum RowStatus { case waiting, printing, printed, skipped }

    @Published private(set) var table: CSVTable?
    @Published private(set) var fileURL: URL?
    @Published var firstRow = 1
    @Published var lastRow = 1
    @Published var previewRow = 1
    @Published private(set) var isPrinting = false
    @Published private(set) var status: String?
    @Published var errorMessage: String?

    /// Rows (0-based) of the current / last run, and copies per row, for per-row status.
    private(set) var runRows: [Int] = []
    private(set) var runCopies = 1
    /// Jobs finished in the last completed run (while running, the printer's queue progress counts).
    private var finishedJobs = 0

    var rowCount: Int { table?.rows.count ?? 0 }
    var selectedRowCount: Int { rowCount == 0 ? 0 : max(0, lastRow - firstRow + 1) }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a CSV file. The first row must contain the column names."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        do {
            let table = try CSVTable.load(url)
            self.table = table
            fileURL = url
            firstRow = 1
            lastRow = max(table.rows.count, 1)
            previewRow = 1
            status = nil
            runRows = []
            finishedJobs = 0
        } catch {
            errorMessage = "Couldn't read “\(url.lastPathComponent)”. \(error.localizedDescription)"
        }
    }

    func clear() {
        guard !isPrinting else { return }
        table = nil
        fileURL = nil
        status = nil
        runRows = []
    }

    func filled(_ template: LabelDocument, row: Int) -> LabelDocument {
        guard let table, table.rows.indices.contains(row - 1) else { return template }
        return LabelFields.fill(template, with: table.record(at: row - 1))
    }

    /// Status of a 1-based row, given the printer's live queue progress.
    func status(ofRow row: Int, queueDone: Int?) -> RowStatus {
        guard let position = runRows.firstIndex(of: row - 1) else {
            return (row < firstRow || row > lastRow) ? .skipped : .waiting
        }
        let done = isPrinting ? (queueDone ?? 0) : finishedJobs
        if done >= (position + 1) * runCopies { return .printed }
        if isPrinting, done >= position * runCopies { return .printing }
        return .waiting
    }

    /// Prints each selected row `copies` times, one label per job (see `LabelPrintService.job`).
    /// - Parameter onFinish: labels printed and the error (nil = all printed, "stopped" = user stopped).
    func start(template: LabelDocument, printer: PrinterBluetoothManager, onFinish: @escaping (Int, String?) -> Void = { _, _ in }) {
        guard let table, selectedRowCount > 0, !isPrinting else { return }
        isPrinting = true
        status = nil
        let copies = max(template.copies, 1)
        let rows = Array((firstRow - 1)..<lastRow)
        runRows = rows
        runCopies = copies
        finishedJobs = 0
        printer.sendQueue(count: rows.count * copies) { index in
            try LabelPrintService.job(for: LabelFields.fill(template, with: table.record(at: rows[index / copies]))
                .advancingCounters(by: index))
        } completion: { [weak self] error in
            guard let self else { return }
            finishedJobs = printer.lastQueueDone
            onFinish(finishedJobs, error)
            isPrinting = false
            if let error {
                status = error == "stopped" ? "Stopped after \(finishedJobs) labels." : "Stopped: \(error)"
            } else {
                status = "Printed \(finishedJobs) labels."
            }
        }
    }

    func stop(printer: PrinterBluetoothManager) { printer.stopQueue() }
}

// MARK: - Batch tab

/// Batch printing: three steps on the left (template, data, print), the filled label and the CSV
/// data on the right.
struct BatchTab: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var printCenter: PrintCenter
    @EnvironmentObject private var model: BatchPrintModel
    @State private var isDropTarget = false

    private var template: LabelDocument { session.document }
    private var fields: [String] { LabelFields.names(in: template) }
    private var missing: Set<String> {
        Set(LabelFields.missing(in: template, columns: model.table?.headers ?? []).map { $0.lowercased() })
    }
    private var totalLabels: Int { model.selectedRowCount * max(template.copies, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(spacing: 14) {
                        templateStep
                        dataStep
                        printStep
                    }
                    .padding(.bottom, 100)
                }
                .scrollIndicators(.never)
                .frame(width: 360)

                VStack(spacing: 14) {
                    preview
                    dataTable
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.bottom, 96)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .frame(maxWidth: 1240, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .noticeDialog("Couldn't read the CSV file", icon: "tablecells.badge.ellipsis", message: $model.errorMessage)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Batch printing").font(.system(size: 26, weight: .bold))
                Text("One label per CSV row. Put {{column}} in any text, barcode or QR content.").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Steps

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(done ? Theme.ledReady : Color.accentColor.opacity(0.15))
                    if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                    else { Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor) }
                }
                .frame(width: 22, height: 22)
                Text(title).font(.headline)
                Spacer()
            }
            content()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var templateStep: some View {
        step(1, "Template", done: !fields.isEmpty) {
            HStack(spacing: 12) {
                RollPreview(document: template, maxSize: CGSize(width: 96, height: 62))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).fontWeight(.semibold).lineLimit(1)
                    Text(template.mediaTitle).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Change…") { session.openWithPanel(); session.showBatch() }
                        Button("Edit") { session.continueEditing() }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.top, 2)
                }
            }
            if fields.isEmpty {
                Label("No fields yet. Add {{column}} to the label, e.g. {{sku}}.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(fields, id: \.self) { field in
                        let ok = model.table == nil || !missing.contains(field.lowercased())
                        Label("{{\(field)}}", systemImage: model.table == nil ? "curlybraces" : ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption.monospaced().weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background((ok ? Color.primary : Theme.ledBusy).opacity(0.08), in: Capsule())
                            .foregroundStyle(model.table == nil ? Color.secondary : ok ? Theme.ledReady : Theme.ledBusy)
                    }
                }
                if model.table != nil, !missing.isEmpty {
                    Text("Amber fields have no matching column and print as written.").font(.caption).foregroundStyle(Theme.ledBusy)
                }
            }
        }
    }

    private var dataStep: some View {
        step(2, "Data", done: model.table != nil) {
            if let table = model.table, let url = model.fileURL {
                HStack(spacing: 12) {
                    Image(systemName: "tablecells.fill").font(.title2).foregroundStyle(.purple)
                        .frame(width: 40, height: 40)
                        .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).fontWeight(.semibold).lineLimit(1)
                        Text("\(table.rows.count) rows, \(table.headers.count) columns").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Choose Another CSV…") { model.chooseFile() }
                        Button("Reload File") { model.load(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Divider()
                        Button("Remove", role: .destructive) { model.clear() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(model.isPrinting)
                }
            } else {
                Button { model.chooseFile() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").font(.title2)
                        Text("Choose a CSV file").fontWeight(.semibold)
                        Text("or drop it here. The first row names the columns.").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .foregroundStyle(isDropTarget ? Color.accentColor : .primary)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { ["csv", "tsv", "txt"].contains($0.pathExtension.lowercased()) }) else { return false }
                    model.load(url)
                    return true
                } isTargeted: { isDropTarget = $0 }
            }
        }
    }

    private var printStep: some View {
        step(3, "Print", done: model.status?.hasPrefix("Printed") == true && !model.isPrinting) {
            VStack(spacing: 8) {
                ValueStepper(title: "From row", value: $model.firstRow.asDouble, range: 1...Double(max(model.lastRow, 1)), unit: nil)
                ValueStepper(title: "To row", value: $model.lastRow.asDouble, range: Double(model.firstRow)...Double(max(model.rowCount, 1)), unit: nil)
                ValueStepper(title: "Copies per row", value: $session.document.copies.asDouble, range: 1...99, unit: nil)
            }
            .disabled(model.table == nil || model.isPrinting)

            HStack(alignment: .firstTextBaseline) {
                Text("Total").foregroundStyle(.secondary)
                Spacer()
                Text("\(totalLabels) label\(totalLabels == 1 ? "" : "s")").font(.title3.weight(.semibold)).monospacedDigit()
            }
            .padding(.top, 2)

            if model.isPrinting, let progress = bluetooth.queueProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    HStack {
                        Text("Label \(min(progress.done + 1, progress.total)) of \(progress.total)").monospacedDigit()
                        Spacer()
                        Button("Stop", role: .destructive) { model.stop(printer: bluetooth) }
                    }
                    .font(.callout)
                }
            } else {
                Button {
                    let name = session.displayName, template = template
                    model.start(template: template, printer: bluetooth) { printed, error in
                        printCenter.recordBatch(name: name, template: template, labels: printed, printed: printed, error: error)
                        session.advanceCounters(by: printed)
                    }
                } label: {
                    Label("Print \(totalLabels) Label\(totalLabels == 1 ? "" : "s")", systemImage: "printer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.table == nil || model.selectedRowCount == 0 || !printCenter.canPrint)

                if let status = model.status {
                    Label(status, systemImage: status.hasPrefix("Printed") ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(status.hasPrefix("Printed") ? Theme.ledReady : Theme.ledBusy)
                } else if !bluetooth.connection.isReady {
                    Label("Connect the printer on the Dashboard.", systemImage: "printer.dotmatrix")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Preview + data

    private var preview: some View {
        VStack(spacing: 12) {
            RollPreview(document: model.filled(template, row: model.previewRow), maxSize: CGSize(width: 440, height: 220))
            HStack(spacing: 12) {
                Button { model.previewRow = max(1, model.previewRow - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.previewRow <= 1)
                Text(model.table == nil ? "Preview with your data after choosing a CSV" : "Row \(model.previewRow) of \(model.rowCount)")
                    .monospacedDigit()
                    .foregroundStyle(model.table == nil ? .secondary : .primary)
                Button { model.previewRow = min(model.rowCount, model.previewRow + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.previewRow >= model.rowCount)
            }
            .buttonStyle(.borderless)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    @ViewBuilder
    private var dataTable: some View {
        if let table = model.table {
            let columnWidth: CGFloat = 150
            VStack(alignment: .leading, spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, values in
                                dataRow(row: index + 1, values: values, columnWidth: columnWidth)
                            }
                        } header: {
                            HStack(spacing: 0) {
                                Text("Row").frame(width: 52, alignment: .leading)
                                ForEach(table.headers, id: \.self) { header in
                                    Text(header)
                                        .foregroundStyle(fields.contains { $0.caseInsensitiveCompare(header) == .orderedSame } ? Color.accentColor : .secondary)
                                        .frame(width: columnWidth, alignment: .leading)
                                        .lineLimit(1)
                                }
                                Text("Status").frame(width: 96, alignment: .leading)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.bar)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
        }
    }

    private func dataRow(row: Int, values: [String], columnWidth: CGFloat) -> some View {
        let status = model.status(ofRow: row, queueDone: bluetooth.queueProgress?.done)
        let isPreview = row == model.previewRow
        return HStack(spacing: 0) {
            Text("\(row)").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).lineLimit(1).frame(width: columnWidth, alignment: .leading)
            }
            Group {
                switch status {
                case .printed: StatusPill(state: .ready, text: "Printed")
                case .printing: StatusPill(state: .busy, text: "Printing")
                case .waiting: model.isPrinting ? AnyView(StatusPill(state: .off, text: "Waiting")) : AnyView(EmptyView())
                case .skipped: AnyView(Text("Skipped").font(.caption).foregroundStyle(.tertiary))
                }
            }
            .frame(width: 96, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(isPreview ? Color.accentColor.opacity(0.14) : .clear)
        .opacity(status == .skipped ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.previewRow = row }
    }
}

/// Wrapping row of small views (field chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(subviews, width: bounds.width).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}
