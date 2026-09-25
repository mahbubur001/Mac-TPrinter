import AppKit
import SwiftUI

/// Nearby / paired printers with Connect buttons. Printers first; other Bluetooth devices (with their
/// real icons, no Connect button when they clearly aren't printers) only when "Show all" is on.
/// Used on the dashboard (Search printers) and in Settings › Printers.
struct PrinterChooser: View {
    @EnvironmentObject private var bluetooth: PrinterBluetoothManager

    private struct Device: Identifiable {
        let id: String
        let name: String
        let kind: DeviceKind
        let transport: String
        let connected: Bool
        let connect: () -> Void
    }

    private var devices: [Device] {
        let classic = bluetooth.visibleClassicPrinters.map { printer in
            Device(id: printer.id, name: printer.name,
                   kind: printer.isImagingDevice ? .printer : DeviceKind.classic(major: printer.majorClass, minor: printer.minorClass, name: printer.name),
                   transport: "Classic Bluetooth",
                   connected: printer.id == bluetooth.connectedClassicAddress) { bluetooth.connectClassic(printer.id) }
        }
        let ble = bluetooth.visiblePrinters.filter { !isUnnamed($0.name) }.map { printer in
            Device(id: printer.id.uuidString, name: printer.name,
                   kind: DeviceKind.ble(name: printer.name, looksLikePrinter: printer.looksLikePrinter),
                   transport: printer.rssi != 0 ? "Bluetooth LE, signal \(printer.rssi) dBm" : "Bluetooth LE",
                   connected: printer.id == bluetooth.connectedPrinterID) { bluetooth.connect(printer.id) }
        }
        let usb = bluetooth.usbPrinters.map { printer in
            Device(id: printer.id, name: printer.name, kind: .printer, transport: "USB cable",
                   connected: printer.id == bluetooth.connectedUSBID) { bluetooth.connectUSB(printer.id) }
        }
        return usb + classic + ble
    }

    private var unnamedCount: Int { bluetooth.visiblePrinters.filter { isUnnamed($0.name) }.count }

    private func isUnnamed(_ name: String) -> Bool { name == "Unknown device" || name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let all = devices
        let printers = all.filter { $0.kind == .printer || $0.connected }
        let others = all.filter { $0.kind != .printer && !$0.connected }

        VStack(alignment: .leading, spacing: 8) {
            if bluetooth.bluetoothState == .unauthorized {
                HStack {
                    Text("TPrinter isn't allowed to use Bluetooth.").foregroundStyle(.secondary)
                    Button("Open Bluetooth Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }

            sectionTitle("Printers", count: printers.count)
            if printers.isEmpty {
                Text("No printers found. Plug the printer in by USB, or pair it in System Settings › Bluetooth, turn it on, then search again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(printers) { row($0) }

            if bluetooth.showAllDevices, !others.isEmpty || unnamedCount > 0 {
                sectionTitle("Other Bluetooth devices", count: others.count).padding(.top, 8)
                ForEach(others) { row($0) }
                if unnamedCount > 0 {
                    Text("\(unnamedCount) unnamed device\(unnamedCount == 1 ? "" : "s") hidden")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                }
            }

            HStack(spacing: 12) {
                if bluetooth.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Looking for Bluetooth LE printers…").foregroundStyle(.secondary)
                    Button("Stop") { bluetooth.stopScan() }.buttonStyle(.link)
                }
                Spacer()
                Toggle("Show all Bluetooth devices", isOn: $bluetooth.showAllDevices)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .font(.callout)
            .padding(.top, 4)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.tertiary) }
        }
    }

    private func row(_ device: Device) -> some View {
        let isPrinter = device.kind == .printer
        return HStack(spacing: 12) {
            Image(systemName: device.kind.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(isPrinter ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .background((isPrinter ? Color.accentColor : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).fontWeight(.medium)
                Text(device.kind == .unknown ? device.transport : "\(device.kind.title), \(device.transport)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if device.connected {
                StatusPill(state: .ready, text: "Connected")
            } else if isPrinter {
                Button("Connect", action: device.connect)
            } else if !device.kind.isKnownNonPrinter {
                Button("Try Connecting", action: device.connect)
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("This device didn't say what it is. It may be a printer.")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(isPrinter ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 10))
        .opacity(isPrinter || device.connected ? 1 : 0.85)
    }
}

/// The label's elements, front-most first: select, rename (double-click), reorder (drag), right-click menu.
/// Layers, front-most first. ⌘-click / ⇧-click select several (shared with the canvas selection).
struct LayersList: View {
    @Binding var document: LabelDocument
    @Binding var selection: Set<LabelElement.ID>
    @EnvironmentObject private var session: LabelSession
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: $selection) {
            if document.elements.isEmpty {
                Text("Nothing on the label yet.").foregroundStyle(.secondary)
            }
            // Front-most first, like design apps; `elements` stores back-to-front.
            ForEach(document.elements.reversed()) { element in
                row(element)
                    .tag(element.id)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { session.renamingElementID = element.id })
                    .contextMenu {
                        ElementContextMenu(element: element, session: session) { selection = $0.map { [$0] } ?? [] }
                    }
            }
            .onMove(perform: move)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ element: LabelElement) -> some View {
        Label {
            if session.renamingElementID == element.id {
                TextField("Name", text: $renameText, prompt: Text(automaticName(element)))
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onAppear {
                        renameText = element.name
                        renameFocused = true
                    }
                    .onSubmit { finishRename(element.id) }
                    .onExitCommand { session.renamingElementID = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { finishRename(element.id) } }
            } else {
                HStack(spacing: 6) {
                    Text(element.layerName).lineLimit(1).opacity(element.isHidden ? 0.45 : 1)
                    Spacer(minLength: 0)
                    if ElementGeometry.overflowMM(of: element, label: CGSize(width: document.widthMM, height: document.heightMM)) > 0 {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Runs off the label")
                    }
                    Button { toggle(element.id, \.isHidden, name: element.isHidden ? "Show" : "Hide") } label: {
                        Image(systemName: element.isHidden ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(element.isHidden ? .primary : .tertiary)
                    .help(element.isHidden ? "Show" : "Hide")
                    Button { toggle(element.id, \.isLocked, name: element.isLocked ? "Unlock" : "Lock") } label: {
                        Image(systemName: element.isLocked ? "lock.fill" : "lock.open")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(element.isLocked ? .primary : .tertiary)
                    .help(element.isLocked ? "Unlock" : "Lock")
                }
            }
        } icon: {
            if element.kind == .icon, IconCatalog.isValid(element.content) {
                Image(systemName: element.content)
            } else {
                Image(systemName: element.kind.systemImage)
            }
        }
    }

    private func automaticName(_ element: LabelElement) -> String {
        var unnamed = element
        unnamed.name = ""
        return unnamed.layerName
    }

    private func finishRename(_ id: LabelElement.ID) {
        guard session.renamingElementID == id else { return }
        session.renamingElementID = nil
        session.renameElement(id, to: renameText)
    }

    private func toggle(_ id: LabelElement.ID, _ flag: WritableKeyPath<LabelElement, Bool>, name: String) {
        session.perform(name) { doc in
            guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
            doc.elements[index][keyPath: flag].toggle()
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        session.perform("Reorder Layers") { doc in
            var frontFirst = Array(doc.elements.reversed())
            frontFirst.move(fromOffsets: source, toOffset: destination)
            doc.elements = frontFirst.reversed()
        }
    }
}
