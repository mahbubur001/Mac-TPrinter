import AppKit
import SwiftUI

// MARK: - Window chrome

/// The window has no title bar; put this behind custom headers so they drag the window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Width reserved for the traffic-light buttons at the window's top-left.
let trafficLightInset: CGFloat = 78

/// The app icon (a label on its roll with the status LED), drawn to match AppIcon.icns.
struct AppIconView: View {
    var size: CGFloat = 28

    var body: some View {
        if let icon = NSApp.applicationIconImage, icon.size.width > 0 {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24).fill(Color(hex: 0x2E322F)).frame(width: size, height: size)
        }
    }
}

// MARK: - Printer status

extension PrinterBluetoothManager {
    var displayName: String {
        switch connection {
        case .ready(let name), .connecting(let name), .discovering(let name): name
        default: "No printer"
        }
    }

    var statusText: String {
        if let queue = queueProgress { return "Printing \(min(queue.done + 1, queue.total)) of \(queue.total)" }
        if isSending { return "Printing" }
        if bluetoothState == .unauthorized { return "Bluetooth access is off" }
        switch connection {
        case .ready: return "Ready"
        case .connecting: return "Connecting"
        case .discovering: return "Setting up"
        case .failed: return "Not reachable"
        case .idle: return bluetoothState == .poweredOn ? "Not connected" : "Bluetooth is off"
        }
    }

    var ledState: StatusLED.State {
        if isSending || isQueueRunning { return .busy }
        switch connection {
        case .ready: return .ready
        case .connecting, .discovering: return .busy
        case .failed: return .problem
        case .idle: return .off
        }
    }

    var connectionKind: String {
        if connectedUSBID != nil { return "USB" }
        if connectedClassicAddress != nil { return "Classic Bluetooth" }
        if connectedPrinterID != nil { return "Bluetooth LE" }
        return "—"
    }
}

/// Status as a tinted capsule with the LED ("Ready", "Printing 2 of 3").
struct StatusPill: View {
    let state: StatusLED.State
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            StatusLED(state: state)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(state == .off ? Color.secondary : tint)
    }

    private var tint: Color {
        switch state {
        case .ready: Theme.ledReady
        case .busy: Theme.ledBusy
        case .off: .secondary
        case .problem: .red
        }
    }
}

// MARK: - Tiles & cards

/// A quick action: tinted icon square, title, one line of description.
struct QuickActionTile: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.05), radius: hovering ? 10 : 3, y: hovering ? 4 : 1)
            .offset(y: hovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }
}

/// The label on a short length of its roll: liner strip, slivers of the neighbouring labels.
struct RollPreview: View {
    let document: LabelDocument
    let maxSize: CGSize

    var body: some View {
        let width = CGFloat(document.widthDots), height = CGFloat(document.heightDots)
        // The strip is the label plus a gap and a liner sliver above and below: fit all of it.
        let gapDots = CGFloat(document.gapMM) * dotsPerMM
        let factor = max(min((maxSize.width - 32) / width, (maxSize.height - 30) / (height + 2 * gapDots)), 0.01)
        let labelWidth = width * factor, labelHeight = height * factor
        let corner = max(Theme.labelCornerMM * dotsPerMM * factor, 2)
        let gap = max(document.gapMM * dotsPerMM * factor, 3)

        return VStack(spacing: gap) {
            UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: corner, bottomTrailing: corner))
                .fill(Theme.paper.opacity(0.75)).frame(width: labelWidth, height: 9)
            LabelRenderView(document: document, paper: Theme.paper)
                .scaleEffect(factor, anchor: .topLeading)
                .frame(width: labelWidth, height: labelHeight, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .background(RoundedRectangle(cornerRadius: corner).fill(Theme.paper).shadow(color: .black.opacity(0.14), radius: 1.5, y: 1))
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: corner, topTrailing: corner))
                .fill(Theme.paper.opacity(0.75)).frame(width: labelWidth, height: 9)
        }
        .padding(.horizontal, 12)
        .background(Theme.liner)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .frame(width: maxSize.width, height: maxSize.height)
        .clipped()
        .accessibilityLabel("\(document.widthMM.formatted()) by \(document.heightMM.formatted()) millimetre label")
    }
}

/// A saved template: preview, name, when it was edited and its media.
struct TemplateCard: View {
    let url: URL
    let document: LabelDocument?
    let modified: Date?
    var width: CGFloat = 200
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Group {
                    if let document {
                        RollPreview(document: document, maxSize: CGSize(width: width, height: width * 0.62))
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(Theme.liner.opacity(0.4))
                            .frame(width: width, height: width * 0.62)
                            .overlay(Text("Can't read this file").font(.caption).foregroundStyle(.secondary))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2).opacity(hovering ? 1 : 0))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                        if let document, !LabelFields.names(in: document).isEmpty {
                            Text("CSV").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                .help("Has {{fields}} for batch printing")
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(url.path)
    }

