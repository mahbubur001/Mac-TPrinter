@preconcurrency import CoreBluetooth
import Foundation

struct DiscoveredPrinter: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var looksLikePrinter: Bool
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

/// Finds, connects to and streams data to the printer, over either transport:
/// - Classic Bluetooth RFCOMM (`RP310-D157`) via IOBluetooth — preferred, verified working
/// - BLE (`RP310-D157-BLE`) via CoreBluetooth
@MainActor
final class PrinterBluetoothManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting(String)
        case discovering(String)
        case ready(String)
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    /// Write characteristics commonly used by Rongta and other Chinese BLE printers, tried in order.
    static let preferredWriteCharacteristics: [CBUUID] = [
        CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3"), // ISSC / Microchip transparent UART
        CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
        CBUUID(string: "FF02"),
        CBUUID(string: "FFE1"),
        CBUUID(string: "FFF2"),
        CBUUID(string: "2AF1"),
    ]

    /// Upper bound per BLE write; many printers mis-handle anything larger.
    static let chunkLimit = 180

    private static let lastPrinterKey = "lastPrinterIdentifier"
    private static let lastClassicAddressKey = "lastClassicPrinterAddress"
    private static let lastUSBKey = "lastUSBPrinterID"
    /// "usb" or "classic": which connection to restore at launch.
    private static let lastTransportKey = "lastPrinterTransport"
    static let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TPrinter.log")
    private static let printerNameHints = ["RP", "RONGTA", "PRINTER", "RPP", "TSC", "LABEL"]

    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var printers: [DiscoveredPrinter] = []
    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var connectedPrinterID: UUID?
    @Published private(set) var writeCharacteristicDescription: String?
    @Published private(set) var sendProgress: Double?
    @Published private(set) var log: [LogEntry] = []
    @Published var showAllDevices = false
    /// Multi-label printing in progress: labels sent so far / total.
    @Published private(set) var queueProgress: (done: Int, total: Int)?
    /// Jobs completed by the last queue (available in its completion handler).
    private(set) var lastQueueDone = 0
    @Published private(set) var classicPrinters: [ClassicPrinterInfo] = []
    @Published private(set) var connectedClassicAddress: String?
    /// Printers plugged in by USB (updated on plug / unplug).
    @Published private(set) var usbPrinters: [USBPrinterInfo] = []
    @Published private(set) var connectedUSBID: String?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse

    private var pending = Data()
    private var pendingTotal = 0
    private var awaitingWriteResponse = false
    private var servicesAwaitingCharacteristics = 0
    private var sendCompletion: ((String?) -> Void)?
    private var queueStopRequested = false
    private var classic: ClassicPrinterConnection?
    private var usb: USBPrinterConnection?
    private var usbWatcher: AnyObject?

    override init() {
        super.init()
        append("TPrinter started. Log file: \(Self.logFileURL.path)")
        refreshClassicPrinters()
        usbPrinters = USBPrinterConnection.connectedPrinters()
        if UserDefaults.standard.string(forKey: Self.lastTransportKey) == "usb", let printer = lastUSBPrinter {
            connectUSB(printer.id)
        } else {
            reconnectToLastClassicPrinter()
        }
        usbWatcher = USBPrinterConnection.watch { [weak self] in self?.usbPrintersChanged() }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var visibleClassicPrinters: [ClassicPrinterInfo] {
        showAllDevices ? classicPrinters : classicPrinters.filter { $0.isImagingDevice || Self.looksLikePrinter($0.name) }
    }

    var visiblePrinters: [DiscoveredPrinter] {
        let list = showAllDevices ? printers : printers.filter(\.looksLikePrinter)
        return list.sorted { $0.rssi > $1.rssi }
    }

    var isSending: Bool { sendProgress != nil }

    // MARK: - Public API

    func startScan() {
        guard bluetoothState == .poweredOn else {
            append("Bluetooth is not powered on (\(bluetoothState.label)).")
            return
        }
        refreshClassicPrinters()
        printers.removeAll { $0.id != connectedPrinterID }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        append("Scanning…")
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        append("Scan stopped.")
    }

    func refreshClassicPrinters() {
        classicPrinters = ClassicPrinterConnection.pairedPrinters()
    }

    // MARK: USB

    private var lastUSBPrinter: USBPrinterInfo? {
        let id = UserDefaults.standard.string(forKey: Self.lastUSBKey)
        return usbPrinters.first { $0.id == id }
    }

    /// Uses a printer plugged in by USB. Like Classic, each job opens the connection itself.
    func connectUSB(_ id: String) {
        guard let info = usbPrinters.first(where: { $0.id == id }) else { return }
        stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetConnection()
        closeClassic()
        let printer = USBPrinterConnection(info: info)
        printer.onReceive = { [weak self] data in self?.append("Printer → \(data.hexString)") }
        printer.onEvent = { [weak self] event in self?.append(event) }
        usb = printer
        connectedUSBID = id
        connection = .ready(info.name)
        UserDefaults.standard.set(id, forKey: Self.lastUSBKey)
        UserDefaults.standard.set("usb", forKey: Self.lastTransportKey)
        append("Ready: \(info.name) (USB \(String(format: "%04X:%04X", info.vendorID, info.productID))).")
    }

    /// Plugged in: switch to it when it's the printer used last or nothing's connected.
    /// Unplugged while in use: back to the last Bluetooth printer.
    private func usbPrintersChanged() {
        let before = Set(usbPrinters.map(\.id))
        usbPrinters = USBPrinterConnection.connectedPrinters()
        let now = Set(usbPrinters.map(\.id))
        for printer in usbPrinters where !before.contains(printer.id) {
            append("USB printer plugged in: \(printer.name).")
            let wasLast = printer.id == UserDefaults.standard.string(forKey: Self.lastUSBKey)
            if !isSending, !isQueueRunning, wasLast || !connection.isReady { connectUSB(printer.id) }
        }
        if let id = connectedUSBID, !now.contains(id) {
            append("USB printer unplugged.")
            closeUSB()
            connection = .idle
            if !isSending { reconnectToLastClassicPrinter() }
        }
    }

    private func closeUSB() {
        usb = nil
        connectedUSBID = nil
    }

    private func sendUSB(_ data: Data, via printer: USBPrinterConnection) {
        pendingTotal = data.count
        sendProgress = 0
        append("Sending \(data.count) bytes to \(printer.info.name) over USB…")
        printer.send(data) { [weak self] fraction in
            self?.sendProgress = fraction
        } completion: { [weak self] error in
            guard let self else { return }
            if let error { failSend(error.localizedDescription) } else { finishSend() }
        }
    }

    /// Selects a paired Classic printer. Each job opens its own RFCOMM channel, so this doesn't touch the radio.
    func connectClassic(_ address: String) {
        stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnection()
        closeClassic()
        closeUSB()
        do {
            let printer = try ClassicPrinterConnection(address: address)
            printer.onReceive = { [weak self] data in self?.append("Printer → \(data.hexString)") }
            printer.onChannelEvent = { [weak self] event in self?.append(event) }
            classic = printer
            connectedClassicAddress = address
            connection = .ready(printer.name)
            UserDefaults.standard.set(address, forKey: Self.lastClassicAddressKey)
            UserDefaults.standard.set("classic", forKey: Self.lastTransportKey)
            append("Ready: \(printer.name) (Classic Bluetooth \(address)).")
        } catch {
            connection = .failed(error.localizedDescription)
            append(error.localizedDescription)
        }
    }

    func connect(_ id: UUID) {
        guard let target = peripherals[id] else { return }
        stopScan()
        closeClassic()
        closeUSB()
        if let current = peripheral, current.identifier != id {
            central.cancelPeripheralConnection(current)
        }
        peripheral = target
        target.delegate = self
        connection = .connecting(target.displayName)
        append("Connecting to \(target.displayName)…")
        central.connect(target)
    }

    func disconnect() {
        if usb != nil {
            closeUSB()
            connection = .idle
            append("Disconnected.")
            return
        }
        if classic != nil {
            closeClassic()
            connection = .idle
            append("Disconnected.")
            return
        }
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    /// - Parameter completion: called once the job has gone out (nil) or failed (error message).
    func send(_ data: Data, completion: ((String?) -> Void)? = nil) {
        guard !isSending else {
            append("A job is already being sent.")
            completion?("A job is already being sent.")
            return
        }
        sendCompletion = completion
        if let usb {
            sendUSB(data, via: usb)
            return
        }
        if let classic {
            sendClassic(data, via: classic)
            return
        }
        guard connection.isReady, writeCharacteristic != nil else {
            append("Not connected to a printer.")
            sendCompletion = nil
            completion?("Not connected to a printer.")
            return
        }
        pending = data
        pendingTotal = data.count
        sendProgress = 0
        append("Sending \(data.count) bytes…")
        pump()
    }

    /// Sends `count` single-label jobs one after another, building each just before it's sent
    /// (so large batches don't render everything up front). Stops at the first failure or on `stopQueue()`.
    /// - Parameter completion: nil when all were sent, otherwise why it stopped.
    func sendQueue(count: Int, makeJob: @escaping (Int) throws -> Data, completion: ((String?) -> Void)? = nil) {
        guard count > 0, queueProgress == nil, !isSending else { return }
        queueStopRequested = false
        queueProgress = (0, count)
        append("Printing \(count) labels, one job each…")
        sendQueued(index: 0, count: count, makeJob: makeJob, completion: completion)
    }

    func stopQueue() { queueStopRequested = true }

    var isQueueRunning: Bool { queueProgress != nil }

    private func sendQueued(index: Int, count: Int, makeJob: @escaping (Int) throws -> Data, completion: ((String?) -> Void)?) {
        func end(_ error: String?) {
            lastQueueDone = index
            queueProgress = nil
            append(error.map { "Stopped after \(index) of \(count) labels: \($0)" } ?? "Printed \(count) labels.")
            completion?(error)
        }
        guard index < count else { return end(nil) }
        guard !queueStopRequested else { return end("stopped") }
        let job: Data
        do { job = try makeJob(index) } catch { return end(error.localizedDescription) }
        send(job) { [weak self] error in
            guard let self else { return }
            if let error { return end(error) }
            queueProgress = (index + 1, count)
            sendQueued(index: index + 1, count: count, makeJob: makeJob, completion: completion)
        }
    }

    func clearLog() { log.removeAll() }

    // MARK: - Internals

    private func append(_ message: String) {
        let entry = LogEntry(message: message)
        log.append(entry)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        writeToLogFile(entry)
    }

    /// Mirrors the console to ~/Library/Logs/TPrinter.log so it can be inspected outside the app.
    private func writeToLogFile(_ entry: LogEntry) {
        let line = Data("\(entry.date.ISO8601Format()) \(entry.message)\n".utf8)
        let url = Self.logFileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    private static func looksLikePrinter(_ name: String) -> Bool {
        let upper = name.uppercased()
        return printerNameHints.contains { upper.contains($0) }
    }

    private func sendClassic(_ data: Data, via printer: ClassicPrinterConnection) {
        pendingTotal = data.count
        sendProgress = 0
        append("Sending \(data.count) bytes to \(printer.name)…")
        printer.send(data) { [weak self] fraction in
            self?.sendProgress = fraction
        } completion: { [weak self] error in
            guard let self else { return }
            if let error {
                failSend(error.localizedDescription)
            } else {
                finishSend()
            }
        }
    }

    private func closeClassic() {
        classic?.close()
        classic = nil
        connectedClassicAddress = nil
    }

    private func reconnectToLastClassicPrinter() {
        guard
            let address = UserDefaults.standard.string(forKey: Self.lastClassicAddressKey),
            classicPrinters.contains(where: { $0.id == address })
        else { return }
        connectClassic(address)
    }

    private func pump() {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        let chunkSize = max(1, min(peripheral.maximumWriteValueLength(for: writeType), Self.chunkLimit))

        while !pending.isEmpty {
            if writeType == .withoutResponse {
                guard peripheral.canSendWriteWithoutResponse else { return } // resumes in peripheralIsReady
            } else if awaitingWriteResponse {
                return // resumes in didWriteValueFor
            }

            let chunk = pending.prefix(chunkSize)
            pending.removeFirst(chunk.count)
            peripheral.writeValue(Data(chunk), for: characteristic, type: writeType)
            if writeType == .withResponse { awaitingWriteResponse = true }
            sendProgress = Double(pendingTotal - pending.count) / Double(max(pendingTotal, 1))
        }

        if !awaitingWriteResponse { finishSend() }
    }

    private func finishSend() {
        guard sendProgress != nil else { return }
        sendProgress = nil
        append("Sent \(pendingTotal) bytes.")
        takeCompletion()?(nil)
    }

    private func failSend(_ message: String) {
        pending.removeAll()
        awaitingWriteResponse = false
        sendProgress = nil
        append("Send failed: \(message)")
        takeCompletion()?(message)
    }

    private func takeCompletion() -> ((String?) -> Void)? {
        defer { sendCompletion = nil }
        return sendCompletion
    }

    private func chooseWriteCharacteristic(from services: [CBService]) {
        guard writeCharacteristic == nil else { return }
        let writable = services.flatMap { $0.characteristics ?? [] }.filter {
            $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write)
        }
        let preferred = Self.preferredWriteCharacteristics.lazy.compactMap { uuid in writable.first { $0.uuid == uuid } }.first
        guard let characteristic = preferred ?? writable.first else {
            connection = .failed("No writable characteristic found")
            append("No writable characteristic found on this device.")
            return
        }
        useWriteCharacteristic(characteristic)
    }

    private func useWriteCharacteristic(_ characteristic: CBCharacteristic) {
        writeCharacteristic = characteristic
        writeType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let description = "service \(characteristic.service?.uuid.uuidString ?? "?") / char \(characteristic.uuid.uuidString) (\(writeType == .withoutResponse ? "no response" : "with response"))"
        writeCharacteristicDescription = description
        append("Using \(description)")
        if let peripheral {
            connection = .ready(peripheral.displayName)
            connectedPrinterID = peripheral.identifier
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPrinterKey)
            append("Ready. Max write length: \(peripheral.maximumWriteValueLength(for: writeType)) bytes.")
        }
    }

    private func reconnectToLastPrinter() {
        guard
            let raw = UserDefaults.standard.string(forKey: Self.lastPrinterKey),
            let id = UUID(uuidString: raw),
            let known = central.retrievePeripherals(withIdentifiers: [id]).first
        else { return }
        record(known, rssi: 0)
        append("Reconnecting to last printer \(known.displayName)…")
        connect(id)
    }

    private func record(_ peripheral: CBPeripheral, rssi: Int, advertisedName: String? = nil) {
        peripherals[peripheral.identifier] = peripheral
        let name = advertisedName ?? peripheral.name ?? "Unknown device"
        let entry = DiscoveredPrinter(id: peripheral.identifier, name: name, rssi: rssi, looksLikePrinter: Self.looksLikePrinter(name))
        if let index = printers.firstIndex(where: { $0.id == entry.id }) {
            printers[index] = entry
        } else {
            printers.append(entry)
        }
    }

    private func resetConnection() {
        peripheral = nil
        writeCharacteristic = nil
        writeCharacteristicDescription = nil
        connectedPrinterID = nil
        if isSending, classic == nil, usb == nil { failSend("printer disconnected") }
    }
}

