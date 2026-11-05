import SwiftUI

extension AnnotationLayer {
    func expandedGroups(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(annotations.filter { ids.contains($0.id) }.compactMap(\.groupID))
        return ids.union(annotations.filter { $0.groupID.map(groups.contains) ?? false }.map(\.id))
    }

    var canGroup: Bool { selectedAnnotations.filter { !$0.isLocked }.count >= 2 }
    var canUngroup: Bool { selectedAnnotations.contains { $0.groupID != nil && !$0.isLocked } }
    var selectionIsLocked: Bool { !selectedAnnotations.isEmpty && selectedAnnotations.allSatisfy(\.isLocked) }

    func groupSelection() {
        guard canGroup else { return }
        let group = UUID()
        editSelection("Group") { $0.groupID = group }
    }

    func ungroupSelection() { editSelection("Ungroup") { $0.groupID = nil } }

    func toggleSelectionLock() {
        let lock = !selectionIsLocked
        var updated = annotations
        for index in updated.indices where selectedIDs.contains(updated[index].id) { updated[index].isLocked = lock }
        apply(updated, actionName: lock ? "Lock" : "Unlock")
    }

    func unlockAll() {
        apply(annotations.map { var copy = $0; copy.isLocked = false; return copy }, actionName: "Unlock All")
    }

    func arrangeSelection(front: Bool) {
        let ids = Set(selectedAnnotations.filter { !$0.isLocked }.map(\.id))
        let selected = annotations.filter { ids.contains($0.id) }
        let others = annotations.filter { !ids.contains($0.id) }
        apply(front ? others + selected : selected + others, actionName: front ? "Bring to Front" : "Send to Back")
    }

    /// Groups form a single alignment/distribution unit so arranging them preserves their internal layout.
    private var arrangementUnits: [(ids: Set<UUID>, bounds: CGRect)] {
        let items = selectedAnnotations.filter { !$0.isLocked }
        var units: [(ids: Set<UUID>, bounds: CGRect)] = []
        var seen: Set<UUID> = []
        for item in items where !seen.contains(item.id) {
            let members = item.groupID.map { group in items.filter { $0.groupID == group } } ?? [item]
            let ids = Set(members.map(\.id))
            let bounds = members.dropFirst().reduce(members[0].bounds) { $0.union($1.bounds) }
            units.append((ids, bounds))
            seen.formUnion(ids)
        }
        return units
    }

    func alignSelection(_ alignment: AnnotationAlignment) {
        let units = arrangementUnits
        guard units.count >= 2, let first = units.first else { return }
        let union = units.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        var updated = annotations
        for unit in units {
            let box = unit.bounds
            let delta: CGPoint
            switch alignment {
            case .left: delta = CGPoint(x: union.minX - box.minX, y: 0)
            case .center: delta = CGPoint(x: union.midX - box.midX, y: 0)
            case .right: delta = CGPoint(x: union.maxX - box.maxX, y: 0)
            case .top: delta = CGPoint(x: 0, y: union.minY - box.minY)
            case .middle: delta = CGPoint(x: 0, y: union.midY - box.midY)
            case .bottom: delta = CGPoint(x: 0, y: union.maxY - box.maxY)
            }
            for index in updated.indices where unit.ids.contains(updated[index].id) { updated[index] = updated[index].movedForSelection(by: delta) }
        }
        apply(updated, actionName: "Align")
    }

    func distributeSelection(horizontal: Bool) {
        let units = arrangementUnits.sorted { horizontal ? $0.bounds.midX < $1.bounds.midX : $0.bounds.midY < $1.bounds.midY }
        guard units.count >= 3, let first = units.first, let last = units.last else { return }
        let start = horizontal ? first.bounds.minX : first.bounds.minY
        let end = horizontal ? last.bounds.maxX : last.bounds.maxY
        let widths = units.reduce(CGFloat.zero) { $0 + (horizontal ? $1.bounds.width : $1.bounds.height) }
        let gap = (end - start - widths) / CGFloat(units.count - 1)
        var position = start
        var updated = annotations
        for unit in units {
            let delta = horizontal ? CGPoint(x: position - unit.bounds.minX, y: 0) : CGPoint(x: 0, y: position - unit.bounds.minY)
            for index in updated.indices where unit.ids.contains(updated[index].id) { updated[index] = updated[index].movedForSelection(by: delta) }
            position += (horizontal ? unit.bounds.width : unit.bounds.height) + gap
        }
        apply(updated, actionName: "Distribute")
    }

    func setArrowStyle(_ style: ArrowStyle) {
        toolbox.arrowStyle = style
        if textEditing != nil { textEditing?.arrowStyle = style }
        editSelection("Change Arrow Style") { $0.arrowStyle = style }
    }

    func applyStyle(_ preset: AnnotationStylePreset) {
        // Apply to the selection once; don't let the editor's individual toolbox observers erase the saved font.
        editSelection("Apply Style") {
            $0.color = preset.sample.color
            $0.lineWidth = preset.sample.lineWidth
            $0.text = preset.sample.text
            $0.arrowStyle = preset.sample.arrowStyle
            $0.curveDegrees = preset.sample.curveDegrees
            $0.badgeStyle = preset.sample.badgeStyle
        }
        if !hasSelection {
            toolbox.color = Color(preset.sample.color)
            toolbox.lineWidth = preset.sample.lineWidth
            toolbox.textStyle = preset.sample.text
            toolbox.arrowStyle = preset.sample.arrowStyle
            toolbox.curveDegrees = preset.sample.curveDegrees
            toolbox.badgeStyle = preset.sample.badgeStyle
        }
    }

    func insertStamp(_ text: String, at point: CGPoint? = nil) {
        commitTextEditing()
        var stamp = Annotation(shape: .text(text, origin: point ?? CGPoint(x: 24, y: 24)), color: toolbox.resolvedColor, lineWidth: toolbox.lineWidth)
        stamp.text = toolbox.textStyle
        stamp.text.hasBackground = true
        apply(annotations + [stamp], actionName: "Add Stamp")
        select([stamp.id])
        toolbox.tool = .select
    }

    private func editSelection(_ name: String, edit: (inout Annotation) -> Void) {
        commitTextEditing()
        var updated = annotations
        for index in updated.indices where selectedIDs.contains(updated[index].id) && !updated[index].isLocked { edit(&updated[index]) }
        apply(updated, actionName: name)
    }
}
