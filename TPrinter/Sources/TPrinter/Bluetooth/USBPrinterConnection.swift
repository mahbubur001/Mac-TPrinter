import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// A USB printer: any device with a USB printer-class interface (class 7), e.g. the RP310 by cable.
struct USBPrinterInfo: Identifiable, Hashable {
    /// Stable per printer: the serial number, or the USB location when there's none.
    let id: String
    let name: String
    let vendorID: Int
    let productID: Int
}

/// Sends print jobs over USB with IOUSBHost: opens the printer interface, writes the job to its bulk
/// OUT endpoint, then briefly listens on bulk IN for the printer's status (the RP310 answers
/// `1F 1B 1A 04 05 01 80 00 00 00` after a job over Bluetooth; over USB it's logged if it comes).
/// The interface is opened per job and released after, so CUPS (System Settings' printer) can still
/// use the printer between jobs.
final class USBPrinterConnection {
    let info: USBPrinterInfo
    var onReceive: ((Data) -> Void)?
    var onEvent: ((String) -> Void)?

    private let queue = DispatchQueue(label: "TPrinter.usb")
    /// Bytes per bulk write; progress is reported between chunks.
    private static let chunkSize = 16 * 1024
    /// How long to wait for the printer's status after the data is out.
    private static let statusWait: TimeInterval = 2.5

    init(info: USBPrinterInfo) {
        self.info = info
    }

    enum USBError: LocalizedError {
        case notFound(String), noBulkOut, io(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let name): "\(name) isn't connected by USB any more."
            case .noBulkOut: "The printer's USB interface has no data endpoint."
            case .io(let message): "USB: \(message)"
            }
        }
    }

    // MARK: Discovery

    /// Matching dictionary for printer-class USB interfaces.
    private static func matching() -> CFMutableDictionary {
        let dictionary = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        dictionary["bInterfaceClass"] = 7 // printer class
        return dictionary as CFMutableDictionary
    }

    /// Printers plugged in right now.
    static func connectedPrinters() -> [USBPrinterInfo] {
        var result: [USBPrinterInfo] = []
        forEachInterface { _, info in
            result.append(info)
            return false
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }

    private static func forEachInterface(_ body: (io_service_t, USBPrinterInfo) -> Bool?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching(), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let stop = body(service, info(for: service)) == true
            IOObjectRelease(service)
            if stop { break }
        }
    }

    /// Name / ids from the interface's parent device.
    private static func info(for interface: io_service_t) -> USBPrinterInfo {
        var device: io_registry_entry_t = 0
        IORegistryEntryGetParentEntry(interface, kIOServicePlane, &device)
        defer { if device != 0 { IOObjectRelease(device) } }
        func property(_ key: String) -> Any? {
            let entry = device != 0 ? device : interface
            return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let name = (property("USB Product Name") as? String) ?? (property("kUSBProductString") as? String) ?? "USB Printer"
        let serial = (property("USB Serial Number") as? String) ?? (property("kUSBSerialNumberString") as? String)
        let location = (property("locationID") as? Int) ?? 0
        let vendor = (property("idVendor") as? Int) ?? 0
        let product = (property("idProduct") as? Int) ?? 0
        return USBPrinterInfo(id: serial.map { "usb-\($0)" } ?? "usb-location-\(location)", name: name,
                              vendorID: vendor, productID: product)
    }

    /// Calls `onChange` (main queue) whenever a USB printer is plugged in or removed. Keep the token.
    static func watch(_ onChange: @escaping () -> Void) -> AnyObject {
        USBWatcher(matching: matching(), onChange: onChange)
    }

    // MARK: Printing

    /// Sends one job. `progress` (0…1) and `completion` (nil = sent) are called on the main queue.
    func send(_ data: Data, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        let info = info
        queue.async { [weak self] in
            do {
                try self?.write(data, info: info) { fraction in DispatchQueue.main.async { progress(fraction) } }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private func write(_ data: Data, info: USBPrinterInfo, progress: (Double) -> Void) throws {
        var service: io_service_t = 0
        Self.forEachInterface { candidate, candidateInfo in
            guard candidateInfo.id == info.id else { return false }
            IOObjectRetain(candidate)
            service = candidate
            return true
        }
        guard service != 0 else { throw USBError.notFound(info.name) }
        defer { IOObjectRelease(service) }

        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: queue, interestHandler: nil)
        } catch {
            throw USBError.io("couldn't open the printer (\(error.localizedDescription)). Is another app printing to it?")
        }
        defer { interface.destroy() }

        var outAddress: Int?, inAddress: Int?
        var current: UnsafePointer<IOUSBDescriptorHeader>?
        while let endpoint = IOUSBGetNextEndpointDescriptor(interface.configurationDescriptor, interface.interfaceDescriptor, current) {
            let address = Int(endpoint.pointee.bEndpointAddress)
            if endpoint.pointee.bmAttributes & 0x03 == 0x02 { // bulk
                if address & 0x80 == 0 { outAddress = outAddress ?? address } else { inAddress = inAddress ?? address }
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let outAddress else { throw USBError.noBulkOut }
        let out = try interface.copyPipe(withAddress: outAddress)
        onEvent.map { handler in DispatchQueue.main.async { handler("USB interface open (bulk OUT 0x\(String(outAddress, radix: 16)))") } }

        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.chunkSize, data.count)
            let chunk = NSMutableData(data: data.subdata(in: offset..<end))
            var sent = 0
            do {
                try out.__sendIORequest(with: chunk, bytesTransferred: &sent, completionTimeout: 15)
            } catch {
                throw USBError.io("sending failed after \(offset) bytes (\(error.localizedDescription))")
            }
            offset += max(sent, 0) == 0 ? chunk.length : sent
            progress(Double(offset) / Double(max(data.count, 1)))
        }

        // The printer's answer, if it sends one over USB (logged; not required).
        if let inAddress, let input = try? interface.copyPipe(withAddress: inAddress) {
            let buffer = NSMutableData(length: 64)!
            var received = 0
            if (try? input.__sendIORequest(with: buffer, bytesTransferred: &received, completionTimeout: Self.statusWait)) != nil, received > 0 {
                let reply = Data(bytes: buffer.bytes, count: received)
                onReceive.map { handler in DispatchQueue.main.async { handler(reply) } }
            }
        }
    }
}

/// IOKit plug / unplug notifications for USB printer interfaces.
private final class USBWatcher {
    private let port: IONotificationPortRef
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private let onChange: () -> Void

    init(matching: CFMutableDictionary, onChange: @escaping () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            // Drain the iterator (required to re-arm the notification), then report.
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let context else { return }
            Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, (matching as NSDictionary).mutableCopy() as! CFMutableDictionary,
                                         callback, context, &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, (matching as NSDictionary).mutableCopy() as! CFMutableDictionary,
                                         callback, context, &removed)
        while case let service = IOIteratorNext(added), service != 0 { IOObjectRelease(service) }
        while case let service = IOIteratorNext(removed), service != 0 { IOObjectRelease(service) }
    }

    deinit {
        IOObjectRelease(added)
        IOObjectRelease(removed)
        IONotificationPortDestroy(port)
    }
}
