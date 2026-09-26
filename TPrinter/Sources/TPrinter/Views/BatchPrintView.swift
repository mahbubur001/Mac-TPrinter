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
    /// Print a from–to range instead of the ticked rows.
    @Published var usesRange = false
    /// Unticked rows (0-based). Rows with a missing value start unticked.
    @Published var excluded: Set<Int> = []
    /// Field → CSV column chosen by hand (keys lowercased). Unset fields match a column by name.
    @Published var mapping: [String: String] = [:]
    @Published private(set) var isPrinting = false
    @Published private(set) var status: String?
    @Published var errorMessage: String?

    /// Rows (0-based) of the current / last run, and copies per row, for per-row status.
    private(set) var runRows: [Int] = []
    private(set) var runCopies = 1
    /// Jobs finished in the last completed run (while running, the printer's queue progress counts).
    private var finishedJobs = 0

    var rowCount: Int { table?.rows.count ?? 0 }

    /// Rows (0-based) that will print, in order.
    var printRows: [Int] {
        guard rowCount > 0 else { return [] }
        if usesRange { return Array((max(firstRow, 1) - 1)..<min(lastRow, rowCount)) }
        return (0..<rowCount).filter { !excluded.contains($0) }
    }

    var selectedRowCount: Int { printRows.count }

    // MARK: Fields

    /// The column a field reads from: the one picked by hand, else the column with the same name.
    func column(for field: String) -> String? {
        guard let table else { return nil }
        if let picked = mapping[field.lowercased()], table.headers.contains(picked) { return picked }
        return table.headers.first { $0.caseInsensitiveCompare(field) == .orderedSame }
    }

    func setColumn(_ column: String?, for field: String) {
        mapping[field.lowercased()] = column
    }

    /// Row values keyed by field name (mapped columns), plus every column by its own name.
    func record(at row: Int, fields: [String]) -> [String: String] {
        guard let table, table.rows.indices.contains(row) else { return [:] }
        var record = table.record(at: row)
        for field in fields {
            if let column = column(for: field) { record[field] = table.record(at: row)[column] ?? "" }
        }
        return record
    }

    /// Fields with no value in this row (or no column at all).
    func missingValues(inRow row: Int, fields: [String]) -> [String] {
        let record = record(at: row, fields: fields)
        return fields.filter { column(for: $0) == nil || (record[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func chooseFile(fields: [String] = []) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a CSV file. The first row must contain the column names."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url, fields: fields)
    }

    /// Loads a CSV; rows missing a value for one of `fields` start unticked.
    func load(_ url: URL, fields: [String] = []) {
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
            mapping = mapping.filter { table.headers.contains($0.value) }
            excluded = Set((0..<table.rows.count).filter { row in
                fields.contains { field in
                    guard let column = column(for: field) else { return false } // an unmatched field isn't a row problem
                    return (table.record(at: row)[column] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                }
            })
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
        excluded = []
    }

    func filled(_ template: LabelDocument, row: Int) -> LabelDocument {
        guard let table, table.rows.indices.contains(row - 1) else { return template }
        return LabelFields.fill(template, with: record(at: row - 1, fields: LabelFields.names(in: template)))
    }

    /// Status of a 1-based row, given the printer's live queue progress.
    func status(ofRow row: Int, queueDone: Int?) -> RowStatus {
        guard let position = runRows.firstIndex(of: row - 1) else {
            return printRows.contains(row - 1) ? .waiting : .skipped
        }
        let done = isPrinting ? (queueDone ?? 0) : finishedJobs
        if done >= (position + 1) * runCopies { return .printed }
        if isPrinting, done >= position * runCopies { return .printing }
        return .waiting
    }

    /// Prints each chosen row `copies` times, one label per job (see `LabelPrintService.job`).
    /// - Parameter onFinish: labels printed and the error (nil = all printed, "stopped" = user stopped).
    func start(template: LabelDocument, printer: PrinterBluetoothManager, onFinish: @escaping (Int, String?) -> Void = { _, _ in }) {
        let rows = printRows
        guard table != nil, !rows.isEmpty, !isPrinting else { return }
        isPrinting = true
        status = nil
        let copies = max(template.copies, 1)
        let fields = LabelFields.names(in: template)
        let records = rows.map { record(at: $0, fields: fields) }
        runRows = rows
        runCopies = copies
        finishedJobs = 0
        printer.sendQueue(count: rows.count * copies) { index in
            try LabelPrintService.job(for: LabelFields.fill(template, with: records[index / copies]).advancingCounters(by: index))
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

/// Batch printing: a step tracker, then template / data / field matching on the left, the filled
/// label and the rows (tick which to print) on the right, and a print bar pinned to the bottom.
struct BatchTab: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var printCenter: PrintCenter
    @EnvironmentObject private var model: BatchPrintModel
    @State private var isDropTarget = false
    @State private var rowQuery = ""
    @State private var onlyIssues = false

    private var template: LabelDocument { session.document }
    private var fields: [String] { LabelFields.names(in: template) }
    private var unmatched: [String] { fields.filter { model.column(for: $0) == nil } }
    private var totalLabels: Int { model.selectedRowCount * max(template.copies, 1) }
    private var issueRows: [Int] { (0..<model.rowCount).filter { !model.missingValues(inRow: $0, fields: fields).isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    steps
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 14) {
                            templateCard
                            dataCard
                            if !fields.isEmpty, model.table != nil { fieldsCard }
                        }
                        .frame(width: 320)
                        VStack(spacing: 14) {
                            previewCard
                            if model.table != nil { rowsCard }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .frame(maxWidth: 1260, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            printBar
                .padding(.bottom, 78) // clear of the floating tab bar
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { ["csv", "tsv", "txt"].contains($0.pathExtension.lowercased()) }) else { return false }
            model.load(url, fields: fields)
            return true
        } isTargeted: { isDropTarget = $0 }
        .noticeDialog("Couldn't read the CSV file", icon: "tablecells.badge.ellipsis", message: $model.errorMessage)
    }

    // MARK: Header / steps

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Batch printing").font(.system(size: 26, weight: .bold))
                Text("One label per CSV row. Put {{column}} in any text, barcode or QR content.").foregroundStyle(.secondary)
            }
            Spacer()
            Button { saveSampleCSV() } label: { Label("Sample CSV for This Template", systemImage: "square.and.arrow.down") }
                .disabled(fields.isEmpty)
                .help("Save a CSV with this template's field names as columns, ready to fill in")
        }
        .controlSize(.large)
    }

    private var steps: some View {
        HStack(spacing: 0) {
            stepBadge(1, "Template", detail: session.displayName, state: fields.isEmpty ? .attention : .done)
            stepLine
            stepBadge(2, "Data", detail: model.fileURL.map { "\($0.lastPathComponent) · \(model.rowCount) rows" } ?? "Choose a CSV",
                      state: model.table == nil ? (fields.isEmpty ? .todo : .current) : .done)
            stepLine
            stepBadge(3, "Fields", detail: model.table == nil ? "\(fields.count) field\(fields.count == 1 ? "" : "s")"
                        : "\(fields.count - unmatched.count) of \(fields.count) matched",
                      state: model.table == nil ? .todo : unmatched.isEmpty ? .done : .attention)
            stepLine
            stepBadge(4, "Print", detail: model.isPrinting ? "Printing…" : model.status ?? "\(totalLabels) label\(totalLabels == 1 ? "" : "s") ready",
                      state: model.table == nil ? .todo : model.status?.hasPrefix("Printed") == true ? .done : .current)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .modifier(BatchCard())
    }

    private enum StepState { case todo, current, done, attention }

    private func stepBadge(_ number: Int, _ title: String, detail: String, state: StepState) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(state == .done ? Theme.ledReady : state == .current ? Color.accentColor
                              : state == .attention ? Theme.ledBusy : Color.primary.opacity(0.08))
                if state == .done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                else if state == .attention { Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(state == .current ? .white : .secondary) }
            }
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(Color.accentColor.opacity(state == .current ? 0.25 : 0), lineWidth: 4).padding(-4))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepLine: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 22, height: 2).padding(.horizontal, 8)
    }

    // MARK: Left column

    private func card<Content: View>(_ title: String, icon: String, tint: Color = .accentColor,
                                     @ViewBuilder trailing: () -> some View = { EmptyView() },
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 24, height: 24).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(BatchCard())
    }

    private var templateCard: some View {
        card("Template", icon: "square.grid.2x2") {
            HStack(spacing: 6) {
                Button("Change…") { session.openWithPanel(); session.showBatch() }
                Button("Edit") { session.continueEditing() }
            }
            .controlSize(.small)
        } content: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.liner)
                    LabelThumbnail(document: template, maxSize: CGSize(width: 80, height: 44))
                }
                .frame(width: 92, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).fontWeight(.semibold).lineLimit(1)
                    Text("\(template.mediaTitle) · \(fields.count) field\(fields.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if fields.isEmpty {
                Label("No fields yet. Put {{column}} in a text, barcode or QR, e.g. {{sku}}, then come back.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(Theme.ledBusy)
            }
        }
    }

    private var dataCard: some View {
        card("Data", icon: "tablecells", tint: Theme.ledReady) {
            if model.fileURL != nil {
                Menu {
                    Button("Choose Another CSV…") { model.chooseFile(fields: fields) }
                    if let url = model.fileURL {
                        Button("Reload File") { model.load(url, fields: fields) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Divider()
                    Button("Remove", role: .destructive) { model.clear() }
                } label: { Text("Replace…") }
                .fixedSize().controlSize(.small)
                .disabled(model.isPrinting)
            }
        } content: {
            if let table = model.table, let url = model.fileURL {
                HStack(spacing: 10) {
                    Text("CSV").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.ledReady)
                        .frame(width: 36, height: 36).background(Theme.ledReady.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        Text("\(table.rows.count) rows · \(table.headers.count) columns").font(.caption).foregroundStyle(.secondary)
                    }
                }
                FlowLayout(spacing: 5) {
                    tag(table.delimiterName)
                    tag(table.encodingName)
                    tag("First row = column names")
                }
            } else {
                Button { model.chooseFile(fields: fields) } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").font(.title2)
                        Text("Choose a CSV file").fontWeight(.semibold)
                        Text("or drop it anywhere on this page. The first row names the columns.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 116)
                    .padding(.horizontal, 8)
                    .foregroundStyle(isDropTarget ? Color.accentColor : .primary)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fieldsCard: some View {
        card("Fields", icon: "curlybraces", tint: .purple) {
            Text(unmatched.isEmpty ? "All matched" : "\(unmatched.count) unmatched")
                .font(.caption.weight(.bold)).foregroundStyle(unmatched.isEmpty ? Theme.ledReady : Theme.ledBusy)
        } content: {
            VStack(spacing: 6) {
                ForEach(fields, id: \.self) { field in
                    let column = model.column(for: field)
                    HStack(spacing: 8) {
                        Text("{{\(field)}}").font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Picker("", selection: Binding(get: { column ?? "" }, set: { model.setColumn($0.isEmpty ? nil : $0, for: field) })) {
                            Text("Not in CSV").tag("")
                            ForEach(model.table?.headers ?? [], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        Image(systemName: column == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(column == nil ? Theme.ledBusy : Theme.ledReady)
                    }
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            Text(unmatched.isEmpty ? "Matched by name automatically. Pick another column if a name differs."
                 : "Unmatched fields print as written ({{…}}). Pick the column that holds them.")
                .font(.caption).foregroundStyle(unmatched.isEmpty ? .secondary : Theme.ledBusy)
        }
        .disabled(model.isPrinting)
    }

    // MARK: Preview

    private var previewCard: some View {
        card("Preview", icon: "eye") {
            Text(model.table == nil ? "choose a CSV to see your data" : "exactly what prints for the selected row")
                .font(.caption).foregroundStyle(.secondary)
        } content: {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Theme.liner)
                        VStack {
                            RoundedRectangle(cornerRadius: 6).fill(Theme.paper.opacity(0.55)).frame(height: 18).offset(y: -9)
                            Spacer()
                            RoundedRectangle(cornerRadius: 6).fill(Theme.paper.opacity(0.55)).frame(height: 18).offset(y: 9)
                        }
                        .padding(.horizontal, 60)
                        LabelThumbnail(document: model.filled(template, row: model.previewRow), maxSize: CGSize(width: 420, height: 170), cornerRadius: 6)
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    if model.table != nil {
                        HStack(spacing: 12) {
                            Button { model.previewRow = max(1, model.previewRow - 1) } label: { Image(systemName: "chevron.left") }
                                .disabled(model.previewRow <= 1)
                            Text("Row \(model.previewRow) of \(model.rowCount)").monospacedDigit().fontWeight(.semibold)
                            Button { model.previewRow = min(model.rowCount, model.previewRow + 1) } label: { Image(systemName: "chevron.right") }
                                .disabled(model.previewRow >= model.rowCount)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                if model.table != nil { filmstrip.frame(width: 190) }
            }
        }
    }

    /// The next few rows as small labels.
    private var filmstrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT").font(.system(size: 10, weight: .bold)).kerning(0.5).foregroundStyle(.secondary)
            let next = Array((model.previewRow + 1)...min(model.previewRow + 4, max(model.rowCount, model.previewRow + 1)))
                .filter { $0 <= model.rowCount }
            if next.isEmpty { Text("Last row").font(.caption).foregroundStyle(.tertiary) }
            ForEach(next, id: \.self) { row in
                Button { model.previewRow = row } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4).fill(Theme.liner)
                            LabelThumbnail(document: model.filled(template, row: row), maxSize: CGSize(width: 58, height: 30))
                        }
                        .frame(width: 66, height: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Row \(row)").font(.caption.weight(.semibold))
                            let missing = model.missingValues(inRow: row - 1, fields: fields)
                            Text(missing.isEmpty ? previewText(row) : "Missing \(missing.joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(missing.isEmpty ? Color.secondary : Color.red).lineLimit(1)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func previewText(_ row: Int) -> String {
        let record = model.record(at: row - 1, fields: fields)
        return fields.compactMap { record[$0] }.first { !$0.isEmpty } ?? ""
    }

    // MARK: Rows

    private var shownRows: [Int] {
        let issues = Set(issueRows)
        return (0..<model.rowCount).filter { row in
            (!onlyIssues || issues.contains(row))
                && (rowQuery.isEmpty || (model.table?.rows[row].joined(separator: " ").localizedCaseInsensitiveContains(rowQuery) ?? false))
        }
    }

    private var rowsCard: some View {
        card("Rows", icon: "list.bullet", tint: Theme.ledReady) {
            Text(model.usesRange ? "rows \(model.firstRow)–\(model.lastRow)" : "\(model.selectedRowCount) of \(model.rowCount) selected")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } content: {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter rows", text: $rowQuery).textFieldStyle(.plain)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(maxWidth: 220)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                BatchChip(title: "All", isOn: !onlyIssues) { onlyIssues = false }
                BatchChip(title: "Issues \(issueRows.count)", isOn: onlyIssues, dot: issueRows.isEmpty ? nil : .red) { onlyIssues = true }
                Spacer()
                Button("Select All") { model.excluded = []; model.usesRange = false }
                Button("Select None") { model.excluded = Set(0..<model.rowCount); model.usesRange = false }
            }
            .controlSize(.small)
            rowsTable
        }
        .disabled(model.isPrinting)
    }

    @ViewBuilder
    private var rowsTable: some View {
        if let table = model.table {
            let columnWidth: CGFloat = 150
            let used = Set(fields.compactMap { model.column(for: $0)?.lowercased() })
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(shownRows, id: \.self) { index in
                            tableRow(index, values: table.rows[index], headers: table.headers, used: used, columnWidth: columnWidth)
                        }
                        if shownRows.isEmpty {
                            Text(onlyIssues ? "No rows with issues." : "No rows match.").foregroundStyle(.secondary).padding(14)
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 30)
                            Text("#").frame(width: 40, alignment: .leading)
                            ForEach(table.headers, id: \.self) { header in
                                Text(header)
                                    .foregroundStyle(used.contains(header.lowercased()) ? Color.purple : .secondary)
                                    .frame(width: columnWidth, alignment: .leading)
                                    .lineLimit(1)
                            }
                            Text("Status").frame(width: 96, alignment: .leading)
                        }
                        .font(.system(size: 10.5, weight: .bold)).textCase(.uppercase)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.bar)
                    }
                }
            }
            .frame(height: 320)
            .background(Color.primary.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private func tableRow(_ index: Int, values: [String], headers: [String], used: Set<String>, columnWidth: CGFloat) -> some View {
        let row = index + 1
        let status = model.status(ofRow: row, queueDone: bluetooth.queueProgress?.done)
        let isPreview = row == model.previewRow
        let ticked = model.usesRange ? model.printRows.contains(index) : !model.excluded.contains(index)
        return HStack(spacing: 0) {
            Button {
                model.usesRange = false
                if model.excluded.contains(index) { model.excluded.remove(index) } else { model.excluded.insert(index) }
            } label: {
                Image(systemName: ticked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(ticked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 30, alignment: .leading)
            Text("\(row)").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { column, value in
                let isUsed = used.contains(headers[column].lowercased())
                let empty = isUsed && value.trimmingCharacters(in: .whitespaces).isEmpty
                Text(empty ? "empty" : value)
                    .lineLimit(1)
                    .foregroundStyle(empty ? Color.red : .primary)
                    .fontWeight(empty ? .semibold : .regular)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(empty ? Color.red.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: columnWidth, alignment: .leading)
            }
            Group {
                switch status {
                case .printed: StatusPill(state: .ready, text: "Printed")
                case .printing: StatusPill(state: .busy, text: "Printing")
                case .waiting: model.isPrinting ? AnyView(StatusPill(state: .off, text: "Waiting")) : AnyView(Text("Ready").font(.caption).foregroundStyle(.secondary))
                case .skipped: AnyView(Text("Skipped").font(.caption).foregroundStyle(.tertiary))
                }
            }
            .frame(width: 96, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isPreview ? Color.accentColor.opacity(0.13) : .clear)
        .opacity(status == .skipped ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.previewRow = row }
    }

    // MARK: Print bar

    private var printBar: some View {
        HStack(spacing: 18) {
            barGroup("Rows") {
                Picker("", selection: $model.usesRange) {
                    Text("Selected").tag(false)
                    Text("Range").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if model.usesRange {
                barGroup("From – to") {
                    HStack(spacing: 4) {
                        Stepper(value: $model.firstRow, in: 1...max(model.lastRow, 1)) { Text("\(model.firstRow)").monospacedDigit().frame(minWidth: 22) }
                        Text("–").foregroundStyle(.secondary)
                        Stepper(value: $model.lastRow, in: model.firstRow...max(model.rowCount, 1)) { Text("\(model.lastRow)").monospacedDigit().frame(minWidth: 22) }
                    }
                }
            }
            barGroup("Copies per row") {
                Stepper(value: $session.document.copies, in: 1...99) { Text("\(session.document.copies)").monospacedDigit().frame(minWidth: 22) }
            }
            barGroup("Total") {
                Text("\(totalLabels) label\(totalLabels == 1 ? "" : "s")").font(.system(size: 18, weight: .bold)).monospacedDigit()
            }
            if model.isPrinting, let progress = bluetooth.queueProgress {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Printing \(min(progress.done + 1, progress.total)) of \(progress.total)").fontWeight(.semibold).monospacedDigit()
                        Spacer()
                        Text("about \(estimate(progress.total - progress.done)) left").foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                }
                .frame(maxWidth: .infinity)
                Button("Stop", role: .destructive) { model.stop(printer: bluetooth) }
                    .controlSize(.large)
            } else {
                Spacer()
                if let status = model.status {
                    Label(status, systemImage: status.hasPrefix("Printed") ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(status.hasPrefix("Printed") ? Theme.ledReady : Theme.ledBusy)
                } else if !bluetooth.connection.isReady {
                    Label("Connect the printer on the Dashboard", systemImage: "printer.dotmatrix").foregroundStyle(.secondary)
                } else if totalLabels > 0 {
                    Text("about \(estimate(totalLabels)) on \(bluetooth.displayName)").foregroundStyle(.secondary)
                }
                Button {
                    let name = session.displayName, template = template
                    model.start(template: template, printer: bluetooth) { printed, error in
                        printCenter.recordBatch(name: name, template: template, labels: printed, printed: printed, error: error)
                        session.advanceCounters(by: printed)
                    }
                } label: {
                    Label("Print \(totalLabels) Label\(totalLabels == 1 ? "" : "s")", systemImage: "printer.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.table == nil || totalLabels == 0 || !printCenter.canPrint)
            }
        }
        .font(.callout)
        .disabled(model.table == nil && !model.isPrinting)
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.bar, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal, 28)
        .frame(maxWidth: 1260)
    }

    private func barGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).kerning(0.4).foregroundStyle(.secondary)
            content()
        }
    }

    /// ~1.8 s per label on the RP310 (send + the printer's "job done" reply).
    private func estimate(_ labels: Int) -> String {
        let seconds = Int((Double(labels) * 1.8).rounded())
        return seconds < 90 ? "\(max(seconds, 1)) s" : "\(Int((Double(seconds) / 60).rounded())) min"
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Sample CSV

    private func saveSampleCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(session.displayName) data.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func quoted(_ text: String) -> String { text.contains(",") || text.contains("\"") ? "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" : text }
        let header = fields.map(quoted).joined(separator: ",")
        let example = fields.map { _ in "" }.joined(separator: ",")
        do {
            try "\(header)\n\(example)\n".write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.errorMessage = "Couldn't save the sample. \(error.localizedDescription)"
        }
    }
}

private struct BatchCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct BatchChip: View {
    let title: String
    let isOn: Bool
    var dot: Color? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.white : .primary)
            .background(isOn ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
