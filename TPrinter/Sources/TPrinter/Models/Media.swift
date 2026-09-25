import Foundation

/// How the printer finds the start of each label on the roll.
enum MediaSeparation: String, Codable, CaseIterable, Identifiable {
    /// Die-cut labels with a gap between them (TSPL `GAP`).
    case gap
    /// A printed black mark on the back of the liner (TSPL `BLINE`).
    case blackMark
    /// No separation: receipt-style continuous paper (TSPL `GAP 0,0`).
    case continuous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gap: "Gap"
        case .blackMark: "Black mark"
        case .continuous: "Continuous"
        }
    }
}

enum MediaMaterial: String, Codable, CaseIterable, Identifiable {
    case directThermal, thermalTransfer
    var id: String { rawValue }
    var title: String { self == .directThermal ? "Direct thermal" : "Thermal transfer" }
}

/// A paper roll the user prints on: label size, separation and defaults. Templates are made for a media.
struct Media: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var category: String
    var widthMM: Double
    var heightMM: Double
    /// Gap (or black-mark height) between labels, mm. Ignored for continuous media.
    var gapMM: Double = 2
    var separation: MediaSeparation = .gap
    /// Labels side by side on the roll (multi-across media).
    var labelsAcross: Int = 1
    var material: MediaMaterial = .directThermal
    /// TSPL DENSITY 0…15.
    var defaultDarkness: Int = 8
    /// TSPL SPEED, inches/second.
    var defaultSpeed: Int = 4

    var sizeText: String { MeasureUnit.current.size(widthMM, heightMM) }
    /// "30 × 15 mm, 2 mm gap" / "…, continuous" in the chosen unit.
    var detailText: String {
        let unit = MeasureUnit.current
        let separation = separation == .continuous ? "continuous" : "\(unit.length(gapMM)) \(self.separation == .gap ? "gap" : "black mark")"
        return "\(unit.size(widthMM, heightMM)), \(separation)"
    }

    /// Stock the RP310 commonly uses; seeded on first launch.
    static let starters: [Media] = [
        Media(name: "Product 30 × 15", category: "Product", widthMM: 30, heightMM: 15),
        Media(name: "Product 40 × 30", category: "Product", widthMM: 40, heightMM: 30),
        Media(name: "Price tag 50 × 30", category: "Product", widthMM: 50, heightMM: 30, gapMM: 3),
        Media(name: "Shipping 4 × 6 in", category: "Shipping", widthMM: 100, heightMM: 150, gapMM: 3),
        Media(name: "Shipping 3 × 3 in", category: "Shipping", widthMM: 76.2, heightMM: 76.2, gapMM: 3),
        Media(name: "Shipping 2 × 3 in", category: "Shipping", widthMM: 50.8, heightMM: 76.2, gapMM: 3),
        Media(name: "Parcel 60 × 40", category: "Shipping", widthMM: 60, heightMM: 40),
        Media(name: "Food date 40 × 20", category: "Food", widthMM: 40, heightMM: 20),
        Media(name: "Ring tag 22 × 10", category: "Jewelry", widthMM: 22, heightMM: 10, gapMM: 3),
    ]

    /// Starters added after the first release: existing libraries get each of these once (a user
    /// who later deletes one doesn't get it back).
    static let laterStarters = ["Shipping 3 × 3 in", "Shipping 2 × 3 in"]
}

/// How labels are laid out in one printed row / sheet. The design is made for one label; printing
/// repeats it in every cell. Rows × columns > 1 suits multi-across media.
struct LabelArrangement: Codable, Hashable {
    var rows: Int = 1
    var columns: Int = 1
    var marginTopMM: Double = 0
    var marginBottomMM: Double = 0
    var marginLeftMM: Double = 0
    var marginRightMM: Double = 0
    var spacingHorizontalMM: Double = 0
    var spacingVerticalMM: Double = 0

    static let single = LabelArrangement()

    /// One label, no margins: printing is exactly the designed label.
    var isSingle: Bool { self == .single }

    var cellCount: Int { max(rows, 1) * max(columns, 1) }

    func sheetSize(label: CGSize) -> CGSize {
        let cols = Double(max(columns, 1)), rws = Double(max(rows, 1))
        return CGSize(
            width: marginLeftMM + marginRightMM + cols * label.width + (cols - 1) * spacingHorizontalMM,
            height: marginTopMM + marginBottomMM + rws * label.height + (rws - 1) * spacingVerticalMM
        )
    }

    /// Top-left of every cell in mm, row by row.
    func cellOrigins(label: CGSize) -> [CGPoint] {
        (0..<max(rows, 1)).flatMap { r in
            (0..<max(columns, 1)).map { c in
                CGPoint(x: marginLeftMM + Double(c) * (label.width + spacingHorizontalMM),
                        y: marginTopMM + Double(r) * (label.height + spacingVerticalMM))
            }
        }
    }
}

extension LabelDocument {
    /// A blank label for `media`, with its defaults and the given arrangement.
    init(media: Media, arrangement: LabelArrangement = .single) {
        self.init()
        widthMM = media.widthMM
        heightMM = media.heightMM
        gapMM = media.gapMM
        separation = media.separation
        density = media.defaultDarkness
        speed = media.defaultSpeed
        mediaName = media.name
        mediaCategory = media.category
        self.arrangement = arrangement
        elements = []
    }

    /// The media name to show ("30 × 15 mm" when the label wasn't made from a saved media).
    var mediaTitle: String { mediaName.isEmpty ? MeasureUnit.current.size(widthMM, heightMM) : mediaName }
}

extension LabelArrangement {
    private enum CodingKeys: String, CodingKey {
        case rows, columns, marginTopMM, marginBottomMM, marginLeftMM, marginRightMM, spacingHorizontalMM, spacingVerticalMM
    }

    /// Missing keys fall back to defaults so templates keep opening as fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 1
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? 1
        marginTopMM = try c.decodeIfPresent(Double.self, forKey: .marginTopMM) ?? 0
        marginBottomMM = try c.decodeIfPresent(Double.self, forKey: .marginBottomMM) ?? 0
        marginLeftMM = try c.decodeIfPresent(Double.self, forKey: .marginLeftMM) ?? 0
        marginRightMM = try c.decodeIfPresent(Double.self, forKey: .marginRightMM) ?? 0
        spacingHorizontalMM = try c.decodeIfPresent(Double.self, forKey: .spacingHorizontalMM) ?? 0
        spacingVerticalMM = try c.decodeIfPresent(Double.self, forKey: .spacingVerticalMM) ?? 0
    }
}
