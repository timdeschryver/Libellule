import Foundation
import Testing
@testable import Libellule

struct OverlayShortcutsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "OverlayShortcutsTests-\(UUID().uuidString)")!
    }

    @Test func theDefaultsDontClashWithEachOtherOrTheColours() {
        let shortcuts = OverlayShortcuts(defaults: freshDefaults())
        for action in OverlayAction.allCases {
            guard let key = action.defaultShortcut else { continue }
            for scope in action.scopes {
                #expect(shortcuts.action(for: key, in: scope) == action, "\(key.displayString) should be \(action.title)")
            }
            if key.modifiers.isEmpty {
                #expect(!OverlayShortcuts.colorKeys.contains(key.character), "\(action.title) sits on a colour letter")
            }
            #expect(OverlayShortcuts.fixedCommands[key] == nil, "\(action.title) sits on a fixed command")
        }
    }

    @Test func takenKeysAreRefusedAndFreeOnesTaken() {
        let shortcuts = OverlayShortcuts(defaults: freshDefaults())
        #expect(shortcuts.update(LocalShortcut("r"), for: .eraser) != nil)  // red
        #expect(shortcuts.update(LocalShortcut("a"), for: .eraser) != nil)  // the arrow
        #expect(shortcuts.update(LocalShortcut("z", .command), for: .eraser) != nil)  // undo
        #expect(shortcuts.update(LocalShortcut("n", .command), for: .eraser) != nil)  // New Window in the editor
        #expect(shortcuts.update(LocalShortcut("7"), for: .eraser) != nil)  // a digit
        #expect(shortcuts.shortcut(for: .eraser) == LocalShortcut("e"))

        #expect(shortcuts.update(LocalShortcut("j"), for: .eraser) == nil)
        #expect(shortcuts.shortcut(for: .eraser) == LocalShortcut("j"))
        #expect(shortcuts.action(for: LocalShortcut("j"), in: .editor) == .eraser)
        #expect(shortcuts.action(for: LocalShortcut("e"), in: .editor) == nil)
    }

    @Test func aDefaultTakenByACustomKeyStartsOutUnset() {
        let shortcuts = OverlayShortcuts(defaults: freshDefaults())
        #expect(shortcuts.update(LocalShortcut("e"), for: .measure) != nil)  // still the eraser's
        shortcuts.clear(.eraser)
        #expect(shortcuts.update(LocalShortcut("e"), for: .measure) == nil)
        shortcuts.reset(.eraser)
        #expect(shortcuts.shortcut(for: .eraser) == nil)  // E now belongs to Measure
        #expect(shortcuts.label(for: AnnotationTool.eraser) == "no key")
        shortcuts.resetAll()
        #expect(shortcuts.shortcut(for: .eraser) == LocalShortcut("e"))
        #expect(!shortcuts.hasOverrides)
    }

    @Test func changesSurviveARestart() {
        let defaults = freshDefaults()
        let first = OverlayShortcuts(defaults: defaults)
        first.update(LocalShortcut("j"), for: .eraser)
        first.clear(.measure)
        let second = OverlayShortcuts(defaults: defaults)
        #expect(second.shortcut(for: .eraser) == LocalShortcut("j"))
        #expect(second.shortcut(for: .measure) == nil)
        #expect(!second.isDefault(.measure))
    }

    @Test func liveOnlyActionsStayOutOfTheEditor() {
        let shortcuts = OverlayShortcuts(defaults: freshDefaults())
        let loupe = shortcuts.shortcut(for: .loupe)!
        #expect(shortcuts.action(for: loupe, in: .live) == .loupe)
        #expect(shortcuts.action(for: loupe, in: .editor) == nil)
    }

    @Test func shiftedPunctuationCountsAsThePlainKey() {
        #expect(LocalShortcut("+") == LocalShortcut("="))
        #expect(LocalShortcut("}") == LocalShortcut("]"))
        #expect(LocalShortcut(LocalShortcut.deleteKey, .option).displayString == "⌥⌫")
        #expect(LocalShortcut("t", [.command, .option]).displayString == "⌥⌘T")
    }

    @Test func toolLabelsNameKeyAndDigit() {
        let shortcuts = OverlayShortcuts(defaults: freshDefaults())
        #expect(shortcuts.label(for: AnnotationTool.arrow) == "A or 1")
        #expect(shortcuts.label(for: AnnotationTool.eraser) == "E")
        #expect(shortcuts.label(for: AnnotationTool.pixelate) == "X or 0")
    }
}

struct AnnotationToolboxTests {
    @Test func widthIsClampedAndThePresetsFollowIt() {
        let toolbox = AnnotationToolbox()
        toolbox.lineWidth = 100
        #expect(toolbox.lineWidth == 24)
        #expect(toolbox.strokeWidth == .thick)
        toolbox.strokeWidth = .thin
        #expect(toolbox.lineWidth == 2)
        toolbox.adjustWidth(by: -5)
        #expect(toolbox.lineWidth == 1)
        #expect(toolbox.strokeWidth == .thin)
    }

    @Test func actionsStepTheSize() {
        let toolbox = AnnotationToolbox()
        toolbox.lineWidth = 4
        #expect(toolbox.perform(.sizeUp))
        #expect(toolbox.lineWidth == 5)
        #expect(toolbox.perform(.thicker))
        #expect(toolbox.lineWidth == 8)
        #expect(toolbox.perform(.thinner))
        #expect(toolbox.lineWidth == 4)
        #expect(toolbox.perform(.eraser))
        #expect(toolbox.tool == .eraser)
        #expect(!toolbox.perform(.board))
        #expect(toolbox.applyColor(LocalShortcut("g")))
        #expect(toolbox.color == AnnotationPalette.color(forKey: "g"))
        #expect(!toolbox.applyColor(LocalShortcut("g", .command)))
    }
}
