/// Which key presses the outcome overlay consumes: bare Esc (undo) and bare Return (accept vocabulary).
public enum OutcomeKeys {
    public enum Action: Equatable { case undo, accept }

    /// Shift, Control, Option, Command, Fn (CGEventFlags raw values). Caps Lock doesn't count.
    static let modifiers: UInt64 = 0x20000 | 0x40000 | 0x80000 | 0x100000 | 0x800000

    public static func action(code: Int64, flags: UInt64, canUndo: Bool, canAccept: Bool) -> Action? {
        guard flags & modifiers == 0 else { return nil }
        switch code {
        case 53 where canUndo: return .undo
        case 36 where canAccept: return .accept
        default: return nil
        }
    }
}
