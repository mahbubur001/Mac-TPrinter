import SwiftUI

/// Floating bar under the label with the selected element's most-used settings (font, size, style,
/// alignment … for text; type and height for barcodes; and so on) and a Settings button that opens
/// the full properties panel.
struct ElementQuickBar: View {
    @Binding var element: LabelElement
    let label: CGSize
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x3.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            controls
            QuickDivider()
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 28)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.35)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .hoverTip("All \(element.kind.title.lowercased()) settings", edge: .top)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .fixedSize()
    }

    @ViewBuilder
    private var controls: some View {
        switch element.kind {
        case .text, .date, .counter: textControls
        case .barcode: barcodeControls
        case .qrCode: qrControls
        case .image: imageControls
        case .icon: iconControls
        case .shape: shapeControls
        }
    }

    // MARK: Text

    @ViewBuilder
    private var textControls: some View {
        FontSearchPicker(selection: $element.fontFamily, width: 150)
        .hoverTip("Font", edge: .top)

        QuickStepper(value: $element.fontSizeMM, step: 0.5, range: 1...40, unit: "mm", tip: "Font size")

        QuickSegment {
            QuickToggle(symbol: "bold", tip: "Bold", isOn: Binding(get: { element.resolvedWeight.isBold },
                                                                     set: { element.fontWeight = $0 ? .bold : .regular; element.bold = $0 }))
            QuickToggle(symbol: "italic", tip: "Italic", isOn: $element.italic)
            QuickToggle(symbol: "underline", tip: "Underline", isOn: $element.underline)
        }
        QuickSegment {
            QuickToggle(symbol: "text.alignleft", tip: "Align left", isOn: alignment(.leading))
            QuickToggle(symbol: "text.aligncenter", tip: "Align centre", isOn: alignment(.center))
            QuickToggle(symbol: "text.alignright", tip: "Align right", isOn: alignment(.trailing))
        }
        QuickSegment {
            QuickToggle(symbol: "circle.lefthalf.filled.inverse", tip: "White on black", isOn: $element.invertsText)
            QuickToggle(symbol: "square.dashed", tip: "Outline box", isOn: $element.outlined)
        }
    }

    private func alignment(_ value: TextAlign) -> Binding<Bool> {
        Binding(get: { element.textAlignment == value }, set: { if $0 { element.textAlignment = value } })
    }

    // MARK: Codes

    @ViewBuilder
    private var barcodeControls: some View {
        Picker("", selection: $element.barcodeType) {
            ForEach(BarcodeType.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden().frame(width: 110)
        .hoverTip("Barcode type", edge: .top)
        QuickStepper(value: $element.barcodeHeightMM, step: 0.5, range: 2...80, unit: "mm", tip: "Bar height")
        QuickStepper(value: Binding(get: { Double(element.barcodeModuleDots) },
                                    set: { element.barcodeModuleDots = min(max(Int($0.rounded()), 1), 6) }),
                     step: 1, range: 1...6, unit: "dot", tip: "Bar width")
        QuickSegment {
            QuickToggle(symbol: "textformat.123", tip: "Show number", isOn: $element.showsBarcodeText)
            QuickToggle(symbol: "arrow.left.and.right.square", tip: "Quiet zone", isOn: $element.barcodeQuietZone)
        }
    }

    @ViewBuilder
    private var qrControls: some View {
        QuickStepper(value: $element.qrSizeMM, step: 0.5, range: 4...100, unit: "mm", tip: "QR size")
        Picker("", selection: $element.qrCorrection) {
            ForEach(["L", "M", "Q", "H"], id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .hoverTip("Error correction", edge: .top)
    }

    // MARK: Pictures

    @ViewBuilder
    private var imageControls: some View {
        QuickStepper(value: $element.imageWidthMM, step: 0.5, range: 2...300, unit: "mm", tip: "Image width")
        Picker("", selection: $element.dithers) {
            Text("Photo").tag(true)
            Text("Line art").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .hoverTip("Printing style", edge: .top)
        Slider(value: $element.imageThreshold, in: 0.2...0.95).frame(width: 90)
            .hoverTip("Darkness", edge: .top)
        QuickSegment {
            QuickToggle(symbol: "circle.lefthalf.filled.inverse", tip: "Invert", isOn: $element.invertsImage)
            QuickToggle(symbol: "crop", tip: "Trim empty margins", isOn: $element.trimsImage)
        }
    }

    @ViewBuilder
    private var iconControls: some View {
        QuickStepper(value: $element.iconSizeMM, step: 0.5, range: 2...100, unit: "mm", tip: "Icon size")
        Picker("", selection: $element.iconWeight) {
            ForEach(IconWeight.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .hoverTip("Weight", edge: .top)
        QuickSegment {
            QuickToggle(symbol: "circle.fill", tip: "Filled", isOn: $element.iconFilled)
        }
    }

    @ViewBuilder
    private var shapeControls: some View {
        Picker("", selection: $element.shapeKind) {
            ForEach(ShapeKind.allCases) { Image(systemName: $0.systemImage).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .hoverTip("Shape", edge: .top)
        QuickStepper(value: $element.lineWidthMM, step: 0.125, range: 0.125...10, unit: "mm", tip: "Line width")
        QuickSegment {
            if element.shapeKind != .line {
                QuickToggle(symbol: "square.fill", tip: "Filled", isOn: $element.shapeFilled)
            }
            QuickToggle(symbol: "line.3.horizontal.decrease", tip: "Dashed", isOn: $element.dashed)
        }
    }
}

// MARK: - Several selected

/// Floating bar for a multi-selection: align the elements to each other, distribute them, lock,
/// duplicate, delete, or clear the selection.
struct MultiSelectionBar: View {
    @EnvironmentObject private var session: LabelSession
    let selection: Set<LabelElement.ID>
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("\(selection.count) selected", systemImage: "square.on.square.dashed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 4)
            QuickDivider()
            QuickSegment {
                ForEach(LabelAlignment.allCases, id: \.self) { alignment in
                    QuickAction(symbol: alignment.systemImage, tip: "Align \(alignment.title) Edges") {
                        session.alignElements(selection, alignment)
                    }
                }
            }
            QuickSegment {
                QuickAction(symbol: "distribute.horizontal.center", tip: "Distribute Horizontally", isDisabled: selection.count < 3) {
                    session.distributeElements(selection, .horizontal)
                }
                QuickAction(symbol: "distribute.vertical.center", tip: "Distribute Vertically", isDisabled: selection.count < 3) {
                    session.distributeElements(selection, .vertical)
                }
            }
            QuickSegment {
                QuickAction(symbol: "lock", tip: "Lock All") { session.setFlag(\.isLocked, to: true, for: selection, actionName: "Lock") }
                QuickAction(symbol: "lock.open", tip: "Unlock All") { session.setFlag(\.isLocked, to: false, for: selection, actionName: "Unlock") }
                QuickAction(symbol: "trash", tip: "Delete \(selection.count) Elements") {
                    session.deleteElements(selection)
                    onClear()
                }
            }
            QuickDivider()
            Button(action: onClear) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
                .buttonStyle(.borderless)
                .hoverTip("Clear Selection", shortcut: "Esc", edge: .top)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .fixedSize()
    }
}

private struct QuickAction: View {
    let symbol: String
    let tip: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .hoverTip(tip, edge: .top)
        .accessibilityLabel(tip)
    }
}

// MARK: - Pieces

private enum QuickField {
    static let fill = Color.primary.opacity(0.07)
}

private struct QuickDivider: View {
    var body: some View { Divider().frame(height: 22) }
}

/// "−  12.0 mm  +" field.
private struct QuickStepper: View {
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    let unit: String
    let tip: String

    var body: some View {
        // "mm" = a length: shown in the unit chosen in Settings, stored in millimetres.
        let measure: MeasureUnit? = unit == "mm" ? MeasureUnit.current : nil
        HStack(spacing: 0) {
            Button { nudge(-1, measure) } label: { Image(systemName: "minus").frame(width: 24, height: 28).contentShape(Rectangle()) }
                .disabled(value <= range.lowerBound)
            TextField("", value: measure.map { $0.binding(Binding(get: { value }, set: { set($0) })) } ?? Binding(get: { value }, set: { set($0) }),
                      format: measure?.fieldFormat ?? .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: 46)
            Text(measure?.symbol ?? unit).font(.caption2).foregroundStyle(.tertiary)
            Button { nudge(1, measure) } label: { Image(systemName: "plus").frame(width: 24, height: 28).contentShape(Rectangle()) }
                .disabled(value >= range.upperBound)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .background(QuickField.fill, in: RoundedRectangle(cornerRadius: 8))
        .hoverTip(tip, edge: .top)
    }

    private func set(_ new: Double) {
        value = min(max(new, range.lowerBound), range.upperBound)
    }

    private func nudge(_ direction: Double, _ measure: MeasureUnit?) {
        if let measure {
            value = measure.stepped(value, stepMM: step, direction: direction, in: range)
        } else {
            value = min(max(((value / step).rounded() + direction) * step, range.lowerBound), range.upperBound)
        }
    }
}

/// Buttons sharing one rounded background.
private struct QuickSegment<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 1) { content }
            .padding(2)
            .background(QuickField.fill, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct QuickToggle: View {
    let symbol: String
    let tip: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .frame(width: 28, height: 24)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .hoverTip(tip, edge: .top)
        .accessibilityLabel(tip)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
