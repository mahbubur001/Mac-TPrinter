import Foundation

/// What a Bluetooth device is, for its icon and whether offering "Connect" makes sense.
enum DeviceKind: Equatable {
    case printer, headphones, speaker, keyboard, mouse, keyboardAndMouse, phone, computer, watch, unknown

    var systemImage: String {
        switch self {
        case .printer: "printer.fill"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        case .keyboard: "keyboard"
        case .mouse: "computermouse.fill"
        case .keyboardAndMouse: "keyboard.badge.ellipsis"
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .watch: "applewatch"
        case .unknown: "dot.radiowaves.left.and.right"
        }
    }

    var title: String {
        switch self {
        case .printer: "Printer"
        case .headphones: "Headphones"
        case .speaker: "Speaker"
        case .keyboard: "Keyboard"
        case .mouse: "Mouse"
        case .keyboardAndMouse: "Keyboard and mouse"
        case .phone: "Phone"
        case .computer: "Computer"
        case .watch: "Watch"
        case .unknown: "Bluetooth device"
        }
    }

    /// Known not-a-printer devices get no Connect button.
    var isKnownNonPrinter: Bool { self != .printer && self != .unknown }

    /// From a Classic Bluetooth Class of Device (major / minor), falling back to the name.
    static func classic(major: UInt32, minor: UInt32, name: String) -> DeviceKind {
        switch major {
        case 0x06: return .printer                                  // Imaging
        case 0x04:                                                   // Audio/Video
            return [0x05, 0x0A].contains(minor) ? .speaker : .headphones
        case 0x05:                                                   // Peripheral: keyboard / pointing bits
            switch minor & 0x30 {
            case 0x10: return .keyboard
            case 0x20: return .mouse
            case 0x30: return .keyboardAndMouse
            default: return named(name)
            }
        case 0x02: return .phone
        case 0x01: return .computer
        case 0x07: return .watch                                     // Wearable
        default: return named(name)
        }
    }

    /// From a Bluetooth LE advertisement (no device class): the name decides.
    static func ble(name: String, looksLikePrinter: Bool) -> DeviceKind {
        looksLikePrinter ? .printer : named(name)
    }

    /// Best guess from a device name.
    static func named(_ name: String) -> DeviceKind {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("printer", "rp3", "rp4", "rongta", "label", "tsc", "zebra", "xprinter") { return .printer }
        if has("keyboard") { return .keyboard }
        if has("mouse", "trackpad") { return .mouse }
        if has("airpods", "buds", "headphone", "headset", "liberty", "bullets", "earbud", "wh-", "wf-") { return .headphones }
        if has("speaker", "soundbar", "boom", "jbl") { return .speaker }
        if has("iphone", "phone", "galaxy", "pixel") { return .phone }
        if has("macbook", "imac", "mac mini", "laptop", "pc") { return .computer }
        if has("watch") { return .watch }
        return .unknown
    }
}
