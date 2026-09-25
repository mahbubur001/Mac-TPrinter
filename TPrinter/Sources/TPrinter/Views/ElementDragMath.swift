import CoreGraphics

/// Position math for dragging elements on the preview. All values in millimetres.
enum ElementDragMath {
    /// Matches the inspector's X/Y stepper step.
    static let gridMM = 0.5

    /// New top-left position after dragging by `translationDots`.
    /// - Parameters:
    ///   - sizeMM: rendered element size; used to keep the element fully on the label.
    ///   - snaps: round to `gridMM` (the Option key turns this off).
    static func position(
        start: CGPoint,
        translationDots: CGSize,
        sizeMM: CGSize,
        labelMM: CGSize,
        snaps: Bool
    ) -> CGPoint {
        var x = start.x + translationDots.width / dotsPerMM
        var y = start.y + translationDots.height / dotsPerMM
        if snaps {
            x = (x / gridMM).rounded() * gridMM
            y = (y / gridMM).rounded() * gridMM
        }
        return CGPoint(
            x: clamp(x, upper: labelMM.width - sizeMM.width),
            y: clamp(y, upper: labelMM.height - sizeMM.height)
        )
    }

    /// Arrow-key step: 0.5 mm, ⇧ 5 mm, ⌥ one printer dot.
    static func nudgeStepMM(shift: Bool, option: Bool) -> Double {
        if option { return 1 / dotsPerMM }
        return shift ? 5 : gridMM
    }

    /// New position after an arrow key; no snapping, so off-grid positions move by exactly one step.
    static func nudged(
        _ start: CGPoint,
        dx: Double, dy: Double, stepMM: Double,
        sizeMM: CGSize, labelMM: CGSize
    ) -> CGPoint {
        position(start: start,
                 translationDots: CGSize(width: dx * stepMM * dotsPerMM, height: dy * stepMM * dotsPerMM),
                 sizeMM: sizeMM, labelMM: labelMM, snaps: false)
    }

    /// Keeps the value in 0…upper; an element bigger than the label is pinned at 0.
    private static func clamp(_ value: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, 0), max(upper, 0))
    }
}
