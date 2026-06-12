import CoreAudio
import Foundation

enum CoreAudioError: Error, LocalizedError {
    case osStatus(OSStatus, String)
    case failure(String)

    var errorDescription: String? {
        switch self {
        case let .osStatus(status, what): return "\(what) failed (OSStatus \(status))"
        case let .failure(what): return what
        }
    }
}

func checkCA(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError.osStatus(status, what()) }
}

/// Renders a four-char code (property selectors etc.) readably for error messages.
func caFourCC(_ value: UInt32) -> String {
    let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                 UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)'"
    }
    return String(value)
}

// AudioObjectID is a typealias of UInt32; these helpers follow the pattern in
// Apple's AudioCap sample.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func readObjectIDList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = Self.globalAddress(selector)
        var dataSize: UInt32 = 0
        try checkCA(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize),
                    "GetPropertyDataSize \(caFourCC(selector))")
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var list = [AudioObjectID](repeating: .unknownObject, count: count)
        try checkCA(AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &list),
                    "GetPropertyData \(caFourCC(selector))")
        return list
    }

    func readUInt32(_ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = Self.globalAddress(selector)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        try checkCA(AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value),
                    "GetPropertyData \(caFourCC(selector))")
        return value
    }

    func readBool(_ selector: AudioObjectPropertySelector) -> Bool {
        ((try? readUInt32(selector)) ?? 0) != 0
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.globalAddress(selector)
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        try checkCA(status, "GetPropertyData \(caFourCC(selector))")
        guard let value else { throw CoreAudioError.failure("Nil string for \(caFourCC(selector))") }
        return value as String
    }

    func readAudioObjectID(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var address = Self.globalAddress(selector)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var value = AudioObjectID.unknownObject
        try checkCA(AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value),
                    "GetPropertyData \(caFourCC(selector))")
        return value
    }

    func readASBD(_ selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var address = Self.globalAddress(selector)
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var value = AudioStreamBasicDescription()
        try checkCA(AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value),
                    "GetPropertyData \(caFourCC(selector))")
        return value
    }

    // MARK: Process objects

    var processBundleID: String { (try? readString(kAudioProcessPropertyBundleID)) ?? "" }
    var processIsRunningInput: Bool { readBool(kAudioProcessPropertyIsRunningInput) }
    var processIsRunningOutput: Bool { readBool(kAudioProcessPropertyIsRunningOutput) }

    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readObjectIDList(kAudioHardwarePropertyProcessObjectList)
    }

    // MARK: Devices

    static func readDefaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.readAudioObjectID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    var deviceUID: String? { try? readString(kAudioDevicePropertyDeviceUID) }
}

/// Block-based Core Audio property listener with managed lifetime.
final class CoreAudioPropertyObserver {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init?(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
          queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.objectID = objectID
        self.address = AudioObjectID.globalAddress(selector)
        self.queue = queue
        self.block = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard status == noErr else {
            Log.error("AudioObjectAddPropertyListenerBlock \(caFourCC(selector)) failed (\(status))")
            return nil
        }
        installed = true
    }

    func invalidate() {
        guard installed else { return }
        installed = false
        _ = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }

    deinit { invalidate() }
}
