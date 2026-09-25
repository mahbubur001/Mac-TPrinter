import Foundation

/// Element commands shared by the canvas, the layers list and the inspector. Each is one undo step.
extension LabelSession {
    /// Copies the element 1 mm down-right, on top of everything. Returns the copy's id.
    @discardableResult
    func duplicateElement(_ id: LabelElement.ID) -> LabelElement.ID? {
        guard let original = document.elements.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.x += 1
        copy.y += 1
        perform("Duplicate") { $0.elements.append(copy) }
        return copy.id
    }

    /// After printing `labels` labels, counters continue from the next number (one undo step).
    func advanceCounters(by labels: Int) {
        guard labels > 0, document.hasCounters else { return }
        perform("Advance Counter") { $0 = $0.advancingCounters(by: labels) }
    }

    // MARK: Clipboard

    func copyElement(_ id: LabelElement.ID) {
        guard let element = document.elements.first(where: { $0.id == id }) else { return }
        ElementClipboard.copy([element])
    }

    func cutElement(_ id: LabelElement.ID) {
        guard let element = document.elements.first(where: { $0.id == id }) else { return }
        ElementClipboard.copy([element])
        perform("Cut \(element.kind.title)") { $0.elements.removeAll { $0.id == id } }
    }

    /// Adds the copied elements on top; returns the last one's id (to select it).
    @discardableResult
    func pasteElements() -> LabelElement.ID? {
        guard let copied = ElementClipboard.elements() else { return nil }
        let pasted = ElementClipboard.pasteable(copied, into: document)
        perform(pasted.count == 1 ? "Paste \(pasted[0].kind.title)" : "Paste") { $0.elements.append(contentsOf: pasted) }
        return pasted.last?.id
    }

    func copyStyle(_ id: LabelElement.ID) {
        guard let element = document.elements.first(where: { $0.id == id }) else { return }
        ElementClipboard.copyStyle(of: element)
    }

    /// Applies the copied style to the element; false when there's none or it doesn't fit this kind.
    @discardableResult
    func pasteStyle(onto id: LabelElement.ID) -> Bool {
        guard let style = ElementClipboard.style(),
              let index = document.elements.firstIndex(where: { $0.id == id }),
              document.elements[index].acceptsStyle(of: style) else { return false }
        perform("Paste Style") { $0.elements[index] = $0.elements[index].applyingStyle(of: style) }
        return true
    }

    func deleteElement(_ id: LabelElement.ID) {
        guard let element = document.elements.first(where: { $0.id == id }) else { return }
        perform("Delete \(element.kind.title)") { $0.elements.removeAll { $0.id == id } }
    }

    func arrange(_ id: LabelElement.ID, _ arrangement: Arrangement) {
        perform(arrangement.title) { arrangement.apply(to: &$0.elements, id: id) }
    }

    func align(_ id: LabelElement.ID, _ alignment: LabelAlignment, elementSize: CGSize) {
        let label = CGSize(width: document.widthMM, height: document.heightMM)
        perform("Align \(alignment.title)") { doc in
            guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
            let position = alignment.position(for: doc.elements[index], size: elementSize, label: label)
            doc.elements[index].x = position.x
            doc.elements[index].y = position.y
        }
    }

    /// Empty `name` returns the layer to its automatic name.
    func renameElement(_ id: LabelElement.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let element = document.elements.first(where: { $0.id == id }), element.name != trimmed else { return }
        perform("Rename") { doc in
            guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
            doc.elements[index].name = trimmed
        }
    }

    /// Replaces the element with an edited copy (resize handles, menu toggles).
    func updateElement(_ element: LabelElement, actionName: String) {
        perform(actionName) { doc in
            guard let index = doc.elements.firstIndex(where: { $0.id == element.id }) else { return }
            doc.elements[index] = element
        }
    }

    // MARK: Several elements (multi-select)

    /// Moves every element in `ids` by `delta` (mm), keeping each top-left on the label.
    func moveElements(_ ids: Set<LabelElement.ID>, by delta: CGSize) {
        guard !ids.isEmpty, delta != .zero else { return }
        perform("Move") { doc in
            for index in doc.elements.indices where ids.contains(doc.elements[index].id) && !doc.elements[index].isLocked {
                doc.elements[index].x = max(0, ((doc.elements[index].x + delta.width) * 100).rounded() / 100)
                doc.elements[index].y = max(0, ((doc.elements[index].y + delta.height) * 100).rounded() / 100)
            }
        }
    }

