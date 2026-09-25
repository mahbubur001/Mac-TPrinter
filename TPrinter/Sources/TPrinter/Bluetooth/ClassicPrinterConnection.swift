import Foundation
import IOBluetooth

/// A paired Classic Bluetooth printer, e.g. `RP310-D157`.
struct ClassicPrinterInfo: Identifiable, Hashable {
    /// Bluetooth address, e.g. "00-11-22-33-44-55".
    let id: String
    let name: String
    let isConnected: Bool
    /// Bluetooth major device class "Imaging" (printers, scanners).
    let isImagingDevice: Bool
    /// Bluetooth Class of Device (major / minor), used to pick the right icon.
    var majorClass: UInt32 = 0
    var minorClass: UInt32 = 0
}

/// Sends print jobs to a Classic Bluetooth printer over an RFCOMM channel opened with IOBluetooth.
///
/// RP310 behaviour this is built around (measured 2026-09-24):
/// - Do not use the `/dev/cu.<printer>` serial node: writes succeed but never reach the printer.
/// - One channel can carry any number of jobs; the printer keeps it open.
/// - ~1.5 s after finishing a job the printer sends a 10-byte status (`1F 1B 1A 04 05 01 80 00 00 00`),
///   used here as the "job done" signal before the next job is sent.
/// - Opening a channel occasionally hangs, and hung/aborted opens make the printer feed a blank
///   label. So the channel is opened once and reused, and only closed after `idleTimeout`.
@MainActor
final class ClassicPrinterConnection: NSObject {
    enum ConnectionError: LocalizedError {
        case deviceNotFound(String)
        case sdpFailed(IOReturn)
        case noSerialService
        case openFailed(IOReturn)
        case writeFailed(IOReturn)
        case closedEarly

        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let address): "Printer \(address) is not paired with this Mac."
            case .sdpFailed(let status): "Could not read the printer's Bluetooth services (\(status.hex))."
            case .noSerialService: "The printer has no Bluetooth serial service."
            case .openFailed(let status): "Could not open the printer channel (\(status.hex)). Is the printer on and in range?"
            case .writeFailed(let status): "Bluetooth write failed (\(status.hex))."
            case .closedEarly: "The printer closed the connection before the job was sent."
            }
        }
    }

    /// First bytes of the printer's status message.
    static let statusPrefix: [UInt8] = [0x1F, 0x1B, 0x1A]
    /// How long to wait for the status after a job before treating it as done anyway.
    private static let statusTimeout: TimeInterval = 8
    /// Close an unused channel after this long so phones / other apps can reach the printer.
    static let idleTimeout: TimeInterval = 120
    /// Opens usually complete in ~0.5 s, but some never complete; abandon an attempt after
    /// `openTimeout` and retry.
    private static let openAttempts = 4
    private static let openTimeout: TimeInterval = 3
    private static let openRetryDelay: TimeInterval = 1

    let address: String
    var name: String { device.name ?? address }
    /// Called with printer → Mac bytes, for the log.
    var onReceive: ((Data) -> Void)?
    /// Called when the channel opens or closes, for the log.
    var onChannelEvent: ((String) -> Void)?

    private let device: IOBluetoothDevice
    private var channelID: BluetoothRFCOMMChannelID?
    private var channel: IOBluetoothRFCOMMChannel?
    private var isChannelOpen = false
    private var idleWork: DispatchWorkItem?

    // Opening
    private var isWaitingForOpen = false
    private var openAttempt = 0
    private var sdpContinuation: ((IOReturn) -> Void)?

    // Current job
    private var bytes: [UInt8] = []
    private var offset = 0
    private var awaitingStatus = false
    private var statusWork: DispatchWorkItem?
    private var progress: ((Double) -> Void)?
    private var completion: ((Error?) -> Void)?

    init(address: String) throws {
        guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else {
            throw ConnectionError.deviceNotFound(address)
        }
        self.address = address
        self.device = device
    }

    static func pairedPrinters() -> [ClassicPrinterInfo] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { device in
            // Class 0 = BLE-only pairing (e.g. "RP310-D157-BLE"): no RFCOMM, handled by CoreBluetooth instead.
            guard let address = device.addressString, device.classOfDevice != 0 else { return nil }
            return ClassicPrinterInfo(id: address.uppercased(), name: device.name ?? address, isConnected: device.isConnected(),
                                      isImagingDevice: device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorImaging),
                                      majorClass: device.deviceClassMajor, minorClass: device.deviceClassMinor)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var isBusy: Bool { completion != nil }

    /// Streams `data` over the (reused) channel and completes when the printer reports the job done.
    func send(_ data: Data, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        precondition(!isBusy, "one job at a time")
        idleWork?.cancel()
        bytes = [UInt8](data)
        offset = 0
        self.progress = progress
        self.completion = completion

        if isChannelOpen {
            writeNextChunk()
            return
        }
        openAttempt = 0
        resolveChannelID { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): finish(error)
            case .success(let id): openChannel(id)
            }
        }
    }

    /// Closes the channel (on disconnect / app quit).
    func close() {
        idleWork?.cancel()
        if isBusy { finish(ConnectionError.closedEarly) }
        closeChannel(reason: "closed")
    }

    // MARK: - Opening

    private func resolveChannelID(_ done: @escaping (Result<BluetoothRFCOMMChannelID, Error>) -> Void) {
        if let channelID { return done(.success(channelID)) }
        if let id = Self.serialChannel(in: device) {
            channelID = id
            return done(.success(id))
        }
        sdpContinuation = { [weak self] status in
            guard let self else { return }
            guard status == kIOReturnSuccess else { return done(.failure(ConnectionError.sdpFailed(status))) }
            guard let id = Self.serialChannel(in: device) else { return done(.failure(ConnectionError.noSerialService)) }
            channelID = id
            done(.success(id))
        }
        let status = device.performSDPQuery(self)
        if status != kIOReturnSuccess { sdpQueryComplete(device, status: status) }
    }

    private func openChannel(_ id: BluetoothRFCOMMChannelID) {
        openAttempt += 1
        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        guard status == kIOReturnSuccess else { return openFailed(status, channel: id) }
        channel = opened
        isWaitingForOpen = true
        let attempt = openAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openTimeout) { [weak self] in
            guard let self, isWaitingForOpen, openAttempt == attempt, let stalled = channel else { return }
            isWaitingForOpen = false
            stalled.setDelegate(nil)
            stalled.close()
            channel = nil
            onChannelEvent?("Channel open timed out (attempt \(attempt)).")
            openFailed(kIOReturnTimeout, channel: id)
        }
    }

    private func openFailed(_ status: IOReturn, channel id: BluetoothRFCOMMChannelID) {
        channel = nil
        guard openAttempt < Self.openAttempts else {
            channelID = nil // re-discover next time in case the channel number changed
            return finish(ConnectionError.openFailed(status))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openRetryDelay) { [weak self] in
            guard let self, completion != nil else { return }
            openChannel(id)
        }
    }

    // MARK: - Job

    /// Writes one MTU-sized chunk per main-loop turn so the UI stays responsive.
    private func writeNextChunk() {
        guard let channel, completion != nil else { return }
        guard offset < bytes.count else { return waitForStatus() }
        let length = min(Int(channel.getMTU()), bytes.count - offset, Int(UInt16.max))
        let status = bytes.withUnsafeMutableBytes { buffer in
            channel.writeSync(buffer.baseAddress! + offset, length: UInt16(length))
        }
        guard status == kIOReturnSuccess else {
            closeChannel(reason: "write failed")
            return finish(ConnectionError.writeFailed(status))
        }
        offset += length
        progress?(Double(offset) / Double(bytes.count))
        DispatchQueue.main.async { [weak self] in self?.writeNextChunk() }
    }

    private func waitForStatus() {
        awaitingStatus = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, awaitingStatus else { return }
            onChannelEvent?("No status from printer after \(Int(Self.statusTimeout)) s; continuing.")
            finish(nil)
        }
        statusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusTimeout, execute: work)
    }

    private func finish(_ error: Error?) {
        guard let completion else { return }
        self.completion = nil
        isWaitingForOpen = false
        awaitingStatus = false
        statusWork?.cancel()
        progress = nil
        bytes = []
        scheduleIdleClose()
        completion(error)
    }

    private func scheduleIdleClose() {
        idleWork?.cancel()
        guard isChannelOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isBusy else { return }
            closeChannel(reason: "idle for \(Int(Self.idleTimeout)) s")
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    private func closeChannel(reason: String) {
        guard let channel else { return }
        channel.setDelegate(nil)
        channel.close()
        self.channel = nil
        if isChannelOpen { onChannelEvent?("Channel \(reason).") }
        isChannelOpen = false
    }

    private static func serialChannel(in device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        func channel(of record: IOBluetoothSDPServiceRecord) -> BluetoothRFCOMMChannelID? {
            var id: BluetoothRFCOMMChannelID = 0
            return record.getRFCOMMChannelID(&id) == kIOReturnSuccess ? id : nil
        }
        // Prefer the Serial Port Profile record (channel 1 on the RP310), else any RFCOMM service.
        let serial = records.first { ($0.getServiceName() ?? "").localizedCaseInsensitiveContains("serial") }
        return serial.flatMap(channel(of:)) ?? records.lazy.compactMap(channel(of:)).first
    }
}

