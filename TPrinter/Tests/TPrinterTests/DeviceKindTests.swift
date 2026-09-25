import Testing
@testable import TPrinter

/// Class-of-Device values from the devices actually paired with this Mac (IOBluetooth pairedDevices).
struct DeviceKindTests {
    /// Splits a raw Class of Device the way IOBluetooth's deviceClassMajor / deviceClassMinor do.
    private func kind(_ cod: UInt32, _ name: String) -> DeviceKind {
        DeviceKind.classic(major: (cod >> 8) & 0x1F, minor: (cod >> 2) & 0x3F, name: name)
    }

    @Test func pairedDevicesGetTheRightKind() {
        #expect(kind(272_000, "RP310-D157") == .printer)                        // Imaging
        #expect(kind(9536, "Mahbubur Rahman’s Magic Keyboard") == .keyboard)     // Peripheral, keyboard
        #expect(kind(9600, "Mahbubur Rahman’s Mouse") == .mouse)                 // Peripheral, pointing
        #expect(kind(2_360_324, "OnePlus BulletsWireless Z2 ANC") == .headphones) // Audio, headset
        #expect(kind(2_360_324, "soundcore Liberty 4 Pro") == .headphones)
        #expect(kind(2_360_340, "MI BT 18I") == .speaker)                        // Audio, loudspeaker
    }

    @Test func bleUsesTheNameOrPrinterHint() {
        #expect(DeviceKind.ble(name: "RP310-D157-BLE", looksLikePrinter: true) == .printer)
        #expect(DeviceKind.ble(name: "Galaxy Buds2", looksLikePrinter: false) == .headphones)
        #expect(DeviceKind.ble(name: "GR-AC_10001_09_ca99_SC", looksLikePrinter: false) == .unknown)
    }

    @Test func onlyUnknownDevicesOfferTryConnecting() {
        #expect(DeviceKind.headphones.isKnownNonPrinter)
        #expect(!DeviceKind.unknown.isKnownNonPrinter)
        #expect(!DeviceKind.printer.isKnownNonPrinter)
    }
}
