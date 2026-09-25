import Foundation
import SwiftUI

/// The unit sizes are shown and typed in (Settings › General › Units). Labels are always stored in
/// millimetres; this only converts for display and input.
enum MeasureUnit: String, CaseIterable, Identifiable {
    case mm, cm, inch = "in"

    static let defaultsKey = "measureUnit"

    /// The unit chosen in Settings (millimetres by default).
    static var current: MeasureUnit {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MeasureUnit.init(rawValue:)) ?? .mm
    }

    var id: String { rawValue }
    var symbol: String { rawValue }

    var title: String {
        switch self {
        case .mm: "Millimetres"
        case .cm: "Centimetres"
        case .inch: "Inches"
        }
    }

    /// Millimetres in one of this unit.
    var millimetres: Double {
        switch self {
        case .mm: 1
        case .cm: 10
        case .inch: 25.4
        }
    }

    /// Decimal places worth showing (a printer dot is 0.125 mm).
    var decimals: Int {
        switch self {
        case .mm: 1
        case .cm: 2
        case .inch: 2
        }
    }

    func value(_ mm: Double) -> Double { mm / millimetres }
    func mm(_ value: Double) -> Double { value * millimetres }

    /// A − / + step in this unit for a step of `mm` millimetres, rounded to something tidy
    /// (1 mm → 0.1 cm or 1/16 in).
    func step(forMM mm: Double) -> Double {
        switch self {
        case .mm: return mm
        case .cm: return mm / 10
        case .inch: return mm >= 1 ? 0.0625 : mm >= 0.5 ? 0.03125 : 0.01
        }
    }

    /// "30", "3", "1.18" — trailing zeros dropped.
    func number(_ mm: Double) -> String {
        value(mm).formatted(.number.precision(.fractionLength(0...decimals)))
    }

    /// "30 mm", "3 cm", "1.18 in".
    func length(_ mm: Double) -> String { "\(number(mm)) \(symbol)" }

    /// "30 × 15 mm".
    func size(_ width: Double, _ height: Double) -> String { "\(number(width)) × \(number(height)) \(symbol)" }

    /// "30×15mm" (tight spaces, for cards and titles).
    func compactSize(_ width: Double, _ height: Double) -> String {
        "\(number(width))×\(number(height))\(self == .inch ? " in" : symbol)"
    }
}

extension MeasureUnit {
    /// A field's value in this unit, writing millimetres back.
    func binding(_ mm: Binding<Double>) -> Binding<Double> {
        Binding(get: { (value(mm.wrappedValue) * 10_000).rounded() / 10_000 }, set: { mm.wrappedValue = self.mm($0) })
    }

    /// `mm` moved one − / + step (`direction` −1 or 1) on this unit's grid, kept in `range` (mm).
    func stepped(_ mm: Double, stepMM: Double, direction: Double, in range: ClosedRange<Double>) -> Double {
        let unitStep = step(forMM: stepMM)
        let next = ((value(mm) / unitStep).rounded() + direction) * unitStep
        return min(max(self.mm(next), range.lowerBound), range.upperBound)
    }

    /// Number format for fields: enough decimals for this unit, none forced.
    var fieldFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...(self == .mm ? 2 : 3)))
    }
}
