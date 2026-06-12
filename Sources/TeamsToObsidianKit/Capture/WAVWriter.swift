import Foundation

/// Incremental 16 kHz mono 16-bit PCM WAV writer designed to survive crashes:
/// samples are appended (and periodically fsynced) as they arrive, so a crash
/// mid-meeting loses nothing but the header sizes — which repairHeader(at:)
/// reconstructs from the file length. This is why we hand-roll RIFF instead of
/// using AVAudioFile.
final class WAVWriter {
    let url: URL
    let sampleRate: Int

    private let handle: FileHandle
    private let queue = DispatchQueue(label: "tto.wavwriter")
    private var dataBytes: UInt32 = 0
    private var lastSync = Date()
    private var finalized = false

    init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataSize: 0, sampleRate: UInt32(sampleRate)))
    }

    func append(samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        queue.async { [self] in
            guard !finalized else { return }
            do {
                try handle.write(contentsOf: data)
                dataBytes &+= UInt32(data.count)
                if Date().timeIntervalSince(lastSync) > 5 {
                    try? handle.synchronize()
                    lastSync = Date()
                }
            } catch {
                Log.error("WAV write failed for \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// Audio duration written so far.
    var durationSeconds: Double {
        queue.sync { Double(dataBytes) / Double(sampleRate * 2) }
    }

    /// Patches the header sizes and closes the file. Safe to call more than once.
    func finalize() {
        queue.sync {
            guard !finalized else { return }
            finalized = true
            do {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Self.header(dataSize: dataBytes, sampleRate: UInt32(sampleRate)))
                try handle.synchronize()
                try handle.close()
            } catch {
                Log.error("WAV finalize failed for \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// Rewrites the 44-byte header of an unfinalized recording, deriving the
    /// data size from the file length. Used by orphan recovery after a crash.
    static func repairHeader(at url: URL, sampleRate: Int = 16_000) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? UInt64, size >= 44 else { return }
        let dataSize = UInt32(min(size - 44, UInt64(UInt32.max)))
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataSize: dataSize, sampleRate: UInt32(sampleRate)))
        try handle.synchronize()
    }

    /// Duration implied by the file length (header sizes not required).
    static func dataDurationSeconds(at url: URL, sampleRate: Int = 16_000) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size >= 44 else { return nil }
        return Double(size - 44) / Double(sampleRate * 2)
    }

    static func header(dataSize: UInt32, sampleRate: UInt32) -> Data {
        var d = Data(capacity: 44)
        d.append(contentsOf: Array("RIFF".utf8))
        d.appendLE(36 &+ dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.appendLE(UInt32(16))            // fmt chunk size
        d.appendLE(UInt16(1))             // PCM
        d.appendLE(UInt16(1))             // mono
        d.appendLE(sampleRate)
        d.appendLE(sampleRate &* 2)       // byte rate
        d.appendLE(UInt16(2))             // block align
        d.appendLE(UInt16(16))            // bits per sample
        d.append(contentsOf: Array("data".utf8))
        d.appendLE(dataSize)
        return d
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
