import Foundation

/// Self-calibrating step estimator.
///
/// Research (Beevi et al.; Kowalski review) shows consumer step counters
/// degrade badly at slow walking speeds — exactly the under-desk range. But
/// the pad's DISTANCE is mechanically exact (belt revolutions). So:
///
/// - at >= trustSpeed we trust the pad's step count and use it to learn the
///   user's personal stride as a function of speed: stride = d/steps
/// - below it, steps are estimated as distance / stride(speed), with the
///   learned curve interpolated between calibrated buckets
///
/// Persisted in UserDefaults (bucket totals survive restarts).
/// Mirrors `stride.py`.
public struct StrideLearner: Sendable {
    public static let trustSpeedKmh = 3.0
    /// Minimum accumulated distance in a bucket before it's calibrated.
    public static let minBucketDistanceM = 50.0

    public static let defaultsKey = "z1.strideLearner"

    /// bucket (0.5 km/h) -> (totalDistanceM, totalSteps)
    public private(set) var buckets: [Double: (distance: Double, steps: Double)] = [:]
    private let storageKey: String

    public init(userDefaultsKey: String = StrideLearner.defaultsKey) {
        storageKey = userDefaultsKey
        if let raw = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: [Double]] {
            for (k, v) in raw where v.count == 2 {
                guard let b = Double(k) else { continue }
                buckets[b] = (v[0], v[1])
            }
        }
    }

    public var calibrated: Bool {
        buckets.values.contains { $0.distance >= Self.minBucketDistanceM }
    }

    static func bucket(_ speedKmh: Double) -> Double {
        (speedKmh * 2).rounded(.down) / 2
    }

    /// Feed a trusted-zone segment (call only at >= trustSpeedKmh).
    public mutating func learn(distanceM: Double, steps: Double, speedKmh: Double) {
        guard speedKmh >= Self.trustSpeedKmh, distanceM > 0, steps > 0 else { return }
        let b = Self.bucket(speedKmh)
        let e = buckets[b] ?? (0, 0)
        buckets[b] = (e.distance + distanceM, e.steps + steps)
        persist()
    }

    /// Stride (m/step) at a speed: bucket value, linear interpolation
    /// between neighbors, or nearest bucket. nil if uncalibrated.
    public func stride(for speedKmh: Double) -> Double? {
        let points = buckets
            .filter { $0.value.distance >= Self.minBucketDistanceM && $0.value.steps > 0 }
            .map { (bucket: $0.key, stride: $0.value.distance / $0.value.steps) }
            .sorted { $0.bucket < $1.bucket }
        guard !points.isEmpty else { return nil }
        let target = Self.bucket(speedKmh)
        if let exact = points.first(where: { $0.bucket == target }) { return exact.stride }
        if target <= points.first!.bucket { return points.first!.stride }
        if target >= points.last!.bucket { return points.last!.stride }
        for i in 0 ..< points.count - 1 where points[i].bucket <= target && target <= points[i + 1].bucket {
            let (b0, s0) = (points[i].bucket, points[i].stride)
            let (b1, s1) = (points[i + 1].bucket, points[i + 1].stride)
            return s0 + (target - b0) / (b1 - b0) * (s1 - s0)
        }
        return points.last!.stride
    }

    private func persist() {
        var raw: [String: [Double]] = [:]
        for (bucket, value) in buckets {
            raw[String(bucket)] = [value.distance, value.steps]
        }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }
}
