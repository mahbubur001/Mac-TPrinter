import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, printers, media, printing, files, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .printers: "Printers"
        case .media: "Media"
        case .printing: "Print options"
        case .files: "Templates & files"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Appearance, units, editor, notifications"
        case .printers: "Connect and manage printers"
        case .media: "Paper rolls and label sizes"
        case .printing: "Print method, alignment, print from websites"
        case .files: "Where templates are saved"
        case .about: "Version and support"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .printers: "printer.fill"
        case .media: "rectangle.split.1x2.fill"
        case .printing: "slider.horizontal.3"
        case .files: "folder.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .printers: .blue
        case .media: .teal
        case .printing: .orange
        case .files: .indigo
        case .about: .purple
        }
    }

    /// Sidebar group.
    var group: String {
        switch self {
        case .general: "App"
        case .printers, .media, .printing: "Printing"
        case .files: "Files"
        case .about: "Help"
        }
    }

    /// Words that find this section in the settings search.
    var keywords: String {
        switch self {
        case .general: "appearance theme dark light units unit mm cm inch inches millimetres centimetres measurement editor layers inspector notifications"
        case .printers: "bluetooth connect search rongta rp310 disconnect advanced console log command"
        case .media: "paper roll label size gap black mark continuous category"
        case .printing: "print options method image native tspl alignment calibrate sensor darkness pdf print window website browser steadfast courier"
        case .files: "templates folder recents data"
        case .about: "version build"
        }
    }
}

/// Appearance override stored in UserDefaults ("appearance").
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    /// Set on NSApp: switches instantly, including back to System (preferredColorScheme(nil) doesn't).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static func apply(_ raw: String) {
        NSApp.appearance = (AppAppearance(rawValue: raw) ?? .system).nsAppearance
    }
}

