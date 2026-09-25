import SwiftUI

/// The app's own dialog: a card sheet with a coloured icon tile, title, message, optional content
/// (e.g. a name field) and large buttons. Used instead of system alerts so every prompt looks alike.
struct ModernDialog<Content: View>: View {
    enum Tone {
        case info, question, warning, danger

        var color: Color {
            switch self {
            case .info: .accentColor
            case .question: .accentColor
            case .warning: .orange
            case .danger: .red
            }
        }
    }

    struct Action {
        let title: String
        var role: ButtonRole?
        var isDisabled = false
        let perform: () -> Void

        init(_ title: String, role: ButtonRole? = nil, isDisabled: Bool = false, perform: @escaping () -> Void) {
            self.title = title
            self.role = role
            self.isDisabled = isDisabled
            self.perform = perform
        }
    }

    let icon: String
    var tone: Tone = .info
    let title: String
    var message: String = ""
    let primary: Action
    /// Shown on the left (e.g. "Don't Save").
    var secondary: Action?
    /// nil: no Cancel button (plain notices with just OK).
    var cancelTitle: String? = "Cancel"
    var onCancel: () -> Void = {}
    /// All buttons on the right, Cancel and the secondary action as text buttons (the unsaved-changes
    /// prompt: Cancel · Exit Without Saving · Save).
    var textButtons = false
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tone.color)
                        .frame(width: 44, height: 44)
                        .background(tone.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: icon.isEmpty ? 10 : 5) {
                    Text(title)
                        .font(.system(size: icon.isEmpty ? 19 : 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !message.isEmpty {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            content()
            if textButtons {
                HStack(spacing: 6) {
                    Spacer()
                    if let cancelTitle {
                        Button(cancelTitle, role: .cancel) { finish(onCancel) }
                            .buttonStyle(DialogButtonStyle(kind: .text))
                            .focusable(false) // the focus ring made Cancel look like the default
                            .keyboardShortcut(.cancelAction)
                    }
                    if let secondary {
                        Button(secondary.title, role: secondary.role) { finish(secondary.perform) }
                            .buttonStyle(DialogButtonStyle(kind: secondary.role == .destructive ? .destructiveText : .text))
                            .focusable(false)
                            .disabled(secondary.isDisabled)
                    }
                    Button(primary.title, role: primary.role) { finish(primary.perform) }
                        .buttonStyle(DialogButtonStyle(kind: .prominent))
                        .keyboardShortcut(.defaultAction)
                        .disabled(primary.isDisabled)
                }
            } else {
            HStack(spacing: 10) {
                if let secondary {
                    Button(secondary.title, role: secondary.role) { finish(secondary.perform) }
                        .buttonStyle(DialogButtonStyle(kind: .plain))
                        .focusable(false) // the focus ring made Cancel look like the default
                        .disabled(secondary.isDisabled)
                }
                Spacer()
                if let cancelTitle {
                    Button(cancelTitle, role: .cancel) { finish(onCancel) }
                        .buttonStyle(DialogButtonStyle(kind: .plain))
                        .focusable(false) // the focus ring made Cancel look like the default
                        .keyboardShortcut(.cancelAction)
                }
                Button(primary.title, role: primary.role) { finish(primary.perform) }
                    .buttonStyle(DialogButtonStyle(kind: primary.role == .destructive ? .destructive : .prominent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(primary.isDisabled)
            }
            }
        }
        .padding(textButtons ? 26 : 22)
        .frame(width: textButtons ? 470 : 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Runs the action first (it may read the state that presented the sheet), then closes.
    private func finish(_ action: () -> Void) {
        action()
        dismiss()
    }
}

extension ModernDialog where Content == EmptyView {
    init(icon: String, tone: Tone = .info, title: String, message: String = "", primary: Action,
         secondary: Action? = nil, cancelTitle: String? = "Cancel", onCancel: @escaping () -> Void = {}, textButtons: Bool = false) {
        self.init(icon: icon, tone: tone, title: title, message: message, primary: primary, secondary: secondary,
                  cancelTitle: cancelTitle, onCancel: onCancel, textButtons: textButtons) { EmptyView() }
    }
}

/// Rounded, full-height dialog buttons: filled accent, filled red, or a quiet grey.
struct DialogButtonStyle: ButtonStyle {
    enum Kind { case prominent, destructive, plain, text, destructiveText }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch kind {
        case .prominent: .accentColor
        case .destructive: .red
        case .plain: Color.primary.opacity(0.08)
        case .text, .destructiveText: configuration.isPressed ? Color.primary.opacity(0.08) : .clear
        }
        let ink: Color = switch kind {
        case .plain: .primary
        case .text: .accentColor
        case .destructiveText: .red
        case .prominent, .destructive: .white
        }
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 16)
            .frame(minWidth: 84, minHeight: 32)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Text field styled for dialogs.
struct DialogTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.12),
                                                                     lineWidth: focused ? 2 : 1))
            .focused($focused)
            .onSubmit(onSubmit)
            .onAppear { focused = true }
    }
}

extension Binding where Value == Bool {
    /// True while `optional` holds a value; setting false clears it (for sheets driven by an optional).
    init<T>(presenting optional: Binding<T?>) {
        self.init(get: { optional.wrappedValue != nil }, set: { if !$0 { optional.wrappedValue = nil } })
    }
}

extension View {
    /// A plain "something happened" notice with an OK button, shown while `message` is set.
    func noticeDialog(_ title: String, icon: String = "exclamationmark.triangle.fill", tone: ModernDialog<EmptyView>.Tone = .warning,
                      message: Binding<String?>) -> some View {
        sheet(isPresented: Binding(presenting: message)) {
            ModernDialog(icon: icon, tone: tone, title: title, message: message.wrappedValue ?? "",
                         primary: .init("OK") { message.wrappedValue = nil }, cancelTitle: nil)
        }
    }

    /// The label-sensor calibration prompt (dashboard, settings, inspector), worded for the media's
    /// separation. Continuous paper and a missing printer get an explanation instead.
    func calibrationDialog(isPresented: Binding<Bool>, document: LabelDocument, printerReady: Bool,
                           send: @escaping (Data) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            let size = MeasureUnit.current.size(document.widthMM, document.heightMM)
            if !printerReady {
                ModernDialog(icon: "printer.fill", tone: .warning, title: "Connect a printer first",
                             message: "Calibration runs on the printer. Connect it on the Dashboard, then try again.",
                             primary: .init("OK") {}, cancelTitle: nil)
            } else if let job = LabelPrintService.sensorCalibrationJob(for: document) {
                let mark = document.separation == .blackMark
                ModernDialog(icon: "ruler", tone: .question,
                             title: mark ? "Calibrate the black-mark sensor?" : "Calibrate the gap sensor?",
                             message: "For \(document.mediaTitle) (\(size), \(document.separation.title.lowercased())). "
                                + "The printer feeds paper until its sensor finds the next "
                                + (mark ? "black mark" : "gap")
                                + " (at most three labels). Print an alignment test afterwards to check.",
                             primary: .init("Calibrate") { send(job) })
            } else {
                ModernDialog(icon: "scroll", tone: .info, title: "Nothing to calibrate",
                             message: "\(document.mediaTitle) is continuous paper: there are no gaps or marks to measure. "
                                + "Change the media's separation if your roll has them.",
                             primary: .init("OK") {}, cancelTitle: nil)
            }
        }
    }
}
