import AppKit
import SwiftUI

/// Printer console (Settings › Printers › Advanced): Bluetooth log plus a raw command box for
/// debugging the printer. Commands go straight to the printer.
struct ConsoleView: View {
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager
    @State private var command = ""
    @State private var sendAsHex = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(bluetooth.log) { entry in
                            Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(entry.message)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .onChange(of: bluetooth.log.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            Divider()

            HStack {
                TextField(sendAsHex ? "Hex bytes, e.g. 1B 40" : "TSPL command, e.g. SELFTEST", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(send)
                Toggle("Hex", isOn: $sendAsHex).toggleStyle(.checkbox)
                Button("Send", action: send).disabled(!bluetooth.connection.isReady || bluetooth.isSending)
                Button("Clear Log") { bluetooth.clearLog() }
                Button { NSWorkspace.shared.activateFileViewerSelecting([PrinterBluetoothManager.logFileURL]) } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Show the log file in Finder")
            }
            .padding(8)
        }
    }

    private func send() {
        if sendAsHex {
            guard let data = Data(hexString: command) else { return }
            bluetooth.send(data)
        } else {
            // Allow multiple commands separated by newlines or ";".
            let lines = command
                .split(whereSeparator: { $0 == "\n" || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var tspl = TSPLCommandBuilder()
            lines.forEach { tspl.raw($0) }
            bluetooth.send(tspl.data)
        }
    }
}