struct SettingsTab: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @State private var query = ""
    /// The setting a search result jumped to, highlighted for a moment.
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    private var results: [SettingsSearch.Entry] { SettingsSearch.matches(query) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Divider()
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else if session.settingsSection == .media {
                // Media scrolls its library and editor itself, so its save bar stays pinned.
                VStack(alignment: .leading, spacing: 18) {
                    SettingsHeader(section: .media)
                    MediaSettings()
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 20)
                .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            SettingsHeader(section: session.settingsSection)
                            Group {
                                switch session.settingsSection {
                                case .general: GeneralSettings()
                                case .printers: PrinterSettings()
                                case .media: MediaSettings()
                                case .printing: PrintingSettings()
                                case .files: FileSettings()
                                case .about: AboutSettings()
                                }
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 26)
                        .padding(.bottom, 110)
                        .frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .environment(\.settingsHighlight, highlighted)
                    .onChange(of: highlighted) { _, id in
                        guard let id else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation(.easeOut(duration: 0.4)) { if highlighted == id { highlighted = nil } }
                        }
                    }
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 24, weight: .bold)).padding(.horizontal, 6)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all settings", text: $query).textFieldStyle(.plain).focused($searchFocused)
                if query.isEmpty {
                    Text("⌘F").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? Color.accentColor : Color.primary.opacity(0.1)))
            .background { Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden() }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["App", "Printing", "Files", "Help"], id: \.self) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.6)
                                .foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.bottom, 2)
                            ForEach(SettingsSection.allCases.filter { $0.group == group }) { section in
                                sidebarRow(section)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .frame(width: 250)
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .background(Color.primary.opacity(0.025))
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isOn = session.settingsSection == section && query.isEmpty
        let needsAttention = section == .printers && !bluetooth.connection.isReady
        return Button {
            query = ""
            session.settingsSection = section
        } label: {
            HStack(spacing: 10) {
                IconTile(systemImage: section.systemImage, tint: section.tint, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title).font(.system(size: 13, weight: .semibold))
                    Text(section.subtitle).font(.caption).foregroundStyle(isOn ? Color.white.opacity(0.85) : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if needsAttention {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(isOn ? .white : Theme.ledBusy)
                        .help("No printer connected")
                }
            }
            .foregroundStyle(isOn ? .white : .primary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(isOn ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    IconTile(systemImage: "magnifyingglass", tint: .accentColor, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Results for “\(query)”").font(.system(size: 22, weight: .bold))
                        Text("\(results.count) setting\(results.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                }
                if results.isEmpty {
                    Text("No settings match. Try “dark”, “inch”, “iCloud” or “calibrate”.").foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(results) { entry in
                        Button {
                            query = ""
                            session.settingsSection = entry.section
                            highlighted = entry.anchor
                        } label: {
                            HStack(spacing: 12) {
                                IconTile(systemImage: entry.section.systemImage, tint: entry.section.tint, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).fontWeight(.semibold)
                                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(entry.section.title) ›").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.08)))
                            .contentShape(RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 110)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Every searchable setting: which page, the anchor to scroll to (a row's title, or a fixed id), and words.
enum SettingsSearch {
    struct Entry: Identifiable {
        let section: SettingsSection
        let anchor: String
        let title: String
        let subtitle: String
        let keywords: String
        var id: String { "\(section.rawValue)/\(anchor)" }
    }

    static let entries: [Entry] = [
        Entry(section: .general, anchor: "appearance", title: "Appearance", subtitle: "Light, dark or follow the system", keywords: "theme dark light system mode"),
        Entry(section: .general, anchor: "Measurements", title: "Units", subtitle: "Millimetres, centimetres or inches", keywords: "unit units mm cm inch inches measurement"),
        Entry(section: .general, anchor: "Layers", title: "Layers panel", subtitle: "Show the layers list in the editor", keywords: "editor panel"),
        Entry(section: .general, anchor: "Inspector", title: "Properties panel", subtitle: "Element settings beside the label", keywords: "inspector editor panel properties"),
        Entry(section: .general, anchor: "Print results", title: "Print notifications", subtitle: "When a print finishes, stops or fails", keywords: "notification notify prints bell"),
        Entry(section: .general, anchor: "Printer connection", title: "Printer notifications", subtitle: "When the printer connects or drops", keywords: "notification notify printer connect disconnect bell"),
        Entry(section: .general, anchor: "Templates", title: "Template notifications", subtitle: "Imports, moves and iCloud", keywords: "notification notify templates bell"),
        Entry(section: .printers, anchor: "current-printer", title: "Current printer", subtitle: "Status, test print, disconnect", keywords: "printer rp310 bluetooth usb connected disconnect test"),
        Entry(section: .printers, anchor: "available-printers", title: "Available printers", subtitle: "Connect another printer", keywords: "search connect pair bluetooth usb printer"),
        Entry(section: .printers, anchor: "console", title: "Printer console", subtitle: "Raw commands and the log (advanced)", keywords: "console log command advanced debug tspl"),
        Entry(section: .media, anchor: "media", title: "Media library", subtitle: "Label sizes, gaps, darkness", keywords: "media paper roll label size gap black mark continuous"),
        Entry(section: .printing, anchor: "print-method", title: "Default print method", subtitle: "Image (exact) or the printer's fonts", keywords: "method image native tspl fonts"),
        Entry(section: .printing, anchor: "“\(PDFService.menuTitle)” in print windows", title: "Print with TPrinter", subtitle: "In every print window's PDF menu", keywords: "pdf print window website browser steadfast courier"),
        Entry(section: .printing, anchor: "Print right away", title: "Print right away", subtitle: "Skip the preview for PDFs from print windows", keywords: "auto pdf preview"),
        Entry(section: .printing, anchor: "Alignment test", title: "Alignment test", subtitle: "Check the print sits on the label", keywords: "alignment offset position test"),
        Entry(section: .printing, anchor: "Label sensor", title: "Calibrate sensor", subtitle: "Find the start of the next label", keywords: "calibrate sensor gap black mark"),
        Entry(section: .files, anchor: "templates-folder", title: "Templates folder", subtitle: "Where templates are saved", keywords: "folder location icloud drive sync documents"),
        Entry(section: .files, anchor: "icloud", title: "iCloud Drive", subtitle: "Sync templates between your Macs", keywords: "icloud sync cloud drive move"),
        Entry(section: .files, anchor: "recents", title: "Recent templates", subtitle: "Clear the recents list", keywords: "recents clear recent"),
        Entry(section: .files, anchor: "Data folder", title: "App data", subtitle: "Media, history and settings on this Mac", keywords: "data history folder support"),
        Entry(section: .files, anchor: "Thumbnail cache", title: "Thumbnail cache", subtitle: "Saved template previews", keywords: "thumbnail cache previews clear"),
        Entry(section: .about, anchor: "about", title: "Version", subtitle: "TPrinter version and build", keywords: "version about build update"),
        Entry(section: .about, anchor: "Log file", title: "Log file", subtitle: "~/Library/Logs/TPrinter.log", keywords: "log support debug"),
    ]

    static func matches(_ query: String) -> [Entry] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let text = "\(entry.title) \(entry.subtitle) \(entry.keywords) \(entry.section.title)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The setting a search result jumped to (its anchor), highlighted for a moment.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

/// Marks a block as a search target: scroll anchor + highlight when a result jumps to it.
private struct SettingsAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsHighlight) private var highlighted

    func body(content: Content) -> some View {
        content
            .background(highlighted == id ? Color.accentColor.opacity(0.14) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(highlighted == id ? 0.6 : 0), lineWidth: 2))
            .id(id)
    }
}

extension View {
    func settingsAnchor(_ id: String) -> some View { modifier(SettingsAnchor(id: id)) }
}

// MARK: - Building blocks

/// Coloured rounded-square icon (System Settings style).
struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.26))
    }
}

private struct SettingsHeader: View {
    let section: SettingsSection
    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: section.systemImage, tint: section.tint, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.system(size: 22, weight: .bold))
                Text(section.subtitle).foregroundStyle(.secondary)
            }
        }
    }
}

/// A titled group of rows with dividers, like System Settings.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4) }
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedRows()) { content }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4) }
        }
    }
}

