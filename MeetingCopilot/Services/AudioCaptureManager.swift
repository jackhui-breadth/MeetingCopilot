import AudioToolbox
import AudioSupport
import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let audioDeviceID: AudioDeviceID?
}

struct RecordedAudio {
    let url: URL
    let durationSeconds: Double
}

final class RealtimeVoiceProcessor {
    private var highPassState: [(previousInput: Float, previousOutput: Float)] = []
    private var smoothedRMS: Float = 0
    private var currentGain: Float = 1
    private let autoGainEnabled: Bool

    init(channelCount: Int, autoGainEnabled: Bool) {
        highPassState = Array(
            repeating: (previousInput: 0, previousOutput: 0),
            count: channelCount
        )
        self.autoGainEnabled = autoGainEnabled
    }

    func process(
        _ buffer: AVAudioPCMBuffer,
        sampleRate: Double
    ) -> (level: Float, gainDB: Double) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData
        else {
            return (Self.rmsLevel(buffer: buffer), 0)
        }

        let count = Int(buffer.frameLength)
        guard count > 0 else { return (0, 0) }
        let channelCount = Int(buffer.format.channelCount)
        let highPassCoefficient = Float(
            1 / (1 + (2 * Double.pi * 70 / max(sampleRate, 1)))
        )
        var sumSquares: Float = 0
        var blockPeak: Float = 0

        for channelIndex in 0..<channelCount {
            var state = highPassState[channelIndex]
            let channel = channels[channelIndex]
            for sampleIndex in 0..<count {
                let input = channel[sampleIndex]
                let filtered = highPassCoefficient
                    * (state.previousOutput + input - state.previousInput)
                state.previousInput = input
                state.previousOutput = filtered

                let magnitude = abs(filtered)
                let compressed: Float
                let threshold: Float = 0.28
                if magnitude > threshold {
                    compressed = (magnitude - threshold) * 0.28 + threshold
                } else {
                    compressed = magnitude
                }
                channel[sampleIndex] = filtered < 0 ? -compressed : compressed
                sumSquares += compressed * compressed
                blockPeak = max(blockPeak, compressed)
            }
            highPassState[channelIndex] = state
        }

        let rms = sqrt(sumSquares / Float(max(count * channelCount, 1)))
        if autoGainEnabled, rms > 0.001 {
            smoothedRMS = smoothedRMS == 0
                ? rms
                : smoothedRMS * 0.82 + rms * 0.18
            let targetRMS: Float = 0.075
            var desiredGain = min(max(targetRMS / max(smoothedRMS, 0.001), 0.55), 2.1)
            if blockPeak > 0.82 {
                desiredGain = min(desiredGain, 0.78 / blockPeak)
            }
            let smoothing: Float = desiredGain < currentGain ? 0.38 : 0.055
            currentGain += (desiredGain - currentGain) * smoothing
        }

        let limiterThreshold: Float = 0.92
        let limiterRange: Float = 0.06
        var outputSquares: Float = 0
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for sampleIndex in 0..<count {
                let amplified = channel[sampleIndex] * currentGain
                let magnitude = abs(amplified)
                let limited: Float
                if magnitude > limiterThreshold {
                    limited = limiterThreshold
                        + limiterRange * (1 - exp(-(magnitude - limiterThreshold) / limiterRange))
                } else {
                    limited = magnitude
                }
                let output = amplified < 0 ? -limited : limited
                channel[sampleIndex] = output
                outputSquares += output * output
            }
        }

        let outputRMS = sqrt(
            outputSquares / Float(max(count * channelCount, 1))
        )
        return (
            outputRMS,
            autoGainEnabled
                ? 20 * Double(log10(max(currentGain, 0.000_1)))
                : 0
        )
    }

    private static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            sum += channel[index] * channel[index]
        }
        return sqrt(sum / Float(count))
    }
}

private final class AudioEngineSession: @unchecked Sendable {
    private let engine: AVAudioEngine
    private var audioFile: AVAudioFile?
    private let stateLock = NSLock()
    private var paused = false
    private var smoothedLevel: Float = 0
    private let onLevel: @Sendable (Double) -> Void
    private let onGain: @Sendable (Double) -> Void
    private let onWriteError: @Sendable (String) -> Void
    private let voiceProcessor: RealtimeVoiceProcessor
    private let sampleRate: Double