    private var detail: String {
        var parts: [String] = []
        if let modified { parts.append("Edited \(modified.formatted(.relative(presentation: .named)))") }
        if let document { parts.append(document.mediaTitle) }
        return parts.joined(separator: ", ")
    }
}

/// A saved template as a list row: label thumbnail, name, media, when it was edited, chevron.
struct RecentTemplateRow: View {
    let file: TemplateFile
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(file.url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                        if let document = file.document, !LabelFields.names(in: document).isEmpty {
                            Text("CSV").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                .help("Has {{fields}} for batch printing")
                        }
                    }
                    if let document = file.document {
                        Label(document.mediaTitle, systemImage: "doc.text.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    } else {
                        Text("Can't read this file").font(.callout).foregroundStyle(.secondary)
                    }
                    if let modified = file.modified {
                        Text(Self.edited(modified)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hovering ? Color.accentColor : .secondary)
            }
            .padding(10)
            .padding(.trailing, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: hovering ? 1.5 : 1))
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.06), radius: hovering ? 6 : 3, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(file.url.path)
        .contextMenu {
            Button("Open", action: action)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
    }

    /// The label alone on a white tile, scaled to fit.
    private var thumbnail: some View {
        let box = CGSize(width: 96, height: 64)
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.white)
            if let document = file.document {
                LabelThumbnail(document: document, maxSize: CGSize(width: box.width - 12, height: box.height - 12))
            } else {
                Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
            }
        }
        .frame(width: box.width, height: box.height)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.12)))
    }

    /// "Today, 14:32", "Yesterday, 09:10" or "12 Sep 2026".
    static func edited(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Loads template files for cards (document + modification date).
struct TemplateFile: Identifiable, Hashable {
    let url: URL
    let document: LabelDocument?
    let modified: Date?
    var id: URL { url }

    static func load(_ url: URL) -> TemplateFile {
        let document = (try? Data(contentsOf: url)).flatMap { try? LabelTemplate.decode($0) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return TemplateFile(url: url, document: document, modified: modified)
    }
}

// MARK: - Media drawing

/// A media roll drawn to scale: liner strip with two labels and the gap between them.
struct MediaDrawing: View {
    let media: Media
    var maxSize: CGSize = CGSize(width: 150, height: 110)

    var body: some View {
        let across = CGFloat(max(media.labelsAcross, 1))
        let totalWidth = media.widthMM * across + (across - 1) * 2
        let scale = min((maxSize.width - 16) / totalWidth, (maxSize.height - 10) / (media.heightMM * 1.6 + media.gapMM))
        let w = media.widthMM * scale, h = media.heightMM * scale
        let gap = media.separation == .continuous ? 0 : max(media.gapMM * scale, 2)
        return VStack(spacing: gap) {
            row(w: w, h: h, scale: scale, count: Int(across))
            row(w: w, h: h * 0.55, scale: scale, count: Int(across))
        }
        .padding(.horizontal, max(3 * scale, 5))
        .background(Theme.liner)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomTrailing) {
            if media.separation == .blackMark {
                Rectangle().fill(.black).frame(width: 5, height: max(gap, 2)).offset(x: -3, y: -h * 0.55)
            }
        }
    }

    private func row(w: CGFloat, h: CGFloat, scale: CGFloat, count: Int) -> some View {
        HStack(spacing: 2 * scale) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: max(Theme.labelCornerMM * scale, 1.5))
                    .fill(Theme.paper)
                    .frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.1), radius: 0.8, y: 0.5)
            }
        }
    }
}

// MARK: - Inputs

/// "−  12  mm  +" stepper for millimetre / count values.
struct ValueStepper: View {
    let title: String
    var systemImage: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String? = "mm"

    var body: some View {
        HStack {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
            Spacer()
            HStack(spacing: 0) {
                Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus").frame(width: 26, height: 24) }
                    .disabled(value <= range.lowerBound)
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.center)
                    .frame(width: 46)
                    .textFieldStyle(.plain)
                    .monospacedDigit()
                    .onSubmit { value = min(max(value, range.lowerBound), range.upperBound) }
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary).padding(.trailing, 2) }
                Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus").frame(width: 26, height: 24) }
                    .disabled(value >= range.upperBound)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// Int convenience for ValueStepper.
extension Binding where Value == Int {
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Int($0.rounded()) })
    }
}