/// Puts a divider between the rows of a SettingsGroup.
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        ForEach(children) { child in
            child
            if child.id != children.last?.id { Divider().padding(.leading, 14) }
        }
    }
}

/// Label (and optional hint) on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var tint: Color = .accentColor
    /// Search anchor (defaults to the title).
    var anchor: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .settingsAnchor(anchor ?? title)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage(MeasureUnit.defaultsKey) private var unit = MeasureUnit.mm.rawValue
    @AppStorage("editorShowsLayers") private var showsLayers = true
    @AppStorage("editorShowsInspector") private var showsInspector = true
    @AppStorage(NoticeTopic.prints.settingKey) private var notifyPrints = true
    @AppStorage(NoticeTopic.printer.settingKey) private var notifyPrinter = true
    @AppStorage(NoticeTopic.general.settingKey) private var notifyGeneral = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Appearance").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                HStack(spacing: 16) {
                    ForEach(AppAppearance.allCases) { option in
                        AppearanceTile(option: option, isOn: appearance == option.rawValue) { appearance = option.rawValue }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                .settingsAnchor("appearance")
            }

            SettingsGroup(title: "Units", footer: "Sizes, positions, rulers and fields everywhere use this unit. Labels are saved the same way whatever you pick, so templates open fine on any setting.") {
                SettingsRow(title: "Measurements", subtitle: "Example: the 30 × 15 mm label is \((MeasureUnit(rawValue: unit) ?? .mm).size(30, 15))",
                            systemImage: "ruler", tint: .teal) {
                    Picker("", selection: $unit) {
                        ForEach(MeasureUnit.allCases) { Text("\($0.title) (\($0.symbol))").tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }

            SettingsGroup(title: "Editor", footer: "You can also show or hide these panels from the editor's tool rail.") {
                SettingsRow(title: "Layers", subtitle: "Elements on the label, front-most first", systemImage: "square.3.layers.3d", tint: .indigo) {
                    Toggle("", isOn: $showsLayers).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Inspector", subtitle: "Settings for the selected element or the label", systemImage: "sidebar.right") {
                    Toggle("", isOn: $showsInspector).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsGroup(title: "Notifications", footer: "Notifications appear under the bell in the top bar.") {
                SettingsRow(title: "Print results", subtitle: "Finished, stopped and failed jobs", systemImage: "printer", tint: .green) {
                    Toggle("", isOn: $notifyPrints).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Printer connection", subtitle: "When the printer connects or drops", systemImage: "antenna.radiowaves.left.and.right") {
                    Toggle("", isOn: $notifyPrinter).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Templates", subtitle: "Imports, duplicates and other file actions", systemImage: "doc.on.doc", tint: .purple) {
                    Toggle("", isOn: $notifyGeneral).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}

/// A small window mock-up in the theme it selects.
private struct AppearanceTile: View {
    let option: AppAppearance
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    switch option {
                    case .light: mock(dark: false)
                    case .dark: mock(dark: true)
                    case .system:
                        HStack(spacing: 0) { mock(dark: false); mock(dark: true) }
                    }
                }
                .frame(width: 118, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isOn ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isOn ? 3 : 1))
                Text(option.title).font(.callout.weight(isOn ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    private func mock(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(dark ? Color(hex: 0x1F2320) : Color(hex: 0xECEEEA))
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)).frame(width: 44, height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Theme.liner).frame(width: 48, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 2).fill(Theme.paper).padding(.horizontal, 5).padding(.vertical, 6))
            }
            .padding(9)
        }
    }
}

// MARK: - Printers

private struct PrinterSettings: View {
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var session: LabelSession

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "Current printer") {
                HStack(spacing: 14) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "printer.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                            .frame(width: 58, height: 50)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
                        Circle().fill(bluetooth.connection.isReady ? Theme.ledReady : Theme.ledOff).frame(width: 9, height: 9).offset(x: -6, y: 6)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(bluetooth.displayName).font(.headline)
                            StatusPill(state: bluetooth.ledState, text: bluetooth.statusText)
                        }
                        Text(bluetooth.connection.isReady ? "\(bluetooth.connectionKind), 203 dpi, TSPL" : "Pick a printer below to connect")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if bluetooth.connection.isReady {
                        Button("Test Print") { bluetooth.send(LabelPrintService.testJob()) }
                        Button("Disconnect") { bluetooth.disconnect() }
                    }
                }
                .padding(14)
                .settingsAnchor("current-printer")
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Available printers").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        bluetooth.refreshClassicPrinters()
                        bluetooth.startScan()
                    } label: { Label("Search Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 4)
                PrinterChooser()
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                    .settingsAnchor("available-printers")
                Text("Pair new printers in System Settings › Bluetooth, or plug them in by USB. TPrinter reconnects to the last printer automatically.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }

            AdvancedPrinterSettings()
                .settingsAnchor("console")
        }
    }
}

