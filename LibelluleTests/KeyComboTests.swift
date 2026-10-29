import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Libellule

struct KeyComboTests {
    @Test func showsModifiersInMenuOrder() {
        let combo = KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: [.shift, .command, .control, .option])
        #expect(combo.displayString == "⌃⌥⇧⌘⎋")
    }

    @Test func keepsOnlyTheModifiersAShortcutCanUse() {
        let combo = KeyCombo(keyCode: UInt32(kVK_Return), modifiers: [.command, .capsLock, .function])
        #expect(combo.modifiers == .command)
        #expect(combo.carbonModifiers == UInt32(cmdKey))
        #expect(combo.eventModifiers == .command)
    }

    @Test func survivesBeingStored() throws {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: [.command, .shift])
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo))
        #expect(decoded == combo)
    }
}
