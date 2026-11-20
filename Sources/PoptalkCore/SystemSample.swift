import Foundation

/// Machine conditions at hotkey release, to tell a slow request from a busy machine (#58). Counts only.
public struct SystemSample: Codable, Equatable, Sendable {
    /// 1-minute load average and active CPU count.
    public var load: Double
    public var cpus: Int
    /// nominal, fair, serious or critical.
    public var thermal: String
    public var lowPower: Bool
    /// Poptalk's CPU time (user + system) in ms: process total from `now()`, the request's own after `ended()`.
    public var cpuMs: Double

    public init(load: Double, cpus: Int, thermal: String, lowPower: Bool, cpuMs: Double) {
        (self.load, self.cpus, self.thermal, self.lowPower, self.cpuMs) = (load, cpus, thermal, lowPower, cpuMs)
    }

    public static func now() -> SystemSample {
        var avg = [0.0]
        let p = ProcessInfo.processInfo
        let thermal = switch p.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return SystemSample(load: getloadavg(&avg, 1) == 1 ? avg[0] : 0, cpus: p.activeProcessorCount,
                            thermal: thermal, lowPower: p.isLowPowerModeEnabled, cpuMs: processCPUMs())
    }

    /// This process's user + system CPU time so far, in ms.
    public static func processCPUMs() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let ms = { (t: timeval) in Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
        return ms(u.ru_utime) + ms(u.ru_stime)
    }

    /// This sample with `cpuMs` replaced by the CPU time used since it was taken.
    public func ended() -> SystemSample {
        var s = self
        s.cpuMs = Self.processCPUMs() - cpuMs
        return s
    }

    /// One timing-log line, e.g. `request 842ms (cpu 310ms) load 6.2/12 thermal nominal lpm off`.
    public func summary(wallMs: Double) -> String {
        "request \(Int(wallMs.rounded()))ms (cpu \(Int(cpuMs.rounded()))ms) load \(String(format: "%.1f", load))/\(cpus)"
            + " thermal \(thermal) lpm \(lowPower ? "on" : "off")"
    }
}
