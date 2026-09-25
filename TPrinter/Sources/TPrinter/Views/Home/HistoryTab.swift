import SwiftUI
import UniformTypeIdentifiers

/// Everything printed: a range switch, an overview (labels per day, totals, success rate, most
/// printed), status / type filters, a day-by-day timeline and a detail panel for the selected job with
/// the label exactly as sent.
struct HistoryTab: View {
    @EnvironmentObject private var history: PrintHistory
    @EnvironmentObject private var printCenter: PrintCenter
    @EnvironmentObject private var session: LabelSession
    @AppStorage("historyRange") private var range = Range.week.rawValue
    @State private var status: StatusFilter = .all
    @State private var kind: PrintRecord.Kind?
    @State private var query = ""
    @State private var selectedID: PrintRecord.ID?
    @State private var confirmsClear = false
    /// Decoded "as printed" labels, keyed by record id (decoding once, not per redraw).
    @State private var printed: [PrintRecord.ID: LabelDocument] = [:]

    enum Range: Int, CaseIterable, Identifiable {
        case today = 1, week = 7, month = 30, all = 0
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .today: "Today"
            case .week: "7 days"
            case .month: "30 days"
            case .all: "All"
            }
        }

        func contains(_ date: Date) -> Bool {
            guard self != .all else { return true }
            let start = Calendar.current.date(byAdding: .day, value: -(rawValue - 1), to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
            return date >= start
        }
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All", printed = "Printed", problems = "Problems"
        var id: String { rawValue }
        func matches(_ record: PrintRecord) -> Bool {
            switch self {
            case .all: true
            case .printed: record.result == .printed
            case .problems: record.result != .printed
            }
        }
    }

    // MARK: Data

    private var currentRange: Range { Range(rawValue: range) ?? .week }

    /// Jobs in the chosen range (the overview uses these).
    private var inRange: [PrintRecord] { history.records.filter { currentRange.contains($0.date) } }

    /// Jobs in range after status, type and search filters (the timeline).
    private var shown: [PrintRecord] {
        inRange.filter { record in
            status.matches(record) && (kind == nil || record.jobKind == kind)
                && (query.isEmpty || "\(record.templateName) \(record.mediaName) \(record.printer)".localizedCaseInsensitiveContains(query))
        }
    }

    private var days: [(day: Date, records: [PrintRecord])] {
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    private var selected: PrintRecord? {
        shown.first { $0.id == selectedID } ?? shown.first
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    header
                    overview
                    filters
                    if shown.isEmpty {
                        emptyState
                    } else {
                        ForEach(days, id: \.day) { group in
                            Section {
                                dayRows(group.records)
                            } header: {
                                dayHeader(group.day, group.records)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 110)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if !history.records.isEmpty {
                Divider()
                detailPanel
                    .frame(width: 330)
            }
        }
        .task(id: history.records.map(\.id)) { decodeTemplates() }
        .sheet(isPresented: $confirmsClear) {
            ModernDialog(icon: "clock.arrow.circlepath", tone: .danger, title: "Clear all print history?",
                         message: "Printed labels aren't affected; only this list is emptied.",
                         primary: .init("Clear History", role: .destructive) { history.clear() })
        }
    }

    // MARK: Header / overview

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("History").font(.system(size: 26, weight: .bold))
                Text("Every label you print, with the exact design that was sent.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                .disabled(inRange.isEmpty)
                .help("Save these jobs as a spreadsheet")
            Button("Clear…", role: .destructive) { confirmsClear = true }
                .disabled(history.records.isEmpty)
        }
        .controlSize(.large)
    }

    private var overview: some View {
        let jobs = inRange
        let labels = jobs.filter { $0.result == .printed }.map(\.labels).reduce(0, +)
        let problems = jobs.filter { $0.result != .printed }.count
        let rate = jobs.isEmpty ? 100 : Int((Double(jobs.count - problems) / Double(jobs.count) * 100).rounded())
        let top = Dictionary(grouping: jobs.filter { $0.result == .printed }, by: \.templateName)
            .mapValues { $0.map(\.labels).reduce(0, +) }
            .max { $0.value < $1.value }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                chartTile.frame(minWidth: 280, maxWidth: .infinity)
                tile("Labels", "\(labels)", unit: labels == 1 ? "label" : "labels", note: "\(jobs.count) job\(jobs.count == 1 ? "" : "s")")
                tile("Success", "\(rate)", unit: "%", note: problems == 0 ? "No problems" : "\(problems) problem\(problems == 1 ? "" : "s") · review",
                     noteColor: problems == 0 ? nil : .red, action: problems > 0 ? { status = .problems } : nil)
                tile("Most printed", top?.key ?? "—", unit: nil, note: top.map { "\($0.value) labels" } ?? "Nothing yet", valueSize: 17)
            }
            VStack(spacing: 12) {
                chartTile
                HStack(spacing: 12) {
                    tile("Labels", "\(labels)", unit: "labels", note: "\(jobs.count) jobs")
                    tile("Success", "\(rate)", unit: "%", note: "\(problems) problems")
                    tile("Most printed", top?.key ?? "—", unit: nil, note: top.map { "\($0.value) labels" } ?? "", valueSize: 17)
                }
            }
        }
    }

    /// Labels printed per day (14 days, or 30 for the longer ranges), today highlighted.
    private var chartTile: some View {
        let count = currentRange == .month || currentRange == .all ? 30 : 14
        let today = Calendar.current.startOfDay(for: Date())
        let bars: [(day: Date, labels: Int)] = (0..<count).reversed().map { back in
            let day = Calendar.current.date(byAdding: .day, value: -back, to: today) ?? today
            let labels = history.records
                .filter { $0.result == .printed && Calendar.current.isDate($0.date, inSameDayAs: day) }
                .map(\.labels).reduce(0, +)
            return (day, labels)
        }
        let peak = max(bars.map(\.labels).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LABELS PER DAY").font(.system(size: 10, weight: .bold)).kerning(0.5).foregroundStyle(.secondary)
                Spacer()
                Text("last \(count) days").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(bars, id: \.day) { bar in
                    let isToday = Calendar.current.isDateInToday(bar.day)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isToday ? Color.accentColor : Color.accentColor.opacity(bar.labels > 0 ? 0.35 : 0.12))
                        .frame(height: max(3, CGFloat(bar.labels) / CGFloat(peak) * 58))
                        .frame(maxWidth: .infinity)
                        .help("\(bar.day.formatted(.dateTime.weekday(.abbreviated).day().month())): \(bar.labels) label\(bar.labels == 1 ? "" : "s")")
                }
            }
            .frame(height: 60, alignment: .bottom)
        }
        .padding(14)
        .modifier(HistoryCard())
    }

    private func tile(_ title: String, _ value: String, unit: String?, note: String, noteColor: Color? = nil,
                      valueSize: CGFloat = 26, action: (() -> Void)? = nil) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.5).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: valueSize, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    if let unit { Text(unit).font(.callout).foregroundStyle(.secondary) }
                }
                Text(note).font(.caption.weight(noteColor == nil ? .regular : .semibold)).foregroundStyle(noteColor ?? .secondary).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .modifier(HistoryCard())
            .contentShape(RoundedRectangle(cornerRadius: 14))
        // Only tiles that do something are buttons (a disabled button would look greyed out).
        return Group {
            if let action {
                Button(action: action) { content }.buttonStyle(.plain).help("Show these jobs")
            } else {
                content
            }
        }
    }

    // MARK: Filters

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search template, media or printer", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: 260)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
            ForEach(StatusFilter.allCases) { item in
                HistoryChip(title: item.rawValue, count: inRange.filter(item.matches).count, isOn: status == item,
                            dot: item == .problems ? .red : nil) { status = item }
            }
            Spacer(minLength: 8)
            HistoryChip(title: "All types", count: nil, isOn: kind == nil) { kind = nil }
            ForEach(PrintRecord.Kind.allCases) { item in
                HistoryChip(title: item.title, count: nil, isOn: kind == item) { kind = kind == item ? nil : item }
            }
        }
    }

    // MARK: Timeline

    private func dayHeader(_ day: Date, _ records: [PrintRecord]) -> some View {
        let labels = records.filter { $0.result == .printed }.map(\.labels).reduce(0, +)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(dayTitle(day)).font(.system(size: 14, weight: .semibold))
            Text("\(records.count) job\(records.count == 1 ? "" : "s") · \(labels) label\(labels == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .padding(.vertical, 6)
        .background(Theme.appBackground)
    }

    private func dayRows(_ records: [PrintRecord]) -> some View {
        VStack(spacing: 0) {
            ForEach(records) { record in
                HistoryRow(record: record, document: printed[record.id], canPrint: printCenter.canPrint,
                           isSelected: record.id == selected?.id) {
                    selectedID = record.id
                } reprint: {
                    reprint(record, copies: nil)
                } open: {
                    if let document = printed[record.id] { session.openCopy(of: document) }
                } menu: {
                    actions(record)
                }
                .contextMenu { actions(record) }
                if record.id != records.last?.id { Divider().padding(.leading, 90) }
            }
        }
        .modifier(HistoryCard())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(history.records.isEmpty ? "Nothing printed yet" : "No jobs match").font(.title3.weight(.semibold))
            Text(history.records.isEmpty
                 ? "Each print shows up here with the label as it was printed, so you can reprint it later."
                 : "Try another range, search or filter.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if !history.records.isEmpty {
                Button("Show Everything") { status = .all; kind = nil; query = ""; range = Range.all.rawValue }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let record = selected {
            HistoryDetail(record: record, document: printed[record.id], canPrint: printCenter.canPrint) { copies in
                reprint(record, copies: copies)
            } open: {
                if let document = printed[record.id] { session.openCopy(of: document) }
            } export: {
                guard let document = printed[record.id] else { return }
                do { try TemplateFiles.exportImage(document, name: record.templateName) }
                catch { session.errorMessage = error.localizedDescription }
            } remove: {
                history.delete(record.id)
                selectedID = nil
            }
            .id(record.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                Text("Select a job to see what was printed.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ record: PrintRecord) -> some View {
        Button(record.result == .printed ? "Reprint" : "Retry") { reprint(record, copies: nil) }
            .disabled(printed[record.id] == nil || !printCenter.canPrint)
        Button("Open in Editor") {
            if let document = printed[record.id] { session.openCopy(of: document) }
        }
        .disabled(printed[record.id] == nil)
        Button("Export Image…") {
            guard let document = printed[record.id] else { return }
            do { try TemplateFiles.exportImage(document, name: record.templateName) }
            catch { session.errorMessage = error.localizedDescription }
        }
        .disabled(printed[record.id] == nil)
        Divider()
        Button("Remove from History", role: .destructive) { history.delete(record.id) }
    }

    /// `copies` nil = as many labels as the original job.
    private func reprint(_ record: PrintRecord, copies: Int?) {
        guard var document = printed[record.id] else { return }
        document.copies = copies ?? max(1, record.labels / max(document.arrangement.cellCount, 1))
        printCenter.printLabel(document, name: record.templateName)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "TPrinter history \(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func field(_ text: String) -> String { "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        formatter.timeZone = .current
        var lines = ["Date,Template,Labels,Media,Printer,Result,Type,Detail"]
        for record in inRange {
            lines.append([field(formatter.string(from: record.date)), field(record.templateName), "\(record.labels)",
                          field(record.mediaName), field(record.printer), record.result.rawValue, record.jobKind.rawValue,
                          field(record.detail)].joined(separator: ","))
        }
        do { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { session.errorMessage = "Couldn't save the CSV. \(error.localizedDescription)" }
    }

    private func decodeTemplates() {
        var decoded: [PrintRecord.ID: LabelDocument] = [:]
        for record in history.records {
            if let existing = printed[record.id] { decoded[record.id] = existing; continue }
            if let data = record.template, let document = try? LabelTemplate.decode(data) { decoded[record.id] = document }
        }
        printed = decoded
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct HistoryCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct HistoryChip: View {
    let title: String
    let count: Int?
    let isOn: Bool
    var dot: Color? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title)
                if let count { Text("\(count)").foregroundStyle(isOn ? Color.white.opacity(0.75) : Color.secondary) }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(isOn ? Color.white : .primary)
            .background(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? .clear : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Printed / stopped / failed pill.
private struct ResultPill: View {
    let result: PrintRecord.Result
    var body: some View {
        switch result {
        case .printed: StatusPill(state: .ready, text: "Printed")
        case .stopped: StatusPill(state: .busy, text: "Stopped")
        case .failed: StatusPill(state: .problem, text: "Failed")
        }
    }
}

private extension PrintRecord.Result {
    var color: Color {
        switch self {
        case .printed: Theme.ledReady
        case .stopped: Theme.ledBusy
        case .failed: .red
        }
    }
}

/// Timeline row: time, status dot, label as printed, name + tags (+ the reason for problems), result;
/// Reprint / Open / ⋯ on hover. Click selects it for the detail panel.
private struct HistoryRow<MenuContent: View>: View {
    let record: PrintRecord
    let document: LabelDocument?
    let canPrint: Bool
    let isSelected: Bool
    var select: () -> Void
    var reprint: () -> Void
    var open: () -> Void
    @ViewBuilder var menu: () -> MenuContent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 58, alignment: .trailing)
            Circle().fill(record.result.color).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2).padding(-2))
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.liner)
                if let document { LabelThumbnail(document: document, maxSize: CGSize(width: 70, height: 36)) }
            }
            .frame(width: 80, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.templateName).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    tag("\(record.labels) label\(record.labels == 1 ? "" : "s")")
                    if !record.mediaName.isEmpty { tag(record.mediaName) }
                    tag(record.printer)
                    switch record.jobKind {
                    case .batch: tag("Batch · CSV", color: .purple)
                    case .pdf: tag("PDF", color: .pink)
                    case .single: EmptyView()
                    }
                }
                if record.result != .printed {
                    Label(record.result == .stopped ? (record.detail.isEmpty ? "Stopped before the end" : record.detail)
                          : (record.detail.isEmpty ? "The job didn't finish" : record.detail),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(record.result == .failed ? .red : Theme.ledBusy).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            ResultPill(result: record.result)
            HStack(spacing: 3) {
                Button(action: reprint) { Image(systemName: "arrow.clockwise") }
                    .disabled(document == nil || !canPrint)
                    .help(record.result == .printed ? "Reprint" : "Retry")
                Button(action: open) { Image(systemName: "pencil") }
                    .disabled(document == nil)
                    .help("Open in Editor")
                Menu { menu() } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isSelected ? 1 : 0.35)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    private var background: some View {
        ZStack {
            if record.result != .printed {
                LinearGradient(colors: [record.result.color.opacity(0.1), .clear], startPoint: .leading, endPoint: .center)
            }
            if isSelected { Color.accentColor.opacity(0.12) } else if hovering { Color.primary.opacity(0.04) }
        }
    }

    private func tag(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color ?? .secondary)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((color ?? .primary).opacity(color == nil ? 0.06 : 0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The selected job: the label exactly as sent, details, reprint with copies, open / export / remove.
private struct HistoryDetail: View {
    let record: PrintRecord
    let document: LabelDocument?
    let canPrint: Bool
    var reprint: (Int) -> Void
    var open: () -> Void
    var export: () -> Void
    var remove: () -> Void
    @State private var copies = 0

    private var defaultCopies: Int { max(1, record.labels / max(document?.arrangement.cellCount ?? 1, 1)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.liner)
                    if let document {
                        LabelThumbnail(document: document, maxSize: CGSize(width: 270, height: 130), cornerRadius: 5)
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .frame(maxHeight: .infinity)
                    } else {
                        Text("No preview saved for this job").font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                    }
                    Text("Exactly as sent to the printer").font(.system(size: 10.5)).foregroundStyle(Color.black.opacity(0.5)).padding(.bottom, 7)
                }
                .frame(height: 176)
                ResultPill(result: record.result)
                Text(record.templateName).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                if record.result != .printed, !record.detail.isEmpty {
                    Label(record.detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(record.result == .failed ? .red : Theme.ledBusy)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    row("When", record.date.formatted(date: .abbreviated, time: .shortened))
                    row("Labels", "\(record.labels)")
                    row("Media", record.mediaName.isEmpty ? "—" : record.mediaName)
                    if let document { row("Size", MeasureUnit.current.size(document.widthMM, document.heightMM)) }
                    row("Printer", record.printer)
                    row("Type", record.jobKind == .single ? "Single label" : record.jobKind.title)
                }
                .font(.callout)
                Divider()
                HStack {
                    Text("Copies")
                    Spacer()
                    Stepper(value: Binding(get: { copies == 0 ? defaultCopies : copies }, set: { copies = $0 }), in: 1...99) {
                        Text("\(copies == 0 ? defaultCopies : copies)").monospacedDigit().fontWeight(.semibold)
                    }
                }
                Button {
                    reprint(copies == 0 ? defaultCopies : copies)
                } label: {
                    Label(record.result == .printed ? "Reprint" : "Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(document == nil || !canPrint)
                HStack(spacing: 8) {
                    Button(action: open) { Label("Open in Editor", systemImage: "pencil").frame(maxWidth: .infinity) }
                    Button(action: export) { Label("Export PNG", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                }
                .disabled(document == nil)
                Button("Remove from History", role: .destructive, action: remove)
                    .buttonStyle(.borderless).foregroundStyle(.red).font(.callout)
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(1)
        }
    }
}
