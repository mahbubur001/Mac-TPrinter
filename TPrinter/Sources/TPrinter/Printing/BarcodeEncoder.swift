import CoreGraphics
import Foundation

/// 1-D barcode symbologies beyond Code 128 (which CoreImage draws). Each encoder returns the bar
/// pattern as modules (true = black, one module = the narrowest bar) plus the human-readable text
/// (with any check digit added).
enum BarcodeEncoder {
    struct Encoded: Equatable {
        let modules: [Bool]
        let text: String
    }

    enum EncodeError: LocalizedError, Equatable {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
    }

    static func encode(_ value: String, as type: BarcodeType) throws -> Encoded {
        switch type {
        case .code128: throw EncodeError.invalid("Code 128 is drawn by CoreImage")
        case .ean13: return try ean(value, digits: 12, name: "EAN-13")
        case .ean8: return try ean8(value)
        case .upcA: return try upcA(value)
        case .code39: return try code39(value)
        case .itf14: return try itf14(value)
        case .codabar: return try codabar(value)
        }
    }

    /// 1 px per module, 1 px tall, black on white (like CoreImage's Code 128 output).
    static func image(_ modules: [Bool]) -> CGImage? {
        let width = modules.count
        guard width > 0, let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for (i, black) in modules.enumerated() { pixels[i] = black ? 0 : 255 }
        return context.makeImage()
    }

    // MARK: Check digits

