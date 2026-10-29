import Foundation
import CoreGraphics

nonisolated extension CGRect {
    /// The square around a circle of `radius` at `center`.
    init(center: CGPoint, radius: CGFloat) {
        self.init(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// The rectangle a drag from `a` to `b` spans. With `square` the longer side wins and the square grows
    /// away from `a` in the direction of the drag.
    init(from a: CGPoint, to b: CGPoint, square: Bool) {
        var width = b.x - a.x
        var height = b.y - a.y
        if square {
            let side = max(abs(width), abs(height))
            width = width < 0 ? -side : side
            height = height < 0 ? -side : side
        }
        self.init(x: min(a.x, a.x + width), y: min(a.y, a.y + height), width: abs(width), height: abs(height))
    }

    /// The rectangle centred on `center` with `corner` on its edge: what a drag from `center` to `corner` spans
    /// when it grows out from the middle (⌥). With `square` the longer half-side wins.
    init(center: CGPoint, corner: CGPoint, square: Bool) {
        var halfWidth = abs(corner.x - center.x)
        var halfHeight = abs(corner.y - center.y)
        if square {
            let half = max(halfWidth, halfHeight)
            halfWidth = half
            halfHeight = half
        }
        self.init(x: center.x - halfWidth, y: center.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2)
    }
}

nonisolated extension CGPoint {
    /// The nearest point inside `rect`.
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}

extension UndoManager {
    /// Registers `undo` as the way back from a change just made, named `actionName`. Each change is its own
    /// undo step; while undoing or redoing, the undo manager already has a group open for it.
    func registerChange<Target: AnyObject>(on target: Target, actionName: String, undo: @escaping @MainActor (Target) -> Void) {
        let opensGroup = !isUndoing && !isRedoing
        if opensGroup { beginUndoGrouping() }
        registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated { undo(target) }
        }
        setActionName(actionName)
        if opensGroup { endUndoGrouping() }
    }
}
