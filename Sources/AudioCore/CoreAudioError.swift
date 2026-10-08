import CoreAudio
import Foundation

/// A failed Core Audio call, with enough context to act on.
///
/// Core Audio reports failure as a bare `OSStatus`. Most of its status values
/// are four printable ASCII bytes packed big-endian into an Int32, so the
/// number you see in a debugger — `560947818` — is a rendering of `'!obj'` that
/// throws away the only part anyone can read. This type decodes that, adds the
/// symbolic constant name where one is known, and records which call failed and
/// what it was trying to do. We will be reading a great many of these.
public struct CoreAudioError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The Core Audio function that failed, spelled exactly as in the header.
    public let operation: String

    /// The raw status it returned.
    public let status: OSStatus

    /// What we were trying to accomplish, in the caller's terms.
    public let context: String?

    public init(operation: String, status: OSStatus, context: String? = nil) {
        self.operation = operation
        self.status = status
        self.context = context
    }

    /// The status decoded as a four-character code, when all four bytes are
    /// printable ASCII. Returns nil for numeric statuses such as `-50`.
    public var fourCharCode: String? {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The symbolic constant name, when this is a status we have a name for.
    public var symbolicName: String? { Self.knownStatuses[status] }

    public var description: String {
        var text = "\(operation) failed"
        if let context { text += " while \(context)" }
        text += ": "

        var parts: [String] = []
        if let symbolicName { parts.append(symbolicName) }
        if let fourCharCode { parts.append("'\(fourCharCode)'") }
        parts.append("\(status)")
        text += parts.joined(separator: " ")

        if let hint = Self.hints[status] {
            text += "\n  → \(hint)"
        }
        return text
    }

    /// Every status the hardware layer documents, plus the handful from
    /// AudioToolbox we can actually provoke. Worth the table: the difference
    /// between `!obj` and `!dev` is the difference between a stale object ID
    /// and a device that went away, and those have different fixes.
    private static let knownStatuses: [OSStatus: String] = [
        kAudioHardwareNoError: "kAudioHardwareNoError",
        kAudioHardwareNotRunningError: "kAudioHardwareNotRunningError",
        kAudioHardwareUnspecifiedError: "kAudioHardwareUnspecifiedError",
        kAudioHardwareUnknownPropertyError: "kAudioHardwareUnknownPropertyError",
        kAudioHardwareBadPropertySizeError: "kAudioHardwareBadPropertySizeError",
        kAudioHardwareIllegalOperationError: "kAudioHardwareIllegalOperationError",
        kAudioHardwareBadObjectError: "kAudioHardwareBadObjectError",
        kAudioHardwareBadDeviceError: "kAudioHardwareBadDeviceError",
        kAudioHardwareBadStreamError: "kAudioHardwareBadStreamError",
        kAudioHardwareUnsupportedOperationError: "kAudioHardwareUnsupportedOperationError",
        kAudioDeviceUnsupportedFormatError: "kAudioDeviceUnsupportedFormatError",
        kAudioDevicePermissionsError: "kAudioDevicePermissionsError",
        OSStatus(-50): "paramErr"
    ]

    /// Notes for the statuses whose cause is not guessable from the name.
    /// These are the ones that cost time.
    private static let hints: [OSStatus: String] = [
        kAudioHardwareIllegalOperationError: """
            Often TCC: the audio-capture permission was denied, or the binary is \
            not signed. See AUDIO.md.
            """,
        kAudioHardwareBadObjectError: """
            The object ID is stale — the device or tap was destroyed underneath \
            us. Rebuild it rather than retrying.
            """,
        kAudioDevicePermissionsError: """
            Another process has the device open exclusively (hogged).
            """,
        kAudioHardwareUnknownPropertyError: """
            This object does not carry that property. Usually a wrong scope \
            (input vs output) or the wrong object class.
            """
    ]
}

extension OSStatus {
    /// Throw a decoded `CoreAudioError` unless this status is `noErr`.
    ///
    ///     try AudioHardwareCreateProcessTap(description, &tapID)
    ///         .orThrow("AudioHardwareCreateProcessTap", "creating the global tap")
    func orThrow(_ operation: String, _ context: String? = nil) throws {
        guard self != noErr else { return }
        throw CoreAudioError(operation: operation, status: self, context: context)
    }
}