/// Settings › Printers › Advanced: the printer console, collapsed until needed.
private struct AdvancedPrinterSettings: View {
    @AppStorage("showsPrinterConsole") private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text("Advanced").font(.subheadline.weight(.semibold))
                    Text("Printer console").font(.subheadline).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Commands go straight to the printer: a wrong one can feed paper or change its settings. "
                          + "For troubleshooting only.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(12)
                    Divider()
                    ConsoleView()
                        .frame(height: 280)
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                .transition(.opacity)
                Text("Everything here is also written to \(PrinterBluetoothManager.logFileURL.path).")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Printing

private struct PrintingSettings: View {
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var session: LabelSession
    @AppStorage(PDFService.enabledKey) private var pdfServiceEnabled = true
    @AppStorage("pdfLabels.autoPrint") private var autoPrintPDFs = false
    @State private var pdfServiceInstalled = PDFService.isInstalled
    @AppStorage("defaultPrintMethod") private var defaultMethod = PrintMethod.image.rawValue
    @State private var confirmsCalibration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Default print method for new labels").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                HStack(spacing: 12) {
                    MethodTile(title: "Image (exact preview)", detail: "Prints exactly what you see: any font, pictures, effects. Recommended.",
                               systemImage: "photo", isOn: defaultMethod == PrintMethod.image.rawValue) { defaultMethod = PrintMethod.image.rawValue }
                    MethodTile(title: "Native printer fonts", detail: "The printer's built-in fonts: less data, fewer styles. Styled text still goes as an image.",
                               systemImage: "textformat", isOn: defaultMethod == PrintMethod.nativeTSPL.rawValue) { defaultMethod = PrintMethod.nativeTSPL.rawValue }
                }
                .settingsAnchor("print-method")
                Text("Each label can still change this in the editor's Print settings.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            SettingsGroup(title: "Print from websites and other apps",
                          footer: "In any print window (Steadfast, a browser, Preview …) click PDF ▾ at the bottom-left and choose "
                            + "“\(PDFService.menuTitle)”. The labels open in Print PDF Labels with your saved label size and settings.") {
                SettingsRow(title: "“\(PDFService.menuTitle)” in print windows",
                            subtitle: pdfServiceInstalled ? "Added to the PDF ▾ menu" : "Not in the PDF ▾ menu",
                            systemImage: "printer.dotmatrix", tint: .pink) {
                    Toggle("", isOn: Binding {
                        pdfServiceEnabled && pdfServiceInstalled
                    } set: { on in
                        pdfServiceEnabled = on
                        do {
                            if on { try PDFService.install() } else { try PDFService.uninstall() }
                        } catch {
                            session.errorMessage = "Couldn't change the print window menu. \(error.localizedDescription)"
                        }
                        pdfServiceInstalled = PDFService.isInstalled
                    })
                    .toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Print right away", subtitle: "Skip the preview: print as soon as the PDF arrives",
                            systemImage: "bolt.fill", tint: .orange) {
                    Toggle("", isOn: $autoPrintPDFs).toggleStyle(.switch).labelsHidden()
                }
                HStack(spacing: 6) {
                    Text("In a print window:").foregroundStyle(.secondary)
                    Text("PDF ▾").fontWeight(.semibold).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(PDFService.menuTitle).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            SettingsGroup(title: "Alignment", footer: "Every job turns the printer's tear mode off, which keeps labels aligned on the RP310.") {
                SettingsRow(title: "Alignment test", subtitle: "Prints the label outline, a centre cross and a ruler", systemImage: "viewfinder", tint: .green) {
                    Button("Print Test") { bluetooth.send(LabelPrintService.alignmentJob(for: session.document)) }
                        .disabled(!bluetooth.connection.isReady)
                }
                SettingsRow(title: "Label sensor", subtitle: "Measures gaps or black marks for the current media; feeds a few blank labels", systemImage: "ruler", tint: .yellow) {
                    Button("Calibrate…") { confirmsCalibration = true }
                        .disabled(!bluetooth.connection.isReady)
                }
            }
        }
        .calibrationDialog(isPresented: $confirmsCalibration, document: session.document,
                           printerReady: bluetooth.connection.isReady) { bluetooth.send($0) }
    }
}

