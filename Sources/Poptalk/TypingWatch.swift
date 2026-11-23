import AppKit
import ApplicationServices
import PoptalkCore

/// Watches a dictation's field for the user fixing it by typing (#86): AX value-changed notifications on the field,
/// checked `pause` seconds after the last one. Stops at `end()` (the next dictation, an undo), at a change that leaves
/// the dictation deleted (or sent, #94), at a check that finds focus gone from the field or the dictation no longer
/// there (`InsertAnchors.span`), or after `lifetime`. The field's text is read only in memory, for the diff.
@MainActor
final class TypingWatch {
    private let field: AXUIElement, anchors: InsertAnchors, pasted: String, transcript: String, pause: TimeInterval
    private let known: () -> [VocabTerm], offer: (VocabTerm) -> Void, done: (TypedCorrection) -> Void, deleted: () -> Void
    private var observer: AXObserver?
    private var pending: DispatchWorkItem?
    /// The last check's result: what `done` gets.
    private var latest: TypedCorrection?
    private var offered: Set<String> = []
    /// Called once, at the first change that leaves the dictation different from the paste.
    private var typed: (() -> Void)?

    /// Nil when the field's text can't be read, the paste can't be found in it, or the app sends no notifications.
    /// `typed`: the user has started changing the field. `offer`: a misheard term to offer, once per term. `done`: the
    /// last correction found, when the watch ends. `deleted`: the dictation went blank (deleted or sent, #95).
    init?(field: AXUIElement, pasted: String, transcript: String, pause: TimeInterval = 2, lifetime: TimeInterval = 180,
          known: @escaping () -> [VocabTerm], typed: @escaping () -> Void, offer: @escaping (VocabTerm) -> Void,
          done: @escaping (TypedCorrection) -> Void, deleted: @escaping () -> Void) {
        var pid: pid_t = 0, obs: AXObserver?
        guard let value = TextIO.value(of: field),
              let anchors = InsertAnchors(value: value, inserted: pasted, caret: TextIO.caret(in: field)),
              AXUIElementGetPid(field, &pid) == .success,
              AXObserverCreate(pid, { _, _, _, ctx in
                  guard let ctx else { return }
                  let me = Unmanaged<TypingWatch>.fromOpaque(ctx).takeUnretainedValue()
                  MainActor.assumeIsolated { me.changed() }
              }, &obs) == .success, let obs
        else { return nil }
        (self.field, self.anchors, self.pasted, self.transcript, self.pause) = (field, anchors, pasted, transcript, pause)
        (self.known, self.typed, self.offer, self.done, self.deleted) = (known, typed, offer, done, deleted)
        // Unretained: `end()` removes the notification, and the owner calls it before letting go.
        guard AXObserverAddNotification(obs, field, kAXValueChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return nil }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in self?.end() }
    }

    /// Stops watching; idempotent. `flush`: first run a check still pending, then hand `done` the last correction.
    func end(flush: Bool = true) {
        guard let observer else { return }
        if flush, pending != nil { check(final: true) }
        pending?.cancel()
        pending = nil
        AXObserverRemoveNotification(observer, field, kAXValueChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
        if flush, let latest { done(latest) }
    }

    private func changed() {
        // Read back, so a late or spurious notification (the paste's own, an app's re-render) doesn't count as typing.
        let span = TextIO.value(of: field).flatMap(anchors.span(in:))
        if let t = typed, span != pasted {
            typed = nil
            t()
        }
        // Deleted, or sent from a field it filled: end now, before the user types on (#94), and say so: the next take
        // decides whether it was a redictation (#95).
        if let span, span.allSatisfy(\.isWhitespace) {
            deleted()
            return end()
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check(final: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
    }

    /// `final`: run by `end`, so no offer (a dictation is starting) and no ending from here.
    private func check(final: Bool) {
        pending = nil
        guard let span = TextIO.value(of: field).flatMap(anchors.span(in:)), !span.allSatisfy(\.isWhitespace) else {
            if !final { end() }  // deleted, replaced, or the text around it changed: keep what was found
            return
        }
        latest = TypedCorrection(inserted: pasted, span: span, transcript: transcript)
        let term = final ? nil : latest?.offer(known: known(), isWord: Self.isWord)
        Timing.log.info("typed fix: \(self.latest?.changes.count ?? 0) changes, offer \(term != nil ? "yes" : "no", privacy: .public)")
        if let term, offered.insert(term.text.lowercased()).inserted { offer(term) }
        if !final, TextIO.focusedElement() != field { end() }
    }

    /// Whether the system spell checker knows `w`.
    static func isWord(_ w: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0).location == NSNotFound
    }
}
