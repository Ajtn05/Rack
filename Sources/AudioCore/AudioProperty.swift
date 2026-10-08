import CoreAudio
import Foundation

/// Thin wrappers over `AudioObjectGetPropertyData` and friends.
///
/// Every Core Audio property read is the same six lines of address setup, size
/// juggling and status checking. Written out at each call site it buries the
/// interesting part, and each copy is a chance to get the scope wrong. These
/// helpers run off the audio thread only — they allocate.
enum AudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func exists(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(objectID, &address)
    }

    /// Read a fixed-size property into a value of type `T`.
    static func read<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        as type: T.Type = T.self,
        context: String? = nil
    ) throws -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }

        try AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
            .orThrow("AudioObjectGetPropertyData", context)
        return buffer.pointee
    }

    /// Read a property whose value is a CFString — device UIDs and names.
    ///
    /// Core Audio hands back a +1 reference; binding it to a Swift `CFString`
    /// lets ARC release it at scope exit, which balances.
    static func readString(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        context: String? = nil
    ) throws -> String {
        let value: CFString = try read(objectID, address, as: CFString.self, context: context)
        return value as String
    }

    /// Read a variable-size property as an array of `T`.
    static func readArray<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of type: T.Type = T.self,
        context: String? = nil
    ) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
            .orThrow("AudioObjectGetPropertyDataSize", context)

        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }

        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }

        try AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
            .orThrow("AudioObjectGetPropertyData", context)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    /// Total channel count across every stream in `scope`.
    ///
    /// `kAudioDevicePropertyStreamConfiguration` returns a variable-length
    /// `AudioBufferList`, so this cannot go through `read`.
    static func channelCount(
        _ objectID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        context: String? = nil
    ) throws -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
            .orThrow("AudioObjectGetPropertyDataSize", context)
        guard size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        try AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw)
            .orThrow("AudioObjectGetPropertyData", context)

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
