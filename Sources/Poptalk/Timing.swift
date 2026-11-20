import os
import PoptalkCore

/// Stage timings only (no text): `log stream --level info --predicate 'subsystem == "io.lyx.poptalk"'`.
enum Timing {
    static let log = Logger(subsystem: "io.lyx.poptalk", category: "timing")
    /// The latest `start()` and Poptalk's CPU time then, so marks since it also log CPU ms (#58).
    private static let begun = OSAllocatedUnfairLock<(ContinuousClock.Instant, Double)?>(initialState: nil)

    static func start() -> ContinuousClock.Instant {
        let t = ContinuousClock.now
        let cpu = SystemSample.processCPUMs()
        begun.withLock { $0 = (t, cpu) }
        return t
    }

    static func mark(_ stage: String, since start: ContinuousClock.Instant) {
        let ms = ms(since: start)
        if let (t, cpu) = begun.withLock({ $0 }), t == start {
            let cpuMs = SystemSample.processCPUMs() - cpu
            log.info("\(stage, privacy: .public) \(ms, format: .fixed(precision: 0))ms (cpu \(cpuMs, format: .fixed(precision: 0))ms)")
        } else {
            log.info("\(stage, privacy: .public) \(ms, format: .fixed(precision: 0))ms")
        }
    }

    /// Logs the per-request summary line and returns `system` with the request's CPU time, for history.
    static func summary(_ system: SystemSample, since start: ContinuousClock.Instant) -> SystemSample {
        let s = system.ended()
        log.info("\(s.summary(wallMs: ms(since: start)), privacy: .public)")
        return s
    }

    private static func ms(since start: ContinuousClock.Instant) -> Double {
        let d = (ContinuousClock.now - start).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
}
