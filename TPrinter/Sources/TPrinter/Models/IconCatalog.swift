import AppKit

/// SF Symbols that are useful on labels, grouped the way people look for them.
/// Any other SF Symbol name can be typed in the icon search field.
enum IconCatalog {
    struct Group: Identifiable {
        let name: String
        let symbols: [String]
        var id: String { name }
    }

    static let groups: [Group] = [
        Group(name: "Handling", symbols: [
            "arrow.up", "arrow.up.to.line", "wineglass", "umbrella", "drop", "flame", "snowflake",
            "thermometer.medium", "sun.max", "bolt", "exclamationmark.triangle", "hand.raised",
            "scalemass", "shippingbox", "arrow.3.trianglepath", "leaf",
        ]),
        Group(name: "Food & drink", symbols: [
            "fork.knife", "cup.and.saucer", "mug", "takeoutbag.and.cup.and.straw", "carrot",
            "birthday.cake", "fish", "leaf.circle", "checkmark.seal", "clock",
        ]),
        Group(name: "Shop", symbols: [
            "tag", "cart", "bag", "gift", "creditcard", "percent", "star", "heart", "sparkles", "hand.thumbsup",
        ]),
        Group(name: "Contact & info", symbols: [
            "phone", "envelope", "globe", "location", "house", "building.2", "person", "calendar",
            "info.circle", "questionmark.circle", "wifi", "qrcode", "barcode", "lock", "key",
        ]),
    ]
    .map { Group(name: $0.name, symbols: $0.symbols.filter(isValid)) } // drop any this macOS lacks

    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Catalogue symbols whose name contains `query`, plus `query` itself if it's any valid SF Symbol.
    static func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var results = groups.flatMap(\.symbols).filter { $0.contains(q) }
        if isValid(q), !results.contains(q) { results.insert(q, at: 0) }
        return results
    }
}
