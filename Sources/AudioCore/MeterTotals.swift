import RackRealtime

/// Cumulative meter totals. The control side subtracts its previous snapshot
/// instead of clearing shared sums while the audio thread is adding to them.
struct MeterTotals {
    var leftMagnitude: Double = 0
    var rightMagnitude: Double = 0
    var leftCount: UInt64 = 0
    var rightCount: UInt64 = 0
    var lr: Double = 0
    var ll: Double = 0
    var rr: Double = 0
}

extension UnsafeMutablePointer<TapRenderContext> {
    /// The audio writer never retries. This non-realtime reader makes a
    /// bounded number of attempts at a coherent snapshot, then defers the
    /// reading to the next poll if a render keeps overlapping it.
    func meterSnapshot() -> MeterTotals? {
        for _ in 0..<4 {
            let before = rack_u64_load_acquire(&pointee.meterVersion)
            guard before & 1 == 0 else { continue }
            let totals = MeterTotals(
                leftMagnitude: Double(bitPattern: rack_u64_load_acquire(&pointee.vuMagnitudeSumLeftBits)),
                rightMagnitude: Double(bitPattern: rack_u64_load_acquire(&pointee.vuMagnitudeSumRightBits)),
                leftCount: rack_u64_load_acquire(&pointee.vuSampleCountLeft),
                rightCount: rack_u64_load_acquire(&pointee.vuSampleCountRight),
                lr: Double(bitPattern: rack_u64_load_acquire(&pointee.correlationSumLRBits)),
                ll: Double(bitPattern: rack_u64_load_acquire(&pointee.correlationSumLLBits)),
                rr: Double(bitPattern: rack_u64_load_acquire(&pointee.correlationSumRRBits))
            )
            if rack_u64_load_acquire(&pointee.meterVersion) == before { return totals }
        }
        return nil
    }
}
