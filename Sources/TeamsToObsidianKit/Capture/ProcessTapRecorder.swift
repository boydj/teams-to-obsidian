import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Records the audio OUTPUT of a set of processes (Teams) — or all system
/// audio in globalExclude mode — via a Core Audio process tap routed through a
/// private aggregate device. Requires macOS 14.4+ and the "System Audio
/// Recording Only" permission (prompted on first use).
///
/// Call sequence verified against Apple's AudioCap sample:
/// CATapDescription → AudioHardwareCreateProcessTap → aggregate device with the
/// tap in kAudioAggregateDeviceTapListKey → read kAudioTapPropertyFormat →
/// AudioDeviceCreateIOProcIDWithBlock → AudioDeviceStart. Teardown in reverse.
final class ProcessTapRecorder {
    enum Mode {
        /// Tap only these process objects (mono mixdown).
        case processes([AudioObjectID])
        /// Tap all system audio. Fallback for the known case where a Teams
        /// process tap yields silence.
        case globalExcludingNone
    }

    private let mode: Mode
    private let writer: WAVWriter
    private let ioQueue = DispatchQueue(label: "tto.tap-io")
    private let stateLock = NSLock()

    private var tapID = AudioObjectID.unknownObject
    private var aggregateID = AudioObjectID.unknownObject
    private var ioProcID: AudioDeviceIOProcID?
    private var resampler: Resampler?
    private var _lastNonSilentAt = Date()
    private var _peakRMS: Float = 0

    init(mode: Mode, writer: WAVWriter) {
        self.mode = mode
        self.writer = writer
    }

    /// Last time a buffer with non-trivial signal arrived (silence-watchdog input).
    var lastNonSilentAt: Date {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastNonSilentAt
    }

    /// Peak RMS observed so far (record-test diagnostics).
    var peakRMS: Float {
        stateLock.lock(); defer { stateLock.unlock() }
        return _peakRMS
    }

    func start() throws {
        let description: CATapDescription
        switch mode {
        case .processes(let ids):
            guard !ids.isEmpty else { throw CoreAudioError.failure("No processes to tap") }
            description = CATapDescription(monoMixdownOfProcesses: ids.map { NSNumber(value: $0) })
        case .globalExcludingNone:
            description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        }
        description.uuid = UUID()
        description.name = "teams-to-obsidian tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted   // the user keeps hearing the meeting

        var newTapID = AudioObjectID.unknownObject
        try checkCA(AudioHardwareCreateProcessTap(description, &newTapID), "AudioHardwareCreateProcessTap")
        tapID = newTapID

        do {
            let outputDevice = try AudioObjectID.readDefaultOutputDevice()
            guard let outputUID = outputDevice.deviceUID else {
                throw CoreAudioError.failure("Default output device has no UID")
            }

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "teams-to-obsidian aggregate",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ]
            var newAggregateID = AudioObjectID.unknownObject
            try checkCA(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
                        "AudioHardwareCreateAggregateDevice")
            aggregateID = newAggregateID

            // Never assume the tap format — Teams has been observed at 24 kHz.
            var asbd = try tapID.readASBD(kAudioTapPropertyFormat)
            guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
                throw CoreAudioError.failure("Unsupported tap stream format")
            }
            Log.info("Process tap running at \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) channel(s).")
            guard let resampler = Resampler(inputFormat: tapFormat) else {
                throw CoreAudioError.failure("Could not build resampler for tap format")
            }
            self.resampler = resampler

            var procID: AudioDeviceIOProcID?
            try checkCA(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
                [weak self] _, inInputData, _, _, _ in
                self?.handle(inInputData, format: tapFormat)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            ioProcID = procID

            try checkCA(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")

            stateLock.lock()
            _lastNonSilentAt = Date()
            stateLock.unlock()
        } catch {
            stop()   // tear down whatever was partially built
            throw error
        }
    }

    /// Stops capture and destroys the tap/aggregate. Does NOT finalize the
    /// writer — the owner does, so a rebuilt tap can keep appending to the same WAV.
    func stop() {
        if aggregateID != .unknownObject, let procID = ioProcID {
            _ = AudioDeviceStop(aggregateID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != .unknownObject {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknownObject
        }
        if tapID != .unknownObject {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknownObject
        }
    }

    private func handle(_ bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let resampler else { return }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil) else {
            return
        }
        let samples = resampler.convert(pcm)
        guard !samples.isEmpty else { return }

        let rms = Self.rms(samples)
        if rms > 0.001 {   // ≈ -60 dBFS noise floor
            stateLock.lock()
            _lastNonSilentAt = Date()
            if rms > _peakRMS { _peakRMS = rms }
            stateLock.unlock()
        }
        writer.append(samples: samples)
    }

    private static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc = 0.0
        for s in samples {
            let v = Double(s) / 32768.0
            acc += v * v
        }
        return Float((acc / Double(samples.count)).squareRoot())
    }
}
