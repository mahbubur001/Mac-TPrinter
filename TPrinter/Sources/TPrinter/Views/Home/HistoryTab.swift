import SwiftUI

/// Everything printed: summary, search + filters, grouped by day, each job with the label as printed.
struct HistoryTab: View {
    @EnvironmentObject private var history: PrintHistory
    @EnvironmentObject private var printCenter: PrintCenter
    @EnvironmentObject private var session: LabelSession
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var confirmsClear = false
    /// Decoded "as printed" labels, keyed by record id (decoding once, not per redraw).
    @State private var printed: [PrintRecord.ID: LabelDocument] = [:]

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", today = "Today", batches = "Batches", problems = "Problems"
        var id: String { rawValue }

        func matches(_ record: PrintRecord) -> Bool {
            switch self {
            case .all: true
            case .today: Calendar.current.isDateInToday(record.date)
            case .batches: record.wasBatch
            case .problems: record.result != .printed
            }
        }
    }

    private var shown: [PrintRecord] {
        history.records.filter { filter.matches($0) && (query.isEmpty || $0.templateName.localizedCaseInsensitiveContains(query)) }
    }

    /// Records grouped by calendar day, newest first.
    private var days: [(day: Date, records: [PrintRecord])] {
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    private var problemCount: Int { history.records.filter { $0.result != .printed }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                summary
                toolbar
                if shown.isEmpty {
                    emptyState
                } else {
                    ForEach(days, id: \.day) { group in
                        daySection(group.day, group.records)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 110)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: history.records.map(\.id)) { decodeTemplates() }
        .sheet(isPresented: $confirmsClear) {
            ModernDialog(icon: "clock.arrow.circlepath", tone: .danger, title: "Clear all print history?",
                         message: "Printed labels aren't affected; only this list is emptied.",
                         primary: .init("Clear History", role: .destructive) { history.clear() })
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("History").font(.system(size: 26, weight: .bold))
                Text("Every label you print, with the exact design that was sent.").foregroundStyle(.secondary)
            }
            Spacer()
            if !history.records.isEmpty {
                Button("Clear History…") { confirmsClear = true }
            }
        }
        .controlSize(.large)
    }

    private var summary: some View {
        HStack(spacing: 0) {
            stat("Today", history.labelsPrintedToday, unit: "labels")
            Divider().frame(height: 36)
            stat("Last 7 days", history.labelsPrintedThisWeek, unit: "labels")
            Divider().frame(height: 36)
            stat("All time", history.labelsPrintedTotal, unit: "labels")
            Divider().frame(height: 36)
            stat("Problems", problemCount, unit: problemCount == 1 ? "job" : "jobs", tint: problemCount > 0 ? Theme.ledBusy : nil)
        }
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func stat(_ title: String, _ value: Int, unit: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)").font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(tint ?? .primary)
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by template", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .frame(maxWidth: 260)
            ForEach(Filter.allCases) { item in
                let count = history.records.filter(item.matches).count
                FilterChip(title: "\(item.rawValue) \(count)", isOn: filter == item) { filter = item }
            }
            Spacer()
        }
    }

    private func daySection(_ day: Date, _ records: [PrintRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayTitle(day)).font(.headline)
                let labels = records.filter { $0.result == .printed }.map(\.labels).reduce(0, +)
                Text("\(records.count) job\(records.count == 1 ? "" : "s"), \(labels) label\(labels == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(records) { record in
                    HistoryRow(record: record, document: printed[record.id], canPrint: printCenter.canPrint) {
                        reprint(record)
                    } menu: { actions(record) }
                        .contextMenu { actions(record) }
                    if record.id != records.last?.id { Divider().padding(.leading, 104) }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(history.records.isEmpty ? "Nothing printed yet" : "No jobs match").font(.title3.weight(.semibold))
            Text(history.records.isEmpty
                 ? "Each print shows up here with the label as it was printed, so you can reprint it later."
                 : "Try another search, or show all jobs.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if !history.records.isEmpty {
                Button("Clear Filters") { filter = .all; query = "" }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ record: PrintRecord) -> some View {
        Button(record.result == .printed ? "Reprint" : "Retry") { reprint(record) }
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

    private func reprint(_ record: PrintRecord) {
        guard var document = printed[record.id] else { return }
        // Same number of labels as the original job.
        document.copies = max(1, record.labels / max(document.arrangement.cellCount, 1))
        printCenter.printLabel(document, name: record.templateName)
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

/// One job: the label as printed, what and where, when, result; Reprint and ⋯ on hover.
private struct HistoryRow<MenuContent: View>: View {
    let record: PrintRecord
    let document: LabelDocument?
    let canPrint: Bool
    var reprint: () -> Void
    @ViewBuilder var menu: () -> MenuContent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let document {
                    RollPreview(document: document, maxSize: CGSize(width: 76, height: 50))
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.liner.opacity(0.4)).frame(width: 76, height: 50)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.templateName).font(.headline).lineLimit(1)
                    if record.wasBatch {
                        Text("CSV").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.purple)
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            status.frame(width: 96, alignment: .leading)
            HStack(spacing: 4) {
                Button(action: reprint) { Image(systemName: "arrow.clockwise") }
                    .disabled(document == nil || !canPrint)
                    .help(record.result == .printed ? "Reprint" : "Retry")
                Menu { menu() } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.4)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var detail: String {
        var parts = ["\(record.labels) label\(record.labels == 1 ? "" : "s") on \(record.printer)", record.mediaName]
        if record.result == .failed, !record.detail.isEmpty { parts.append(record.detail) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var status: some View {
        switch record.result {
        case .printed: StatusPill(state: .ready, text: "Printed")
        case .stopped: StatusPill(state: .busy, text: "Stopped")
        case .failed: StatusPill(state: .problem, text: "Failed").help(record.detail)
        }
    }
}
