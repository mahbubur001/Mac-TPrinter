import Foundation

/// `{{column}}` placeholders in element content, filled from a CSV row for batch printing.
enum LabelFields {
    private static let pattern = #/\{\{\s*([^{}]+?)\s*\}\}/#

    /// Field names used anywhere in the document, in first-use order.
    static func names(in document: LabelDocument) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for element in document.elements {
            for match in element.content.matches(of: pattern) {
                let name = String(match.output.1)
                if seen.insert(name.lowercased()).inserted { names.append(name) }
            }
        }
        return names
    }

    /// Field names that have no matching column (case-insensitive).
    static func missing(in document: LabelDocument, columns: [String]) -> [String] {
        let available = Set(columns.map { $0.lowercased() })
        return names(in: document).filter { !available.contains($0.lowercased()) }
    }

    /// The document with every `{{name}}` replaced by the row's value. Unknown names stay as written
    /// so they're visible in the preview.
    static func fill(_ document: LabelDocument, with record: [String: String]) -> LabelDocument {
        let values = Dictionary(record.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        var filled = document
        for index in filled.elements.indices {
            filled.elements[index].content = filled.elements[index].content.replacing(pattern) { match in
                values[String(match.output.1).lowercased()] ?? String(match.output.0)
            }
        }
        return filled
    }
}
