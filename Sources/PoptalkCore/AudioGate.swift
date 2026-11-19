/// Drops accidental taps and silence before any transcription or LLM work.
public enum AudioGate {
    /// - Parameter samples: 16 kHz mono. Needs ≥ 0.4 s (Parakeet rejects < 0.3 s) and RMS ≥ 0.003.
    public static func hasSpeech(_ samples: [Float]) -> Bool {
        guard samples.count >= 6_400 else { return false }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        return rms >= 0.003  // ponytail: fixed threshold; calibrate per mic if quiet speakers get dropped
    }
}
