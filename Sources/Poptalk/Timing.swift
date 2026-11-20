import os

/// Stage timings only (no text): `log stream --level info --predicate 'subsystem == "io.lyx.poptalk"'`.
enum Timing {
    static let log = Logger(subsystem: "io.lyx.poptalk", category: "timing")

    static func mark(_ stage: String, since start: ContinuousClock.Instant) {
        let d = (ContinuousClock.now - start).components
        let ms = Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
        log.info("\(stage, privacy: .public) \(ms, format: .fixed(precision: 0))ms")
    }
}