// MARK: - CBCentralManagerDelegate

extension PrinterBluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothState = central.state
            append("Bluetooth: \(central.state.label)")
            if central.state == .poweredOn {
                if peripheral == nil, classic == nil { reconnectToLastPrinter() }
            } else {
                isScanning = false
                resetConnection()
                if classic == nil { connection = .idle }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated {
            record(peripheral, rssi: RSSI.intValue, advertisedName: advertisedName)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connection = .discovering(peripheral.displayName)
            append("Connected. Discovering services…")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let message = error?.localizedDescription ?? "unknown error"
            connection = .failed(message)
            append("Failed to connect: \(message)")
            resetConnection()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if classic != nil {
                append("BLE link closed (using Classic Bluetooth).")
                resetConnection()
                return
            }
            if let error {
                connection = .failed(error.localizedDescription)
                append("Disconnected: \(error.localizedDescription)")
            } else {
                connection = .idle
                append("Disconnected.")
            }
            resetConnection()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PrinterBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                append("Service discovery failed: \(error.localizedDescription)")
                return
            }
            let services = peripheral.services ?? []
            append("Services: \(services.map(\.uuid.uuidString).joined(separator: ", "))")
            servicesAwaitingCharacteristics = services.count
            if services.isEmpty { chooseWriteCharacteristic(from: []) }
            services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            servicesAwaitingCharacteristics -= 1
            defer {
                if servicesAwaitingCharacteristics <= 0 { chooseWriteCharacteristic(from: peripheral.services ?? []) }
            }
            if let error {
                append("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
                return
            }
            for characteristic in service.characteristics ?? [] {
                append("  \(service.uuid.uuidString) › \(characteristic.uuid.uuidString) [\(characteristic.properties.label)]")
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        MainActor.assumeIsolated {
            guard let value, !value.isEmpty else { return }
            append("Printer → \(value.hexString)")
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { pump() }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            awaitingWriteResponse = false
            if let error {
                failSend(error.localizedDescription)
                return
            }
            if pending.isEmpty { finishSend() } else { pump() }
        }
    }
}

// MARK: - Helpers

extension CBPeripheral {
    var displayName: String { name ?? identifier.uuidString }
}

extension CBManagerState {
    var label: String {
        switch self {
        case .poweredOn: "on"
        case .poweredOff: "off"
        case .unauthorized: "not authorized"
        case .unsupported: "unsupported"
        case .resetting: "resetting"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }
}

extension CBCharacteristicProperties {
    var label: String {
        var parts: [String] = []
        if contains(.read) { parts.append("read") }
        if contains(.write) { parts.append("write") }
        if contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if contains(.notify) { parts.append("notify") }
        if contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Parses "1B 40 0A" / "1b400a" style hex. Returns nil on invalid input.
    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
