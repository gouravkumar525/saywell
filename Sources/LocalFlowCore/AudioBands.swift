import Foundation

/// C4: the voice dots. Splits the mic spectrum into `count` bands, spaced
/// evenly on a log scale from low (left) to high (right), and maps each band's
/// power to 0...1. Band math adapted from Coucou's FlowBands (MIT).
public enum AudioBands {
    public static let count = 9
    public static let lowHz = 90.0
    public static let highHz = 7000.0

    /// The `count + 1` band edges in Hz.
    public static func edges(count: Int = count, low: Double = lowHz, high: Double = highHz) -> [Double] {
        (0...count).map { low * pow(high / low, Double($0) / Double(count)) }
    }

    /// FFT bins [from, to) of each band for `fftSize` samples at `sampleRate`.
    /// Every band gets at least one bin, and bands never overlap.
    public static func binRanges(fftSize: Int, sampleRate: Double, count: Int = count) -> [Range<Int>] {
        let binHz = sampleRate / Double(fftSize)
        let maxBin = fftSize / 2
        let e = edges(count: count)
        var out: [Range<Int>] = []
        var last = 1
        for i in 0..<count {
            let from = min(maxBin - 1, max(last, Int((e[i] / binHz).rounded(.down))))
            let to = min(maxBin, max(from + 1, Int((e[i + 1] / binHz).rounded(.up))))
            out.append(from..<to)
            last = to
        }
        return out
    }

    /// A band's power in dB → 0...1: silence stays low, a normal voice fills it.
    /// `index` lifts the treble bands a little (voices have less energy there).
    public static func level(db: Double, index: Int = 0, floor: Double = -78, ceiling: Double = -30) -> Double {
        let tilted = db + Double(index) * 2.2
        return min(1, max(0, (tilted - floor) / (ceiling - floor)))
    }

    /// Display smoothing: rises quickly, falls slower, so dots glide instead of
    /// flickering with every 20 ms audio buffer.
    public static func smooth(_ current: Double, toward target: Double, dt: Double) -> Double {
        let rate = target > current ? 12.0 : 5.0
        return current + (target - current) * (1 - exp(-dt * rate))
    }
}
