import SwiftUI

/// Start page: greeting + printer status, the printer card (media, tools), this week's numbers, the main
/// actions, the label you were working on, recent templates and recent prints.
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
            VStack(alignment: .leading, spacing: 20) {
                greeting
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        printerCard.frame(maxWidth: .infinity)
                        statsColumn.frame(width: 360)
                    }
                    VStack(spacing: 16) { printerCard; statsColumn }
                }
                actions
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        workCard.frame(maxWidth: .infinity)
                        activityCard.frame(width: 360)
                    }
                    VStack(spacing: 16) { workCard; activityCard }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 24)
            .padding(.bottom, 110) // room for the floating tab bar
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: session.recentURLs) { recents = session.recentURLs.prefix(4).map(TemplateFile.load) }
        .calibrationDialog(isPresented: $confirmsCalibration, document: session.document,
                           printerReady: bluetooth.connection.isReady) { bluetooth.send($0) }
    }

    // MARK: Data

    private var ready: Bool { bluetooth.connection.isReady }

    /// Labels printed on each of the last 7 days (oldest first; the last is today).
    private var week: [(day: Date, labels: Int)] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).reversed().map { back in
            let day = Calendar.current.date(byAdding: .day, value: -back, to: today) ?? today
            let labels = history.records
                .filter { $0.result == .printed && Calendar.current.isDate($0.date, inSameDayAs: day) }
                .map(\.labels).reduce(0, +)
            return (day, labels)
        }
    }

    private var weekRecords: [PrintRecord] {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
        return history.records.filter { $0.date >= start }
    }

    private var printCounts: [String: Int] {
        history.records.reduce(into: [:]) { counts, record in
            if record.result == .printed { counts[record.templateName, default: 0] += record.labels }
        }
    }

    private var greetingText: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: Greeting

    private var greeting: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greetingText).font(.system(size: 26, weight: .bold))
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(ready ? Theme.ledReady : Theme.ledOff).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder((ready ? Theme.ledReady : Theme.ledOff).opacity(0.3), lineWidth: 3).padding(-3))
                Text(ready ? "\(bluetooth.displayName) ready" : bluetooth.statusText).fontWeight(.semibold)
            }
            .font(.callout)
            .foregroundStyle(ready ? Theme.ledReady : .secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background((ready ? Theme.ledReady : Color.primary).opacity(ready ? 0.13 : 0.06), in: Capsule())
        }
    }

    // MARK: Printer

    private var printerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                PrinterPicture(isReady: ready)
                    .frame(width: 132, height: 110)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text(ready ? "Rongta \(bluetooth.displayName)" : "No printer connected")
                            .font(.system(size: 19, weight: .bold)).lineLimit(1)
                        StatusPill(state: bluetooth.ledState, text: bluetooth.statusText)
                    }
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            spec("Connection", ready ? bluetooth.connectionKind : "—")
                            spec("Resolution", "203 dpi")
                            spec("Last job", history.records.first.map {
                                "\($0.templateName) · \($0.date.formatted(date: .omitted, time: .shortened))"
                            } ?? "None yet")
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                MediaThumbnail(media: loadedMedia, box: CGSize(width: 56, height: 42))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.document.mediaTitle).fontWeight(.semibold)
                    Text("\(MeasureUnit.current.size(session.document.widthMM, session.document.heightMM)) · "
                         + "\(MeasureUnit.current.length(session.document.gapMM)) \(session.document.separation.title.lowercased()) · "
                         + "darkness \(session.document.density) · speed \(session.document.speed)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Change Media") { session.settingsSection = .media; session.route = .home(.settings) }
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                if ready {
                    Button { bluetooth.send(LabelPrintService.testJob()) } label: { Label("Test Print", systemImage: "printer") }
                        .disabled(!printCenter.canPrint)
                    Button { bluetooth.send(LabelPrintService.alignmentJob(for: session.document)) } label: { Label("Alignment Test", systemImage: "viewfinder") }
                        .disabled(!printCenter.canPrint)
                    Button { confirmsCalibration = true } label: { Label("Calibrate", systemImage: "ruler") }
                    Spacer()
                    Button(searching ? "Hide Printers" : "Printers…") { toggleSearch() }.buttonStyle(.borderless)
                    Button("Disconnect") { bluetooth.disconnect() }.buttonStyle(.borderless)
                } else {
                    Button { toggleSearch() } label: { Label(searching ? "Hide Printers" : "Find Printer", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                    Text("Turn the RP310 on, or plug it in by USB. TPrinter reconnects by itself.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if searching {
                Divider()
                PrinterChooser()
            }
        }
        .padding(16)
        .modifier(DashCard())
        .animation(.easeOut(duration: 0.2), value: searching)
    }

    /// The media the open label uses, as a Media (for the thumbnail).
    private var loadedMedia: Media {
        let d = session.document
        return Media(name: d.mediaTitle, category: d.mediaCategory, widthMM: d.widthMM, heightMM: d.heightMM, gapMM: d.gapMM)
    }

    private func spec(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.uppercased()).font(.system(size: 9.5, weight: .bold)).kerning(0.4).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1).monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private func toggleSearch() {
        searching.toggle()
        if searching {
            bluetooth.refreshClassicPrinters()
            bluetooth.startScan()
        } else {
            bluetooth.stopScan()
        }
    }

    // MARK: Stats

    private var statsColumn: some View {
        let days = week
        let total = days.map(\.labels).reduce(0, +)
        let peak = max(days.map(\.labels).max() ?? 0, 1)
        let busiest = days.filter { $0.labels > 0 }.max { $0.labels < $1.labels }
        let records = weekRecords
        let problems = records.filter { $0.result != .printed }.count
        let rate = records.isEmpty ? 100 : Int((Double(records.count - problems) / Double(records.count) * 100).rounded())
        let top = printCounts.max { $0.value < $1.value }
        return VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                statLabel("Labels this week")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(total)").font(.system(size: 28, weight: .bold)).monospacedDigit()
                    Text(total == 1 ? "label" : "labels").foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(days, id: \.day) { day in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Calendar.current.isDateInToday(day.day) ? Color.accentColor : Color.accentColor.opacity(day.labels > 0 ? 0.35 : 0.12))
                            .frame(height: max(3, CGFloat(day.labels) / CGFloat(peak) * 34))
                            .frame(maxWidth: .infinity)
                            .help("\(day.day.formatted(.dateTime.weekday(.wide))): \(day.labels) label\(day.labels == 1 ? "" : "s")")
                    }
                }
                .frame(height: 36, alignment: .bottom)
                Text("\(days.last?.labels ?? 0) today" + (busiest.map { " · busiest: \(dayName($0.day)) (\($0.labels))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(DashCard())
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    statLabel("Success")
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(rate)").font(.system(size: 26, weight: .bold)).monospacedDigit()
                        Text("%").foregroundStyle(.secondary)
                    }
                    Text(problems == 0 ? "No problems" : "\(problems) problem\(problems == 1 ? "" : "s")")
                        .font(.caption.weight(problems == 0 ? .regular : .semibold)).foregroundStyle(problems == 0 ? Color.secondary : .red)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .modifier(DashCard())
                Button { session.route = .home(.history) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        statLabel("Most printed")
                        Text(top?.key ?? "—").font(.system(size: 17, weight: .bold)).lineLimit(1).padding(.top, 4)
                        Text(top.map { "\($0.value) labels · History ›" } ?? "Nothing yet").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .modifier(DashCard())
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func statLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.5).foregroundStyle(.secondary)
    }

    private func dayName(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "today" }
        if Calendar.current.isDateInYesterday(day) { return "yesterday" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start something").font(.system(size: 15, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                MainAction(title: "New label", detail: "Pick media, then design", systemImage: "plus", tint: .accentColor,
                           shortcut: "⌘N", featured: true) { session.startNewLabel() }
                MainAction(title: "Print PDF labels", detail: "Courier labels, one page each", systemImage: "doc.richtext", tint: .pink,
                           shortcut: "⌥⌘P") { session.showsPDFLabels = true }
                MainAction(title: "Batch from CSV", detail: "One label per row", systemImage: "tablecells", tint: .purple,
                           shortcut: "⇧⌘P") { session.showBatch() }
                MainAction(title: "Quick print", detail: "A saved template, now", systemImage: "printer", tint: .orange,
                           shortcut: nil) { quickPrint() }
            }
            FlowLayout(spacing: 8) {
                ToolChip(title: "Open Template…", systemImage: "folder", tint: .indigo) { session.openWithPanel() }
                ToolChip(title: "Define Media", systemImage: "rectangle.split.1x2", tint: .teal) {
                    session.settingsSection = .media
                    session.requestsNewMedia = true
                    session.route = .home(.settings)
                }
                ToolChip(title: "Alignment Test", systemImage: "viewfinder", tint: .green) {
                    bluetooth.send(LabelPrintService.alignmentJob(for: session.document))
                }
                ToolChip(title: "Calibrate Sensor", systemImage: "ruler", tint: .yellow) { confirmsCalibration = true }
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

    // MARK: Work

    private var workCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !session.document.elements.isEmpty {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.liner)
                        LabelThumbnail(document: session.document, maxSize: CGSize(width: 130, height: 64))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    }
                    .frame(width: 150, height: 84)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CONTINUE WHERE YOU LEFT OFF").font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundStyle(Color.accentColor)
                        Text(session.displayName).font(.system(size: 17, weight: .bold)).lineLimit(1)
                        Text(continueDetail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { session.continueEditing() } label: { Label("Open", systemImage: "pencil") }
                    Button { printCenter.printLabel(session.document, name: session.displayName) } label: { Label("Print", systemImage: "printer.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!printCenter.canPrint)
                }
                .controlSize(.large)
                Divider()
            }
            HStack {
                Text("Recent templates").font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("All Templates ›") { session.route = .home(.templates) }.buttonStyle(.link)
            }
            if recents.isEmpty {
                Text("Templates you save (⌘S) appear here.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(recents) { file in
                        RecentTemplateTile(file: file, printed: printCounts[file.url.deletingPathExtension().lastPathComponent, default: 0],
                                           canPrint: printCenter.canPrint) {
                            session.open(file.url)
                        } onPrint: {
                            if let document = file.document {
                                printCenter.printLabel(document, name: file.url.deletingPathExtension().lastPathComponent)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .modifier(DashCard())
    }

    private var continueDetail: String {
        let modified = session.fileURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        let printed = printCounts[session.displayName, default: 0]
        return [session.document.mediaTitle,
                modified.map { "edited \(RecentTemplateRow.edited($0).lowercased())" },
                printed > 0 ? "printed \(printed)×" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent activity").font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("History ›") { session.route = .home(.history) }.buttonStyle(.link)
            }
            if history.records.isEmpty {
                Text("Your prints show up here.").foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(history.records.prefix(5)) { record in
                HStack(spacing: 10) {
                    Circle().fill(record.result == .printed ? Theme.ledReady : record.result == .stopped ? Theme.ledBusy : .red)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.templateName).fontWeight(.semibold).lineLimit(1)
                        Text("\(record.labels) label\(record.labels == 1 ? "" : "s") · \(record.mediaName)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(record.date.formatted(date: Calendar.current.isDateInToday(record.date) ? .omitted : .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                .padding(.vertical, 5)
                if record.id != history.records.prefix(5).last?.id { Divider() }
            }
        }
        .padding(16)
        .modifier(DashCard())
    }
}

// MARK: - Pieces

private struct DashCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
    }
}

/// The RP310 drawn simply: white body, paper slot with a label, window, and the status LED.
private struct PrinterPicture: View {
    let isReady: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: -6) {
                // Label coming out of the slot.
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: 56, height: 30)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            Capsule().fill(Color.black.opacity(0.85)).frame(width: 30, height: 4)
                            HStack(spacing: 1.5) {
                                ForEach([2, 1, 3, 1, 2, 1, 1, 3, 1, 2], id: \.self) { w in
                                    Rectangle().fill(Color.black.opacity(0.85)).frame(width: CGFloat(w), height: 10)
                                }
                            }
                        }
                        .padding(5)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 1)
                    .zIndex(0)
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 96, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.1)))
                    Capsule().fill(Color(red: 0.11, green: 0.13, blue: 0.2)).frame(width: 66, height: 5).offset(x: -15, y: 6)
                    RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.17, green: 0.22, blue: 0.34))
                        .frame(width: 44, height: 15).offset(x: -40, y: 24)
                    Circle().fill(isReady ? Color(red: 0.13, green: 0.79, blue: 0.48) : Color.gray)
                        .frame(width: 8, height: 8)
                        .shadow(color: isReady ? Color.green.opacity(0.8) : .clear, radius: 4)
                        .offset(x: -9, y: 4)
                }
                .zIndex(1)
            }
        }
        .accessibilityLabel(isReady ? "Printer ready" : "Printer not connected")
    }
}