// MARK: - IOBluetooth callbacks (delivered on the main run loop)

extension ClassicPrinterConnection: IOBluetoothRFCOMMChannelDelegate {
    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        MainActor.assumeIsolated {
            let continuation = sdpContinuation
            sdpContinuation = nil
            continuation?(status)
        }
    }

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated {
            guard rfcommChannel === channel, isWaitingForOpen else { return }
            isWaitingForOpen = false
            if error == kIOReturnSuccess {
                isChannelOpen = true
                onChannelEvent?("Channel open (attempt \(openAttempt)).")
                writeNextChunk()
            } else if let id = channelID {
                openFailed(error, channel: id)
            } else {
                finish(ConnectionError.openFailed(error))
            }
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let data = Data(bytes: dataPointer, count: dataLength)
        MainActor.assumeIsolated {
            onReceive?(data)
            if awaitingStatus, data.starts(with: Self.statusPrefix) { finish(nil) }
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated {
            guard rfcommChannel === channel else { return }
            channel = nil
            isChannelOpen = false
            onChannelEvent?("Printer closed the channel.")
            idleWork?.cancel()
            guard isBusy else { return }
            // All bytes out = the printer has the job; otherwise it was cut off.
            finish(offset >= bytes.count && !bytes.isEmpty ? nil : ConnectionError.closedEarly)
        }
    }
}

private extension IOReturn {
    var hex: String { String(format: "0x%08X", UInt32(bitPattern: self)) }
}