// MARK: - Files

private struct FileSettings: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var notices: NoticeCenter
    @State private var confirmsClear = false
    @State private var confirmsICloudMove = false

    private var inICloud: Bool { AppStorageLocation.isInICloudDrive(session.templatesFolder) }
    /// Templates (downloaded or still in the cloud) in iCloud Drive › TPrinter Templates.
    private var iCloudCount: Int {
        guard let cloud = AppStorageLocation.iCloudTemplatesFolder else { return 0 }
        return ((try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? [])
            .filter { $0.hasSuffix(".\(LabelTemplate.fileExtension)") || $0.hasSuffix(".\(LabelTemplate.fileExtension).icloud") }.count
    }

    private var templateCount: Int {
        ((try? FileManager.default.contentsOfDirectory(at: session.templatesFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == LabelTemplate.fileExtension }.count
    }

    @State private var cacheSize = FileSettings.size(of: ThumbnailCache.folder)
    private var historySize: String { Self.size(of: AppStorageLocation.directory.appendingPathComponent("history.json")) }

    /// "2.3 MB" for a file or a folder's contents.
    static func size(of url: URL) -> String {
        let fm = FileManager.default
        var total: Int64 = 0
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            for file in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        } else {
            total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "Templates folder", footer: "Save starts here, and the Templates tab lists every template in this folder.") {
                SettingsRow(title: session.templatesFolder.lastPathComponent,
                            subtitle: AppStorageLocation.isInICloudDrive(session.templatesFolder) ? "iCloud Drive" : session.templatesFolder.deletingLastPathComponent().path,
                            systemImage: inICloud ? "icloud.fill" : "folder.fill", anchor: "templates-folder") {
                    HStack {
                        Button("Change…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.directoryURL = session.templatesFolder
                            if panel.runModal() == .OK, let url = panel.url { session.templatesFolder = url }
                        }
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: session.templatesFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(session.templatesFolder)
                        }
                    }
                }
            }
            SettingsGroup(title: "iCloud Drive", footer: inICloud
                          ? "Templates sync to every Mac signed in to your Apple ID. Open TPrinter there and choose this folder in Change…."
                          : AppStorageLocation.iCloudDrive == nil
                              ? "Turn on iCloud Drive in System Settings › Apple Account › iCloud to use this."
                              : "Moves your templates to iCloud Drive › TPrinter Templates so they sync between your Macs.") {
                SettingsRow(title: inICloud ? "Syncing with iCloud Drive" : "Keep templates in iCloud Drive",
                            subtitle: inICloud ? "iCloud Drive › \(session.templatesFolder.lastPathComponent) · \(templateCount) template\(templateCount == 1 ? "" : "s")"
                                               : "Same templates on every Mac, backed up by iCloud",
                            systemImage: "icloud.fill", tint: .cyan, anchor: "icloud") {
                    Button(inICloud ? "Move Back to Documents…" : "Move to iCloud Drive…") { confirmsICloudMove = true }
                        .disabled(!inICloud && AppStorageLocation.iCloudDrive == nil)
                }
                if !inICloud, let cloud = AppStorageLocation.iCloudTemplatesFolder, iCloudCount > 0 {
                    SettingsRow(title: "\(iCloudCount) template\(iCloudCount == 1 ? "" : "s") already in iCloud Drive",
                                subtitle: "From another Mac: use that folder here instead", systemImage: "icloud.and.arrow.down") {
                        Button("Use This Folder") { session.templatesFolder = cloud }
                    }
                }
            }
            SettingsGroup(title: "Recent templates") {
                SettingsRow(title: "\(session.recentURLs.count) recent template\(session.recentURLs.count == 1 ? "" : "s")",
                            subtitle: "Shown on the Dashboard and in Open Recent", systemImage: "clock", anchor: "recents") {
                    Button("Clear Recents…") { confirmsClear = true }.disabled(session.recentURLs.isEmpty)
                }
            }
            SettingsGroup(title: "App data", footer: "Media, print history and settings. Templates are not stored here.") {
                SettingsRow(title: "Data folder", subtitle: "Media, print history (\(historySize)) and settings on this Mac",
                            systemImage: "externaldrive", tint: .indigo) {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppStorageLocation.directory) }
                }
                SettingsRow(title: "Thumbnail cache", subtitle: "Saved template previews (\(cacheSize)); rebuilt when needed",
                            systemImage: "photo.stack", tint: .gray) {
                    Button("Clear") {
                        ThumbnailCache.clear()
                        cacheSize = Self.size(of: ThumbnailCache.folder)
                    }
                }
            }
        }
        .sheet(isPresented: $confirmsICloudMove) {
            let count = templateCount
            ModernDialog(icon: inICloud ? "folder.fill" : "icloud.and.arrow.up.fill", tone: .question,
                         title: inICloud ? "Move templates back to Documents?" : "Move templates to iCloud Drive?",
                         message: "\(count) template\(count == 1 ? "" : "s") move from \(inICloud ? "iCloud Drive › \(session.templatesFolder.lastPathComponent)" : session.templatesFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) to "
                            + (inICloud ? "Documents › TPrinter Templates." : "iCloud Drive › TPrinter Templates.")
                            + " Recent work and the open label keep working. Nothing is deleted.",
                         primary: .init(inICloud ? "Move Back" : "Move to iCloud") { relocate() })
        }
        .sheet(isPresented: $confirmsClear) {
            ModernDialog(icon: "clock.badge.xmark", tone: .danger, title: "Clear the recent templates list?",
                         message: "The template files aren't deleted.",
                         primary: .init("Clear Recents", role: .destructive) { session.clearRecents() })
        }
    }

    private func relocate() {
        let toICloud = !inICloud
        guard let target = toICloud ? AppStorageLocation.iCloudTemplatesFolder : Optional(AppStorageLocation.defaultTemplatesFolder) else { return }
        do {
            let moved = try session.relocateTemplatesFolder(to: target)
            notices.post(.success, toICloud ? "Templates are in iCloud Drive" : "Templates are back in Documents",
                         "\(moved) template\(moved == 1 ? "" : "s") moved")
        } catch {
            session.errorMessage = "Couldn't move the templates. \(error.localizedDescription)"
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @EnvironmentObject private var notices: NoticeCenter
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–" }
    private static let repository = URL(string: "https://github.com/mahbubur001/Mac-TPrinter")!

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 10) {
                AppIconView(size: 88)
                Text("TPrinter").font(.system(size: 24, weight: .bold))
                Text("Version \(version) (\(build)) · label design and printing for Rongta thermal printers")
                    .foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button { NSWorkspace.shared.open(Self.repository) } label: { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([PrinterBluetoothManager.logFileURL]) } label: { Label("Show Log File", systemImage: "doc.text.magnifyingglass") }
                    Button { copySystemInfo() } label: { Label("Copy System Info", systemImage: "doc.on.clipboard") }
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
            .settingsAnchor("about")

            SettingsGroup(title: "Details") {
                SettingsRow(title: "Log file", subtitle: PrinterBluetoothManager.logFileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                            systemImage: "doc.text", tint: .gray) {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([PrinterBluetoothManager.logFileURL]) }
                }
                SettingsRow(title: "License", subtitle: "MIT", systemImage: "checkmark.seal", tint: .green) { EmptyView() }
            }

            SettingsGroup(title: "Supported") {
                SettingsRow(title: "Printers", subtitle: "Rongta RP310 (tested), TSPL label printers", systemImage: "printer") { EmptyView() }
                SettingsRow(title: "Connection", subtitle: "Classic Bluetooth, Bluetooth LE, USB", systemImage: "antenna.radiowaves.left.and.right", tint: .blue) { EmptyView() }
                SettingsRow(title: "Files", subtitle: "Templates (.tprlabel), CSV for batch printing, PNG / JPEG / PDF images", systemImage: "doc", tint: .purple) { EmptyView() }
            }
        }
    }

    /// Version, macOS and printer details for bug reports.
    private func copySystemInfo() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let info = """
        TPrinter \(version) (\(build))
        macOS \(os)
        Printer: \(bluetooth.displayName) · \(bluetooth.connectionKind) · \(bluetooth.statusText)
        Units: \(MeasureUnit.current.title)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
        notices.post(.info, "System info copied", "Paste it into your message or bug report.")
    }
}

// MARK: - Media

/// One print-method choice with a short explanation.
private struct MethodTile: View {
    let title: String
    let detail: String
    let systemImage: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30).background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle").foregroundStyle(isOn ? Color.accentColor : .secondary)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(isOn ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isOn ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isOn ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
