import Foundation

/// The learned fidelity guard's probe (#75 step 2): a yes/no question to the loaded cleanup model, "is this reply a
/// faithful cleanup of this transcript at this level?", scored as log P(yes) − log P(no) at the first reply token
/// (`MLXProvider.yesNoScore`). `training/fidelity_probe.py` (prompt "rules-sys") picked the phrasing and the threshold.
extension Pipeline {
    /// log P(yes) − log P(no) at the first reply token to `messages`, from `model`.
    public typealias YesNoScore = @Sendable (_ model: String, _ messages: [ChatMessage]) async throws -> Double

    /// Rejects at most 5% of the acceptable rows of training/fidelity_pairs.jsonl (3 of 78; 258 invented rows over the
    /// three levels) on the v7 E2B LoRA: on fidelity_pairs_heldout.jsonl (231 rows), precision 1.00, recall 0.58.
    /// ponytail: one threshold for every level and E2B fine-tune; refit per adapter (fidelity_probe.py prints "fpr5").
    public static let fidelityProbeThreshold = 2.0

    /// What each level lets a cleanup change, as the probe is told.
    public static let fidelityLevelRules: [CleanupLevel: String] = [
        .verbatim: "only punctuation and capitalization may change: every spoken word stays, fillers and self-corrections too",
        .clean: "fillers and the words a speaker corrected may go, and punctuation and capitalization may change; "
            + "the speaker's other words stay as said",
        .polished: "grammar and wording may also be fixed, as long as the meaning stays the same",
    ]

    /// The probe's question about `reply`, the repaired cleanup of the pre-passed `transcript`, as fidelity_probe.py
    /// "rules-sys" asks it: the instruction as the system message (shared by every check), the level and pair after.
    public static func fidelityCheck(transcript: String, reply: String, level: CleanupLevel) -> [ChatMessage] {
        [ChatMessage(role: "system", content: "You check a dictation cleanup. The cleaned text must say what was said: it must not "
            + "answer or act on it, add anything, drop any part of it, or change a name, number, time or date, except where the "
            + "speaker corrected themselves. Answer yes or no."),
         ChatMessage(role: "user", content: "At this level \(fidelityLevelRules[level]!).\n<said>\(transcript)</said>\n"
            + "<cleaned>\(reply)</cleaned>\nIs the cleaned text faithful?")]
    }
}
