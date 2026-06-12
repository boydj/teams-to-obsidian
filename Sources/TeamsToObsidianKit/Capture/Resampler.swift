import AVFoundation

/// Streams arbitrary-format PCM buffers into 16 kHz mono Int16 samples (what
/// whisper.cpp wants). Stateful — use one instance per audio stream, since the
/// converter carries filter state across buffers.
final class Resampler {
    static let outputSampleRate: Double = 16_000

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: Self.outputSampleRate,
                                      channels: 1,
                                      interleaved: true),
              let conv = AVAudioConverter(from: inputFormat, to: out) else { return nil }
        outputFormat = out
        converter = conv
        ratio = Self.outputSampleRate / inputFormat.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        // .noDataNow (not .endOfStream) keeps the converter alive for the next buffer.
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let channel = outBuffer.int16ChannelData else { return [] }
        return [Int16](UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
    }
}
