import Darwin

/// The Sound Field Processor's named spaces.
///
/// Each one is a fixed set of decay time, room size, damping and pre-delay —
/// the same four numbers a real digital reverb's factory presets are built
/// from. There is no continuous "room size" knob in Part 1: six named spaces
/// is what the brief asks for, and a named space reads as a place rather than
/// a setting.
public enum ReverbPreset: String, CaseIterable, Equatable, Sendable, Codable {
    case hall
    case church
    case stadium
    case live
    case jazzClub
    case disco

    /// The four values that make a space what it is.
    public struct Design: Equatable, Sendable {
        /// RT60 — the time for the tail to fall 60 dB. What most people mean
        /// by "how long is the reverb".
        public let decaySeconds: Double

        /// Scales the Sound Field Processor's four delay-line lengths
        /// (`Reverb.lineLengthsMilliseconds`), 0…`Reverb.maximumRoomSize`.
        /// Bigger rooms space their early reflections further apart, which
        /// is most of what makes a stadium sound larger than a jazz club at
        /// the same decay time.
        public let roomSize: Double

        /// How much faster the high end decays than the overall RT60, 0…1.
        /// A live stone room has hard, undamped surfaces; a jazz club is
        /// carpeted and full of soft furniture and decays dull. 0 leaves the
        /// whole spectrum decaying at the same rate; 1 damps almost
        /// immediately.
        public let damping: Double

        /// Silence before the first reflection arrives, in milliseconds.
        /// This is also the latency the panel reports — see
        /// `ReverbPreset.latencyMilliseconds`.
        public let preDelayMilliseconds: Double
    }

    public var design: Design {
        switch self {
        case .hall:
            Design(decaySeconds: 1.8, roomSize: 1.0, damping: 0.30, preDelayMilliseconds: 20)
        case .church:
            // Stone and glass: long, and barely damped.
            Design(decaySeconds: 3.2, roomSize: 1.4, damping: 0.15, preDelayMilliseconds: 35)
        case .stadium:
            // The largest space and the longest tail this offers.
            Design(decaySeconds: 4.5, roomSize: 2.0, damping: 0.20, preDelayMilliseconds: 60)
        case .live:
            // A small venue's room sound — present, not lush.
            Design(decaySeconds: 0.9, roomSize: 0.7, damping: 0.40, preDelayMilliseconds: 10)
        case .jazzClub:
            // Warm, close, heavily damped — the smallest, shortest space.
            Design(decaySeconds: 0.6, roomSize: 0.5, damping: 0.50, preDelayMilliseconds: 8)
        case .disco:
            // Hard surfaces for the low end to slap off, but not a big room.
            Design(decaySeconds: 1.2, roomSize: 0.8, damping: 0.25, preDelayMilliseconds: 15)
        }
    }

    /// What a chip in the panel reads.
    public var displayName: String {
        switch self {
        case .hall: "Hall"
        case .church: "Church"
        case .stadium: "Stadium"
        case .live: "Live"
        case .jazzClub: "Jazz Club"
        case .disco: "Disco"
        }
    }

    /// The latency this preset adds, in milliseconds — exactly its
    /// pre-delay. The Sound Field Processor's own network is a recirculating
    /// filter, not a lookahead one, so pre-delay is the only genuine gap
    /// between a dry sample arriving and its first reflection leaving; that
    /// is also the number that matters for lip-sync on video, which is why
    /// the panel shows it plainly rather than leaving it to be discovered.
    public var latencyMilliseconds: Double { design.preDelayMilliseconds }

    /// A stable small integer for each case, so the audio thread can tell
    /// "the published preset changed" from "it published again unchanged"
    /// with a plain integer comparison rather than comparing every derived
    /// coefficient.
    var index: Int32 {
        switch self {
        case .hall: 0
        case .church: 1
        case .stadium: 2
        case .live: 3
        case .jazzClub: 4
        case .disco: 5
        }
    }
}
