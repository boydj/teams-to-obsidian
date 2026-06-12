import AVFoundation
import Foundation

/// Records the default input device (microphone) into the shared WAV writer.
/// Requires the Microphone permission (prompted on first use).
final class MicRecorder {
    private let engine = AVAudioEngine()
    private let writer: WAVWriter
    private let voiceProcessing: Bool
    private var resampler: Resampler?

    init(writer: WAVWriter, voiceProcessing: Bool) {
        self.writer = writer
        self.voiceProcessing = voiceProcessing
    }

    func start() throws {
        let input = engine.inputNode
        if voiceProcessing {
            // Apple's echo cancellation; experimental — can fight Teams' own
            // processing, so it is off by default (see config capture.micVoiceProcessing).
            do { try input.setVoiceProcessingEnabled(true) }
            catch { Log.error("Voice processing unavailable: \(error)") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError.failure("No audio input device available")
        }
        guard let resampler = Resampler(inputFormat: format) else {
            throw CoreAudioError.failure("Could not build resampler for mic format")
        }
        self.resampler = resampler

        // format: nil → the node's own format; buffers arrive on an internal
        // (non-realtime) thread, so writing from the callback is fine.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self, let resampler = self.resampler else { return }
            self.writer.append(samples: resampler.convert(buffer))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
