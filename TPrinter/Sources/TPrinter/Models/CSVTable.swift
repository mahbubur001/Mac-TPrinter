import Foundation

/// A CSV file: first row = column names, the rest = one record per label.
struct CSVTable: Equatable {
    var headers: [String]
    var rows: [[String]]

    enum ParseError: LocalizedError {
        case empty
        case unreadable

        var errorDescription: String? {
            switch self {
            case .empty: "The CSV file has no header row."
            case .unreadable: "The file isn't readable text (try saving it as “CSV UTF-8”)."
            }
        }
    }

    /// Column name → value for one row. Keys are matched case-insensitively by `LabelFields`.
    func record(at index: Int) -> [String: String] {
        Dictionary(zip(headers, rows[index]), uniquingKeysWith: { first, _ in first })
    }

    static func load(_ url: URL) throws -> CSVTable {
        let data = try Data(contentsOf: url)
        // Excel on Mac/Windows may save as UTF-8 (with BOM), UTF-16 or Windows-1252.
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) { return try parse(text) }
        }
        throw ParseError.unreadable
    }

    /// RFC 4180-style parsing: quoted fields, `""` escapes, delimiters and newlines inside quotes, CRLF.
    /// The delimiter (comma, semicolon or tab) is detected from the header line.
    static func parse(_ text: String) throws -> CSVTable {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let delimiter = detectDelimiter(text)

        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil

        func endField() { record.append(field); field = "" }
        func endRecord() {
            endField()
            if !(record.count == 1 && record[0].trimmingCharacters(in: .whitespaces).isEmpty) { records.append(record) }
            record = []
        }

        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" && field.isEmpty {
                inQuotes = true
            } else if char == delimiter {
                endField()
            } else if char == "\n" || char == "\r\n" || char == "\r" {
                endRecord()
            } else {
                field.append(char)
            }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }

        guard let headerRow = records.first else { throw ParseError.empty }
        var seen = Set<String>()
        let headers = headerRow.enumerated().map { index, raw -> String in
            var name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || seen.contains(name.lowercased()) { name = "Column \(index + 1)" }
            seen.insert(name.lowercased())
            return name
        }
        // Pad short rows / trim long ones so every row lines up with the headers.
        let rows = records.dropFirst().map { row in
            Array((row + Array(repeating: "", count: max(0, headers.count - row.count))).prefix(headers.count))
        }
        return CSVTable(headers: headers, rows: rows)
    }

    private static func detectDelimiter(_ text: String) -> Character {
        let header = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        let candidates: [Character] = [",", ";", "\t"]
        return candidates.max { a, b in header.filter { $0 == a }.count < header.filter { $0 == b }.count } ?? ","
    }
}