    init(
        rawURL: URL,
        audioDeviceID: AudioDeviceID?,
        autoGainEnabled: Bool,
        onLevel: @escaping @Sendable (Double) -> Void,
        onGain: @escaping @Sendable (Double) -> Void,
        onWriteError: @escaping @Sendable (String) -> Void
    ) throws {
        self.onLevel = onLevel
        self.onGain = onGain
        self.onWriteError = onWriteError

        let prepared = try Self.prepareInput(
            audioDeviceID: audioDeviceID
        )
        let engine = prepared.engine
        let input = prepared.input
        let format = prepared.format
        self.engine = engine
        sampleRate = format.sampleRate
        voiceProcessor = RealtimeVoiceProcessor(
            channelCount: Int(format.channelCount),
            autoGainEnabled: autoGainEnabled
        )

        try FileManager.default.createDirectory(
            at: rawURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: rawURL.path) {
            try FileManager.default.removeItem(at: rawURL)
        }

        audioFile = try AVAudioFile(
            forWriting: rawURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        do {
            try MCAudioTapInstaller.installTap(
                on: input,
                bus: 0,
                bufferSize: 4_096,
                format: format,
                block: { [weak self] buffer, _ in
                    self?.consume(buffer)
                }
            )
        } catch {
            throw NSError(
                domain: "MeetingCopilot.Audio",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "所选麦克风的音频格式不受支持："
                        + error.localizedDescription
                ]
            )
        }

        try engine.start()
    }

    func setPaused(_ value: Bool) {
        stateLock.lock()
        paused = value
        stateLock.unlock()
        if value {
            onLevel(0)
        }
    }

    func stop() {
        _ = try? MCAudioTapInstaller.removeTap(
            from: engine.inputNode,
            bus: 0
        )
        engine.stop()
        stateLock.lock()
        audioFile = nil
        paused = true
        stateLock.unlock()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        stateLock.lock()
        let isPaused = paused
        var processedLevel: Float = 0
        var gainDB: Double = 0
        if !isPaused {
            let processed = voiceProcessor.process(
                buffer,
                sampleRate: sampleRate
            )
            processedLevel = processed.level
            gainDB = processed.gainDB
            do {
                try audioFile?.write(from: buffer)
            } catch {
                onWriteError("录音写入失败：\(error.localizedDescription)")
            }
        }
        stateLock.unlock()

        guard !isPaused else { return }
        smoothedLevel = smoothedLevel * 0.78 + processedLevel * 0.22
        onLevel(Double(min(max(smoothedLevel * 10, 0), 1)))
        onGain(gainDB)
    }

    private static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }

    private static func prepareInput(
        audioDeviceID: AudioDeviceID?
    ) throws -> (
        engine: AVAudioEngine,
        input: AVAudioInputNode,
        format: AVAudioFormat
    ) {
        var failures: [String] = []
        let candidates: [AudioDeviceID?] = audioDeviceID == nil
            ? [nil]
            : [audioDeviceID, nil]

        for candidateID in candidates {
            let engine = AVAudioEngine()
            let input = engine.inputNode

            if let candidateID,
               let audioUnit = input.audioUnit {
                var mutableID = candidateID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &mutableID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    failures.append("无法切换到所选输入（错误 \(status)）")
                    continue
                }
            }

            engine.prepare()
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                failures.append("输入设备没有有效音频格式")
                continue
            }

            do {
                try MCAudioTapInstaller.installTap(
                    on: input,
                    bus: 0,
                    bufferSize: 4_096,
                    format: format,
                    block: { _, _ in }
                )
                _ = try? MCAudioTapInstaller.removeTap(
                    from: input,
                    bus: 0
                )
                return (engine, input, format)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        throw NSError(
            domain: "MeetingCopilot.Audio",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "无法打开麦克风。请选择实体麦克风后重试。"
                    + (failures.isEmpty
                        ? ""
                        : "\n\(failures.joined(separator: "；"))")
            ]
        )
    }
}

