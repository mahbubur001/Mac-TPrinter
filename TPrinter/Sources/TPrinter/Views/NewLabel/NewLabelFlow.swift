import SwiftUI

/// New label: 1. choose the media in the printer, 2. arrange labels, 3. open the editor.
struct NewLabelFlow: View {
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var library: MediaLibrary
    @AppStorage("defaultPrintMethod") private var defaultMethod = PrintMethod.image.rawValue

    @State private var step = 1
    @State private var category: String?
    @State private var chosen: Media?
    @State private var arrangement = LabelArrangement.single
    @State private var labelWidth = 30.0
    @State private var labelHeight = 15.0
    @State private var newMedia: Media?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    if step == 1 { mediaStep } else { arrangementStep }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(Theme.appBackground)
        .sheet(item: $newMedia) { _ in
            ScrollView {
                MediaEditor(media: Binding($newMedia)!, isNew: true, categories: library.categories) { saved in
                    library.save(saved)
                    choose(saved)
                    newMedia = nil
                }
                .padding(24)
            }
            .frame(width: 620, height: 700)
            .overlay(alignment: .topTrailing) {
                Button("Cancel") { newMedia = nil }.keyboardShortcut(.cancelAction).padding(16)
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 16) {
            Text("New label").font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 8) {
                stepBadge(1, "Media")
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 28, height: 1.5)
                stepBadge(2, "Arrangement")
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 28, height: 1.5)
                stepBadge(3, "Design")
            }
            Spacer()
            Button("Cancel") { session.goBack() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(WindowDragArea())
        .background(.bar)
    }

    private func stepBadge(_ number: Int, _ title: String) -> some View {
        let done = number < step, current = number == step
        return HStack(spacing: 6) {
            ZStack {
                Circle().fill(done ? Theme.ledReady : current ? Color.accentColor : .clear)
                Circle().strokeBorder(done || current ? .clear : Color.secondary.opacity(0.4), lineWidth: 1.5)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(current ? .white : .secondary) }
            }
            .frame(width: 22, height: 22)
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(current ? .primary : .secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { step = 1 }.opacity(step == 1 ? 0 : 1).disabled(step == 1)
            Spacer()
            Text(hint).foregroundStyle(.secondary)
            Spacer()
            Button(step == 1 ? "Continue" : "Open Editor") {
                if step == 1 { step = 2 } else { finish() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(chosen == nil)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var hint: String {
        guard let chosen else { return "Select the media loaded in your printer" }
        return step == 1 ? "\(chosen.name) selected" : "\(arrangement.cellCount) label\(arrangement.cellCount == 1 ? "" : "s") per printed row"
    }

    // MARK: Step 1 — media

    private var mediaStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose the media in your printer").font(.title2.weight(.semibold))
                Text("Label size, gap and darkness come from the media. You can change them later.").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                FilterChip(title: "All categories", isOn: category == nil) { category = nil }
                ForEach(library.categories, id: \.self) { name in
                    FilterChip(title: name, isOn: category == name) { category = name }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 18)], spacing: 18) {
                ForEach(library.media(inCategory: category)) { media in
                    mediaCard(media)
                }
                Button {
                    newMedia = Media(name: "", category: category ?? library.categories.first ?? "General", widthMM: 40, heightMM: 25)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.title2)
                        Text("Create new media").fontWeight(.semibold)
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 268)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func mediaCard(_ media: Media) -> some View {
        let isOn = chosen?.id == media.id
        return Button { choose(media) } label: {
            VStack(alignment: .leading, spacing: 12) {
                MediaDrawing(media: media, maxSize: CGSize(width: 210, height: 128))
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.name).font(.headline).lineLimit(1)
                    Text(media.detailText).font(.callout).foregroundStyle(.secondary)
                }
                Text(media.category).font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isOn ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isOn ? 2 : 1))
            .shadow(color: isOn ? Color.accentColor.opacity(0.25) : .clear, radius: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { choose(media); step = 2 })
    }

    private func choose(_ media: Media) {
        chosen = media
        labelWidth = media.widthMM
        labelHeight = media.heightMM
        arrangement = LabelArrangement()
        arrangement.columns = max(media.labelsAcross, 1)
        arrangement.spacingHorizontalMM = media.labelsAcross > 1 ? 2 : 0
    }

    // MARK: Step 2 — arrangement

    private var arrangementStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Label arrangement").font(.title2.weight(.semibold))
                Spacer()
                Text(chosen?.name ?? "").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 22) {
                sheetPreview
                    .frame(minWidth: 280, maxWidth: 380)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 14) {
                    card("Label grid", "square.grid.2x2") {
                        ValueStepper(title: "Rows", value: $arrangement.rows.asDouble, range: 1...10, unit: nil)
                        ValueStepper(title: "Columns", value: $arrangement.columns.asDouble, range: 1...6, unit: nil)
                    }
                    card("Single label size", "square") {
                        ValueStepper(title: "Width", systemImage: "arrow.left.and.right", value: $labelWidth, range: 5...120)
                        ValueStepper(title: "Height", systemImage: "arrow.up.and.down", value: $labelHeight, range: 5...300)
                    }
                    card("Margins", "square.dashed") {
                        ValueStepper(title: "Top", value: $arrangement.marginTopMM, range: 0...20, step: 0.5)
                        ValueStepper(title: "Bottom", value: $arrangement.marginBottomMM, range: 0...20, step: 0.5)
                        ValueStepper(title: "Left", value: $arrangement.marginLeftMM, range: 0...20, step: 0.5)
                        ValueStepper(title: "Right", value: $arrangement.marginRightMM, range: 0...20, step: 0.5)
                    }
                    card("Label spacing", "arrow.left.and.right.square") {
                        ValueStepper(title: "Horizontal", value: $arrangement.spacingHorizontalMM, range: 0...20, step: 0.5)
                        ValueStepper(title: "Vertical", value: $arrangement.spacingVerticalMM, range: 0...20, step: 0.5)
                    }
                }
            }
            Text("You design one label; printing repeats it in every cell. Each printed row is one job.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }

    /// The printed row to scale: liner, margins, cells.
    private var sheetPreview: some View {
        let label = CGSize(width: labelWidth, height: labelHeight)
        let sheet = arrangement.sheetSize(label: label)
        let scale = min(300 / max(sheet.width, 1), 300 / max(sheet.height, 1))
        return VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.liner)
                ForEach(Array(arrangement.cellOrigins(label: label).enumerated()), id: \.offset) { _, origin in
                    RoundedRectangle(cornerRadius: max(Theme.labelCornerMM * scale, 2))
                        .fill(Theme.paper)
                        .frame(width: labelWidth * scale, height: labelHeight * scale)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        .offset(x: origin.x * scale, y: origin.y * scale)
                }
            }
            .frame(width: sheet.width * scale, height: sheet.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("\(MeasureUnit.current.size(labelWidth, labelHeight)) each, row \(MeasureUnit.current.size(sheet.width, sheet.height))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 360)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func finish() {
        guard var media = chosen else { return }
        media.widthMM = labelWidth
        media.heightMM = labelHeight
        session.newDocument(media: media, arrangement: arrangement, printMethod: PrintMethod(rawValue: defaultMethod) ?? .image)
        step = 1
    }
}
