import Foundation

/// Apps whose ⌘Z doesn't take PopTalk's paste back out (#93), so undo deletes the insert itself: selected over AX
/// (checked by reading it back), else by backspaces under the terminal guard (#79). Listed per app, not per framework:
/// what ⌘Z does is the app's own editor code (Beeper's composer binds ⌘Z and ⇧⌘Z to its own actions; Slack, also
/// Electron, undoes the paste fine).
public enum AXUndo {
    public static let bundleIDs: Set<String> = ["com.automattic.beeper.desktop"]

    public static func contains(_ bundleID: String?) -> Bool { bundleID.map(bundleIDs.contains) ?? false }
}

/// One way to take an insert back, in the order to try them.
public enum UndoStep: Equatable, Sendable {
    /// Select this UTF-16 range over AX (it must read back as the insert), then delete or replace the selection.
    case select(location: Int, length: Int)
    /// Delete this many characters before the caret.
    case backspaces(Int)
}

extension LastInsert {
    /// How to take this insert back out of an `AXUndo` app; empty means leave it alone. Only while `focused` is still
    /// its field. Readable field: select the insert, found ending at the caret or as its only occurrence (`InsertAnchors`),
    /// then, if the caret is right after it, backspaces; not found (edited since, or ambiguous): nothing, so no
    /// backspaces into text PopTalk didn't write. Unreadable field: backspaces, if no key was pressed since, the same app
    /// is frontmost, within `window` seconds, and it has no newline.
    public func axUndoSteps(focused: Target?, value: String?, caret: Int?, frontmost: Int32?, keyDowns: Int,
                            now: Date = Date(), window: TimeInterval = 60) -> [UndoStep] {
        guard let axUndo, focused == target else { return [] }
        let typed = prefix + text
        let untouched = frontmost == axUndo.app && keyDowns == axUndo.keyDowns && now.timeIntervalSince(at) < window
            && !typed.contains(where: \.isNewline)
        let backspaces = untouched ? [UndoStep.backspaces(typed.count)] : []
        guard let value else { return backspaces }
        guard let anchors = InsertAnchors(value: value, inserted: typed, caret: caret) else { return [] }
        let (start, length) = (anchors.before.count, typed.utf16.count)
        return [.select(location: start, length: length)] + (caret == start + length ? backspaces : [])
    }
}