    /// GS1 mod-10 check digit (EAN, UPC, ITF-14): weights 3,1,3,1… from the right.
    static func gs1CheckDigit(_ digits: [Int]) -> Int {
        let sum = digits.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 3 : 1) }
        return (10 - sum % 10) % 10
    }

    private static func digits(_ value: String, count: Int, name: String) throws -> [Int] {
        let clean = value.filter { !$0.isWhitespace }
        guard clean.allSatisfy(\.isNumber) else { throw EncodeError.invalid("\(name) takes digits only.") }
        var d = clean.compactMap { $0.wholeNumberValue }
        if d.count == count { d.append(gs1CheckDigit(d)) }
        else if d.count == count + 1 {
            guard d.last == gs1CheckDigit(Array(d.dropLast())) else { throw EncodeError.invalid("The check digit is wrong for \(name).") }
        } else {
            throw EncodeError.invalid("\(name) needs \(count) digits (or \(count + 1) with the check digit).")
        }
        return d
    }

    // MARK: EAN / UPC

    private static let lCodes = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
    private static let gCodes = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
    private static let rCodes = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
    /// First digit of an EAN-13 → L/G pattern of the left six digits.
    private static let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]

    private static func bits(_ pattern: String) -> [Bool] { pattern.map { $0 == "1" } }

    private static func ean(_ value: String, digits count: Int, name: String) throws -> Encoded {
        let d = try digits(value, count: count, name: name)
        let parities = Array(parity[d[0]])
        var m = bits("101")
        for i in 1...6 { m += bits(parities[i - 1] == "L" ? lCodes[d[i]] : gCodes[d[i]]) }
        m += bits("01010")
        for i in 7...12 { m += bits(rCodes[d[i]]) }
        m += bits("101")
        return Encoded(modules: m, text: d.map(String.init).joined())
    }

    private static func ean8(_ value: String) throws -> Encoded {
        let d = try digits(value, count: 7, name: "EAN-8")
        var m = bits("101")
        for i in 0..<4 { m += bits(lCodes[d[i]]) }
        m += bits("01010")
        for i in 4..<8 { m += bits(rCodes[d[i]]) }
        m += bits("101")
        return Encoded(modules: m, text: d.map(String.init).joined())
    }

    /// UPC-A is EAN-13 with a leading 0.
    private static func upcA(_ value: String) throws -> Encoded {
        let d = try digits(value, count: 11, name: "UPC-A")
        let encoded = try ean("0" + d.map(String.init).joined(), digits: 12, name: "UPC-A")
        return Encoded(modules: encoded.modules, text: d.map(String.init).joined())
    }

    // MARK: Code 39

    /// Narrow/wide pattern per character: 9 elements (bar, space, …), "1" = wide.
    private static let code39Table: [Character: String] = [
        "0": "000110100", "1": "100100001", "2": "001100001", "3": "101100000", "4": "000110001", "5": "100110000",
        "6": "001110000", "7": "000100101", "8": "100100100", "9": "001100100", "A": "100001001", "B": "001001001",
        "C": "101001000", "D": "000011001", "E": "100011000", "F": "001011000", "G": "000001101", "H": "100001100",
        "I": "001001100", "J": "000011100", "K": "100000011", "L": "001000011", "M": "101000010", "N": "000010011",
        "O": "100010010", "P": "001010010", "Q": "000000111", "R": "100000110", "S": "001000110", "T": "000010110",
        "U": "110000001", "V": "011000001", "W": "111000000", "X": "010010001", "Y": "110010000", "Z": "011010000",
        "-": "010000101", ".": "110000100", " ": "011000100", "$": "010101000", "/": "010100010", "+": "010001010",
        "%": "000101010", "*": "010010100",
    ]

    private static func code39(_ value: String) throws -> Encoded {
        let text = value.uppercased()
        guard !text.isEmpty, text.allSatisfy({ $0 != "*" && code39Table[$0] != nil }) else {
            throw EncodeError.invalid("Code 39 takes capital letters, digits and - . $ / + % space.")
        }
        var m: [Bool] = []
        for (index, char) in ("*" + text + "*").enumerated() {
            if index > 0 { m.append(false) } // narrow gap between characters
            for (i, width) in code39Table[char]!.enumerated() {
                m += Array(repeating: i % 2 == 0, count: width == "1" ? 3 : 1)
            }
        }
        return Encoded(modules: m, text: text)
    }

    // MARK: ITF-14 (interleaved 2 of 5)

    private static let itfTable = ["00110", "10001", "01001", "11000", "00101", "10100", "01100", "00011", "10010", "01010"]

    private static func itf14(_ value: String) throws -> Encoded {
        let d = try digits(value, count: 13, name: "ITF-14")
        var m = bits("1010") // start: narrow bar, space, bar, space
        for pair in stride(from: 0, to: d.count, by: 2) {
            let bars = Array(itfTable[d[pair]]), spaces = Array(itfTable[d[pair + 1]])
            for i in 0..<5 {
                m += Array(repeating: true, count: bars[i] == "1" ? 3 : 1)
                m += Array(repeating: false, count: spaces[i] == "1" ? 3 : 1)
            }
        }
        m += [true, true, true, false, true] // stop: wide bar, space, bar
        return Encoded(modules: m, text: d.map(String.init).joined())
    }

    // MARK: Codabar

    /// 7 elements per character (bar, space, …), "1" = wide.
    private static let codabarTable: [Character: String] = [
        "0": "0000011", "1": "0000110", "2": "0001001", "3": "1100000", "4": "0010010", "5": "1000010",
        "6": "0100001", "7": "0100100", "8": "0110000", "9": "1001000", "-": "0001100", "$": "0011000",
        ":": "1000101", "/": "1010001", ".": "1010100", "+": "0010101", "A": "0011010", "B": "0101001",
        "C": "0001011", "D": "0001110",
    ]

    private static func codabar(_ value: String) throws -> Encoded {
        var text = value.uppercased().filter { !$0.isWhitespace }
        let stops: Set<Character> = ["A", "B", "C", "D"]
        if let first = text.first, !stops.contains(first) { text = "A" + text }
        if let last = text.last, !stops.contains(last) || text.count == 1 { text += "A" }
        guard text.count >= 3, text.allSatisfy({ codabarTable[$0] != nil }),
              text.dropFirst().dropLast().allSatisfy({ !stops.contains($0) }) else {
            throw EncodeError.invalid("Codabar takes digits and - $ : / . +, between start/stop letters A–D.")
        }
        var m: [Bool] = []
        for (index, char) in text.enumerated() {
            if index > 0 { m.append(false) }
            for (i, width) in codabarTable[char]!.enumerated() {
                m += Array(repeating: i % 2 == 0, count: width == "1" ? 3 : 1)
            }
        }
        return Encoded(modules: m, text: String(text.dropFirst().dropLast()))
    }
}
