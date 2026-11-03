import Foundation

enum TranscriptionStage: String, Sendable {
    case preparing
    case audioExtraction
    case transcription
    case diarization
    case alignment
    case saving

    var title: String {
        switch self {
        case .preparing: "准备转写"
        case .audioExtraction: "提取音频"
        case .transcription: "识别语音"
        case .diarization: "区分发言人"
        case .alignment: "对齐逐字稿"
        case .saving: "写入档案"
        }
    }
}

struct TranscriptionProgress: Sendable, Equatable {
    let stage: TranscriptionStage
    let fraction: Double?
    let message: String
}

struct ImportedTranscriptSegment: Sendable {
    let id: UUID
    let speakerID: String
    let startTime: Double
    let endTime: Double
    let text: String
}

struct TranscriptionOutput: Sendable {
    let stagingDirectory: URL
    let transcriptURL: URL
    let rawASRURL: URL
    let revision: Int
    let segments: [ImportedTranscriptSegment]
}

struct PythonBridgeError: LocalizedError, Sendable {
    let message: String
    let stage: TranscriptionStage?

    var errorDescription: String? { message }
}

actor PythonBridgeService {
    private struct ProgressEvent: Decodable {
        let type: String
        let stage: String?
        let fraction: Double?
        let message: String?
        let code: String?
        let recoverable: Bool?
    }

    private struct StagingTranscript: Decodable {
        let schemaVersion: Int
        let revision: Int
        let segments: [StagingSegment]
    }

    private struct StagingSegment: Decodable {
        let id: UUID
        let speakerId: String
        let startTime: Double
        let endTime: Double
        let text: String
    }

    private struct CompletionArtifacts: Decodable {
        let transcript: String?
        let rawASR: String?
    }

    private struct CompletionEvent: Decodable {
        let type: String
        let stage: String?
        let artifacts: CompletionArtifacts?
    }

    func transcribe(
        audioURL: URL,
        language: String,
        engine: String,
        speakerCount: Int,
        model: String,
        onProgress: @escaping @Sendable (TranscriptionProgress) async -> Void
    ) async throws -> TranscriptionOutput {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw PythonBridgeError(message: "找不到会议录音文件。", stage: .preparing)
        }

        let scriptURL = try Self.processingScriptURL()
        let pythonURL = try Self.pythonExecutableURL()
        let ffmpegURL = Self.ffmpegExecutableURL()
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MeetingCopilot-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        var keepStagingDirectory = false
        defer {
            if !keepStagingDirectory {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        let process = Process()
        process.executableURL = pythonURL
        let modelArgument: String
        switch engine {
        case "whisper":
            modelArgument = "--whisper-model"
        case "sensevoice":
            modelArgument = "--sensevoice-model"
        default:
            modelArgument = "--funasr-model"
        }
        process.arguments = [
            scriptURL.path,
            "--audio", audioURL.path,
            "--output-stage-dir", stagingDirectory.path,
            "--engine", engine,
            "--language", language,
            "--speaker-count", String(max(speakerCount, 0)),
            modelArgument, model,
            "--ffmpeg-path", ffmpegURL.path
        ]
        process.currentDirectoryURL = stagingDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutReader = Task {
            var completion: CompletionEvent?
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    if let event = Self.decodeProgressEvent(line) {
                        if event.type == "error" {
                            throw PythonBridgeError(
                                message: event.message ?? "转写服务返回错误。",
                                stage: event.stage.flatMap(TranscriptionStage.init(rawValue:))
                            )
                        }
                        if event.type == "progress" {
                            await onProgress(
                                TranscriptionProgress(
                                    stage: event.stage
                                        .flatMap(TranscriptionStage.init(rawValue:))
                                        ?? .transcription,
                                    fraction: event.fraction,
                                    message: event.message ?? "正在处理"
                                )
                            )
                        }
                    } else if let event = Self.decodeCompletionEvent(line) {
                        completion = event
                    }
                }
            } catch {
                throw error
            }
            return completion
        }

        let stderrReader = Task {
            var captured = Data()
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    if captured.count < 64_000 {
                        captured.append(line.data(using: .utf8) ?? Data())
                        captured.append(0x0A)
                    }
                }
            } catch {
                // The exit status and protocol event provide the actionable error.
            }
            return String(data: captured, encoding: .utf8) ?? ""
        }

        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }

        let completion: CompletionEvent?
        do {
            completion = try await stdoutReader.value
        } catch {
            _ = await stderrReader.value
            throw error
        }
        let stderr = await stderrReader.value

        guard status == 0 else {
            let detail = stderr
                .split(separator: "\n")
                .suffix(6)
                .joined(separator: "\n")
            throw PythonBridgeError(
                message: detail.isEmpty
                    ? "转写进程异常退出（代码 \(status)）。"
                    : "转写失败：\n\(detail)",
                stage: .transcription
            )
        }

        guard completion?.type == "completed" else {
            throw PythonBridgeError(
                message: "转写进程结束，但没有返回完成事件。",
                stage: .saving
            )
        }

        let transcriptURL = stagingDirectory
            .appendingPathComponent(
                completion?.artifacts?.transcript ?? "transcript.json"
            )
        let rawASRURL = stagingDirectory
            .appendingPathComponent(
                completion?.artifacts?.rawASR ?? "asr.raw.json"
            )

        do {
            let output = try Self.loadAndValidate(
                transcriptURL: transcriptURL,
                rawASRURL: rawASRURL,
                stagingDirectory: stagingDirectory
            )
            keepStagingDirectory = true
            return output
        } catch {
            throw error
        }
    }

    static func pythonExecutableForDisplay() -> String {
        (try? pythonExecutableURL().path) ?? "未找到 Python 3"
    }

    private static func processingScriptURL() throws -> URL {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent("Scripts", isDirectory: true)
                    .appendingPathComponent("process_meeting.py")
            )
        }
        if let bundled = Bundle.module.url(
            forResource: "process_meeting",
            withExtension: "py",
            subdirectory: "Scripts"
        ) {
            candidates.append(bundled)
        }
        if let bundled = Bundle.module.url(
            forResource: "process_meeting",
            withExtension: "py"
        ) {
            candidates.append(bundled)
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("MeetingCopilot/Resources/Scripts/process_meeting.py")
        )

        if let match = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return match
        }
        throw PythonBridgeError(
            message: "应用内缺少本地转写脚本，请重新构建应用。",
            stage: .preparing
        )
    }

    private static func pythonExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MEETINGCOPILOT_PYTHON"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let projectRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        )
        let projectRootBesideApp = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            projectRoot.appendingPathComponent(".venv/bin/python3").path,
            projectRootBesideApp.appendingPathComponent(".venv/bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        if let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return URL(fileURLWithPath: path)
        }
        throw PythonBridgeError(
            message: "没有找到 Python 3。请安装 Python 后重试。",
            stage: .preparing
        )
    }

    private static func ffmpegExecutableURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["MEETINGCOPILOT_FFMPEG"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return URL(
            fileURLWithPath: candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) ?? "/opt/homebrew/bin/ffmpeg"
        )
    }

    private static func decodeProgressEvent(_ line: String) -> ProgressEvent? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(ProgressEvent.self, from: data),
              event.type == "progress" || event.type == "error"
        else {
            return nil
        }
        return event
    }

    private static func decodeCompletionEvent(_ line: String) -> CompletionEvent? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(CompletionEvent.self, from: data),
              event.type == "completed"
        else {
            return nil
        }
        return event
    }

    private static func loadAndValidate(
        transcriptURL: URL,
        rawASRURL: URL,
        stagingDirectory: URL
    ) throws -> TranscriptionOutput {
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            throw PythonBridgeError(
                message: "转写完成，但结果文件不存在。",
                stage: .saving
            )
        }
        guard FileManager.default.fileExists(atPath: rawASRURL.path) else {
            throw PythonBridgeError(
                message: "转写完成，但原始识别结果不存在。",
                stage: .saving
            )
        }

        let data = try Data(contentsOf: transcriptURL)
        let staging = try JSONDecoder().decode(StagingTranscript.self, from: data)
        guard staging.schemaVersion == 1, staging.revision > 0 else {
            throw PythonBridgeError(
                message: "逐字稿版本不受支持。",
                stage: .saving
            )
        }

        var segmentIDs = Set<UUID>()
        let segments = try staging.segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw PythonBridgeError(message: "逐字稿包含空文本段。", stage: .saving)
            }
            guard segment.startTime.isFinite,
                  segment.endTime.isFinite,
                  segment.startTime >= 0,
                  segment.endTime >= segment.startTime
            else {
                throw PythonBridgeError(message: "逐字稿包含无效时间戳。", stage: .saving)
            }
            guard segmentIDs.insert(segment.id).inserted else {
                throw PythonBridgeError(message: "逐字稿包含重复片段。", stage: .saving)
            }
            let speakerID = segment.speakerId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speakerID.isEmpty else {
                throw PythonBridgeError(message: "逐字稿缺少发言人标签。", stage: .saving)
            }
            return ImportedTranscriptSegment(
                id: segment.id,
                speakerID: speakerID,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: text
            )
        }
        .sorted { $0.startTime < $1.startTime }

        return TranscriptionOutput(
            stagingDirectory: stagingDirectory,
            transcriptURL: transcriptURL,
            rawASRURL: rawASRURL,
            revision: staging.revision,
            segments: segments
        )
    }
}
