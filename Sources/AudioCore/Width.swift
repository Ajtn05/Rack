import CoreAudio

/// The Sound Field Processor's last stage: a mid/side width control over the
/// fully processed signal — reverb and delay's stereo image included, not
/// just the dry source.
///
/// `mid = (L+R)/2`, `side = (L−R)/2`, output `L' = mid + side·width`,
/// `R' = mid − side·width`. Lossless at `width == 1` (identity), collapses
/// toward mono as it falls to 0, and widens past 1 — the standard
/// energy-preserving stereo-width rotation, the same one
/// `EngineController.goniometerPoint` already documents from the analyzer
/// side. Cheap enough to need no delay line of its own: a Haas-effect
/// widener would, which is why this is the one implemented here.
@inline(__always)
func rackProcessWidth(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    let target = block.pointee.widthGain
    let smoothing = context.pointee.dsp.smoothingCoefficient

    // Unity width is the identity — `mid + side` reconstructs each channel — so
    // once the knob has settled back to 1 there is nothing to do and the
    // mid/side decode is skipped. Skipping is in fact *more* transparent than
    // running it, since it avoids the sub-ULP rounding of the (L±R)/2 round
    // trip; kept running while the ramp is still on its way to 1 so a move back
    // to centre does not step.
    if target == 1, context.pointee.widthGain == 1 { return }

    @inline(__always)
    func mix(left: inout Float, right: inout Float) {
        context.pointee.widthGain = rackSmooth(
            context.pointee.widthGain, toward: target, coefficient: smoothing
        )
        let width = context.pointee.widthGain
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5
        left = mid + side * width
        right = mid - side * width
    }

    rackWalkStereoPairs(buffers: buffers, mix)
}