/// One of the four main actions; `featured` is the filled accent tile.
private struct MainAction: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let shortcut: String?
    var featured = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(featured ? Color.white : tint)
                        .frame(width: 40, height: 40)
                        .background((featured ? Color.white.opacity(0.2) : tint.opacity(0.14)), in: RoundedRectangle(cornerRadius: 11))
                    Spacer()
                    if let shortcut {
                        Text(shortcut).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(featured ? Color.white.opacity(0.85) : Color.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(featured ? Color.white.opacity(0.4) : Color.primary.opacity(0.15)))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14.5, weight: .bold))
                    Text(detail).font(.caption).foregroundStyle(featured ? Color.white.opacity(0.85) : .secondary).lineLimit(1)
                }
            }
            .foregroundStyle(featured ? Color.white : .primary)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .background {
                if featured {
                    RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(featured ? .clear : Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.04), radius: hovering ? 12 : 4, y: hovering ? 5 : 1)
            .offset(y: hovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }
}

/// Small secondary action: coloured icon + title.
private struct ToolChip: View {
    let title: String
    let systemImage: String
    let tint: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 22, height: 22).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(hovering ? Color.accentColor : .primary)
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small template card: label on its roll, name and print count; Print / Edit on hover.
private struct RecentTemplateTile: View {
    let file: TemplateFile
    let printed: Int
    let canPrint: Bool
    var onOpen: () -> Void
    var onPrint: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.liner
                if let document = file.document {
                    LabelThumbnail(document: document, maxSize: CGSize(width: 116, height: 54))
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                }
                if hovering {
                    Color.black.opacity(0.3)
                    HStack(spacing: 6) {
                        Button(action: onPrint) { Image(systemName: "printer.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canPrint || file.document == nil)
                            .help("Print")
                        Button(action: onOpen) { Image(systemName: "pencil") }
                            .buttonStyle(.bordered).tint(.white)
                            .help("Edit")
                    }
                    .controlSize(.small)
                }
            }
            .frame(height: 78)
            .clipped()
            HStack {
                Text(file.url.deletingPathExtension().lastPathComponent).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if printed > 0 { Text("\(printed)×").font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onOpen)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(file.url.path)
    }
}