    /// Lines the elements up with each other: left edges on the leftmost, centres on the selection's
    /// centre, and so on.
    func alignElements(_ ids: Set<LabelElement.ID>, _ alignment: LabelAlignment) {
        let frames = frames(of: ids)
        guard frames.count > 1 else { return }
        let bounds = frames.values.reduce(CGRect.null) { $0.union($1) }
        perform("Align \(alignment.title)") { doc in
            for index in doc.elements.indices {
                guard let frame = frames[doc.elements[index].id], !doc.elements[index].isLocked else { continue }
                switch alignment {
                case .left: doc.elements[index].x = bounds.minX
                case .center: doc.elements[index].x = bounds.midX - frame.width / 2
                case .right: doc.elements[index].x = bounds.maxX - frame.width
                case .top: doc.elements[index].y = bounds.minY
                case .middle: doc.elements[index].y = bounds.midY - frame.height / 2
                case .bottom: doc.elements[index].y = bounds.maxY - frame.height
                }
                doc.elements[index].x = max(0, (doc.elements[index].x * 100).rounded() / 100)
                doc.elements[index].y = max(0, (doc.elements[index].y * 100).rounded() / 100)
            }
        }
    }

    enum DistributeAxis { case horizontal, vertical }

    /// Equal gaps between the elements (3 or more): the first and last stay put.
    func distributeElements(_ ids: Set<LabelElement.ID>, _ axis: DistributeAxis) {
        let frames = frames(of: ids)
        guard frames.count > 2 else { return }
        let horizontal = axis == .horizontal
        let ordered = frames.sorted { horizontal ? $0.value.minX < $1.value.minX : $0.value.minY < $1.value.minY }
        let start = horizontal ? ordered.first!.value.minX : ordered.first!.value.minY
        let end = ordered.map { horizontal ? $0.value.maxX : $0.value.maxY }.max()!
        let total = ordered.reduce(0) { $0 + (horizontal ? $1.value.width : $1.value.height) }
        let gap = (end - start - total) / Double(ordered.count - 1)
        var positions: [LabelElement.ID: Double] = [:]
        var cursor = start
        for (id, frame) in ordered {
            positions[id] = cursor
            cursor += (horizontal ? frame.width : frame.height) + gap
        }
        perform(horizontal ? "Distribute Horizontally" : "Distribute Vertically") { doc in
            for index in doc.elements.indices {
                guard let value = positions[doc.elements[index].id], !doc.elements[index].isLocked else { continue }
                let rounded = max(0, (value * 100).rounded() / 100)
                if horizontal { doc.elements[index].x = rounded } else { doc.elements[index].y = rounded }
            }
        }
    }

    func deleteElements(_ ids: Set<LabelElement.ID>) {
        guard !ids.isEmpty else { return }
        perform(ids.count == 1 ? "Delete" : "Delete \(ids.count) Elements") { $0.elements.removeAll { ids.contains($0.id) } }
    }

    /// Copies of the elements 1 mm down-right, on top. Returns the copies' ids in stacking order.
    @discardableResult
    func duplicateElements(_ ids: Set<LabelElement.ID>) -> [LabelElement.ID] {
        let copies = document.elements.filter { ids.contains($0.id) }.map { original -> LabelElement in
            var copy = original
            copy.id = UUID()
            copy.x += 1
            copy.y += 1
            return copy
        }
        guard !copies.isEmpty else { return [] }
        perform("Duplicate") { $0.elements.append(contentsOf: copies) }
        return copies.map(\.id)
    }

    func copyElements(_ ids: Set<LabelElement.ID>) {
        ElementClipboard.copy(document.elements.filter { ids.contains($0.id) })
    }

    /// Pastes and returns the new elements' ids (to select them all).
    @discardableResult
    func pasteAllElements() -> [LabelElement.ID] {
        guard let copied = ElementClipboard.elements() else { return [] }
        let pasted = ElementClipboard.pasteable(copied, into: document)
        perform(pasted.count == 1 ? "Paste \(pasted[0].kind.title)" : "Paste") { $0.elements.append(contentsOf: pasted) }
        return pasted.map(\.id)
    }

    /// Sets a flag (hidden / locked) on every element in `ids`.
    func setFlag(_ key: WritableKeyPath<LabelElement, Bool>, to value: Bool, for ids: Set<LabelElement.ID>, actionName: String) {
        perform(actionName) { doc in
            for index in doc.elements.indices where ids.contains(doc.elements[index].id) { doc.elements[index][keyPath: key] = value }
        }
    }

    /// Rendered frames (mm) of the visible elements in `ids`.
    private func frames(of ids: Set<LabelElement.ID>) -> [LabelElement.ID: CGRect] {
        var result: [LabelElement.ID: CGRect] = [:]
        for element in document.elements where ids.contains(element.id) && !element.isHidden {
            result[element.id] = CGRect(origin: CGPoint(x: element.x, y: element.y), size: ElementGeometry.sizeMM(of: element))
        }
        return result
    }
}