@MainActor
final class AudioCaptureManager: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published var selectedDeviceID: String = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var currentGainDB: Double = 0
    @Published var errorMessage: String?

    private var activeSession: AudioEngineSession?
    private var rawURL: URL?
    private var timerTask: Task<Void, Never>?
    private var noiseReductionEnabled = true

    init() {
        refreshDevices()
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshDevices()
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            refreshDevices()
            return granted
        default:
            return false
        }
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let discovered = discovery.devices.map { device in
            AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                audioDeviceID: Self.coreAudioID(forUID: device.uniqueID)
            )
        }
        devices = discovered

        let remembered = UserDefaults.standard.string(forKey: "selectedAudioDeviceID")
        if let remembered, devices.contains(where: { $0.id == remembered }) {
            selectedDeviceID = remembered
        } else if selectedDeviceID.isEmpty || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id ?? ""
        }
    }

    func startRecording(
        rawURL: URL,
        deviceID: String?
    ) async throws {
        guard !isRecording else { return }
        errorMessage = nil
        refreshDevices()

        let selected = devices.first(where: { $0.id == deviceID })
        let canSelectHardware = selected.map(Self.supportsExplicitRouting) ?? false
        let audioDeviceID = canSelectHardware ? selected?.audioDeviceID : nil
        let autoGainEnabled = UserDefaults.standard.object(
            forKey: "audioAutoGainEnabled"
        ) as? Bool ?? true
        noiseReductionEnabled = UserDefaults.standard.object(
            forKey: "audioNoiseReductionEnabled"
        ) as? Bool ?? true

        let session = try await Task.detached(priority: .userInitiated) {
            try AudioEngineSession(
                rawURL: rawURL,
                audioDeviceID: audioDeviceID,
                autoGainEnabled: autoGainEnabled,
                onLevel: { level in
                    Task { @MainActor [weak self] in
                        self?.audioLevel = level
                    }
                },
                onGain: { gainDB in
                    Task { @MainActor [weak self] in
                        self?.currentGainDB = gainDB
                    }
                },
                onWriteError: { message in
                    Task { @MainActor [weak self] in
                        self?.errorMessage = message
                    }
                }
            )
        }.value

        activeSession = session
        self.rawURL = rawURL
        elapsedSeconds = 0
        isPaused = false
        audioLevel = 0
        currentGainDB = 0
        isRecording = true

        if !selectedDeviceID.isEmpty {
            UserDefaults.standard.set(selectedDeviceID, forKey: "selectedAudioDeviceID")
        }
        startTimer()
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        activeSession?.setPaused(isPaused)
    }

    func stopRecording() async throws -> RecordedAudio {
        guard isRecording, let rawURL else {
            throw NSError(
                domain: "MeetingCopilot.Audio",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "当前没有进行中的录音。"]
            )
        }

        timerTask?.cancel()
        timerTask = nil
        activeSession?.stop()
        activeSession = nil
        self.rawURL = nil
        isRecording = false
        isPaused = false
        audioLevel = 0
        currentGainDB = 0

        let duration = elapsedSeconds
        let finalURL = rawURL
            .deletingLastPathComponent()
            .appendingPathComponent("audio.m4a")

        do {
            try await Self.convertToM4A(
                source: rawURL,
                destination: finalURL,
                noiseReductionEnabled: noiseReductionEnabled,
                autoGainEnabled: UserDefaults.standard.object(
                    forKey: "audioAutoGainEnabled"
                ) as? Bool ?? true
            )
            try? FileManager.default.removeItem(at: rawURL)
            return RecordedAudio(url: finalURL, durationSeconds: duration)
        } catch {
            errorMessage = "AAC 转换失败，已保留原始 CAF 录音。\(error.localizedDescription)"
            return RecordedAudio(url: rawURL, durationSeconds: duration)
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isRecording else { return }
                if !self.isPaused {
                    self.elapsedSeconds += 0.25
                }
            }
        }
    }

    private static func supportsExplicitRouting(_ device: AudioInputDevice) -> Bool {
        let lowercased = device.name.lowercased()
        return !lowercased.contains("iphone") && !lowercased.contains("ipad")
    }

    private static func convertToM4A(
        source: URL,
        destination: URL,
        noiseReductionEnabled: Bool,
        autoGainEnabled: Bool
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            var filters = ["highpass=f=70"]
            if noiseReductionEnabled {
                filters.append("afftdn=nr=8:nf=-42:tn=1")
            }
            if autoGainEnabled {
                filters.append("dynaudnorm=f=150:g=12:p=0.9:m=10")
            }
            filters.append("alimiter=limit=0.95")
            process.arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", source.path,
                "-vn",
                "-ac", "1",
                "-ar", "48000",
                "-af", filters.joined(separator: ","),
                "-c:a", "aac",
                "-b:a", "96k",
                destination.path
            ]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8) ?? "未知 FFmpeg 错误"
                throw ArchiveWriteError(message: message)
            }
        }.value
    }

    private static func coreAudioID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return nil
        }

        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &deviceUID) { pointer in
                AudioObjectGetPropertyData(
                    id,
                    &uidAddress,
                    0,
                    nil,
                    &uidSize,
                    pointer
                )
            }
            if status == noErr, (deviceUID as String) == uid {
                return id
            }
        }
        return nil
    }
}
