import Foundation
import SwiftData

@MainActor
final class ProcessingCoordinator: ObservableObject {
    @Published private(set) var progressByMeeting: [UUID: TranscriptionProgress] = [:]

    private struct PendingJob {
        let meeting: MeetingRecord
        let project: Project
        let context: ModelContext
    }

    private let bridge = PythonBridgeService()
    private var queue: [PendingJob] = []
    private var isRunning = false

    func enqueue(
        meeting: MeetingRecord,
        project: Project,
        context: ModelContext,
        replaceExisting: Bool = false
    ) {
        if !replaceExisting, !meeting.segments.isEmpty {
            return
        }
        guard !queue.contains(where: { $0.meeting.id == meeting.id }),
              progressByMeeting[meeting.id] == nil
        else {
            return
        }

        meeting.status = .processing
        meeting.errorMessage = nil
        project.updatedAt = Date()
        try? context.save()
        try? ArchiveFileManager.shared.writeMeetingManifest(
            meeting,
            project: project
        )

        progressByMeeting[meeting.id] = TranscriptionProgress(
            stage: .preparing,
            fraction: 0,
            message: queue.isEmpty ? "准备本地转写" : "等待上一场会议处理完成"
        )
        queue.append(PendingJob(meeting: meeting, project: project, context: context))
        runNextIfNeeded()
    }

    func progress(for meetingID: UUID) -> TranscriptionProgress? {
        progressByMeeting[meetingID]
    }

    @MainActor
    func recoverInterruptedMeetings(context: ModelContext) {
        let descriptor = FetchDescriptor<MeetingRecord>(
            predicate: #Predicate {
                $0.statusRaw == "processing"
            }
        )
        guard let meetings = try? context.fetch(descriptor) else {
            return
        }

        var changed = false
        for meeting in meetings {
            guard progressByMeeting[meeting.id] == nil,
                  !queue.contains(where: { $0.meeting.id == meeting.id })
            else {
                continue
            }
            meeting.status = meeting.segments.isEmpty
                ? .recorded
                : .awaitingSpeakerReview
            meeting.errorMessage = meeting.segments.isEmpty
                ? "上次转写因应用退出而中断，可以重新开始转写。"
                : "上次说话人处理因应用退出而中断；逐字稿已保留，可重新转写。"
            meeting.project?.updatedAt = Date()
            if let project = meeting.project {
                try? ArchiveFileManager.shared.writeMeetingManifest(
                    meeting,
                    project: project
                )
            }
            changed = true
        }
        if changed {
            try? context.save()
        }
    }

    private func runNextIfNeeded() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        let job = queue.removeFirst()
        let audioURL = job.meeting.audioURL

        Task {
            do {
                guard let audioURL else {
                    throw PythonBridgeError(
                        message: "会议档案中没有可读取的录音。",
                        stage: .preparing
                    )
                }

                let configuredEngine = UserDefaults.standard.string(
                    forKey: "transcriptionEngine"
                ) ?? "auto"
                let engine: String
                if configuredEngine == "auto" {
                    // Accuracy-first default. SenseVoice remains available as
                    // an explicit fast mode for users who prefer speed.
                    engine = "funasr-nano"
                } else {
                    engine = configuredEngine
                }
                let fallbackModel: String
                switch engine {
                case "whisper":
                    fallbackModel = "mlx-community/whisper-large-v3-turbo"
                case "sensevoice":
                    fallbackModel = "iic/SenseVoiceSmall"
                default:
                    fallbackModel = "FunAudioLLM/Fun-ASR-Nano-2512"
                }
                let model = UserDefaults.standard.string(
                    forKey: "transcriptionModel"
                ) ?? fallbackModel
                let output = try await bridge.transcribe(
                    audioURL: audioURL,
                    language: "zh",
                    engine: engine,
                    speakerCount: job.meeting.expectedSpeakerCount ?? 0,
                    model: model
                ) { progress in
                    await MainActor.run {
                        self.progressByMeeting[job.meeting.id] = progress
                    }
                }

                self.progressByMeeting[job.meeting.id] = TranscriptionProgress(
                    stage: .saving,
                    fraction: nil,
                    message: "校验并写入逐字稿"
                )
                try self.apply(
                    output,
                    to: job.meeting,
                    project: job.project,
                    context: job.context
                )
            } catch {
                job.meeting.status = outputWasEmpty(error) ? .readyWithoutSummary : .recorded
                job.meeting.errorMessage = error.localizedDescription
                job.project.updatedAt = Date()
                try? job.context.save()
                try? ArchiveFileManager.shared.writeMeetingManifest(
                    job.meeting,
                    project: job.project
                )
            }

            self.progressByMeeting.removeValue(forKey: job.meeting.id)
            self.isRunning = false
            self.runNextIfNeeded()
        }
    }

    private func apply(
        _ output: TranscriptionOutput,
        to meeting: MeetingRecord,
        project: Project,
        context: ModelContext
    ) throws {
        defer {
            try? FileManager.default.removeItem(at: output.stagingDirectory)
        }

        let replacingExistingTranscript = !meeting.segments.isEmpty
        if replacingExistingTranscript {
            try ArchiveFileManager.shared.archiveCurrentTranscript(meeting)
        }
        for segment in Array(meeting.segments) {
            context.delete(segment)
        }
        meeting.segments.removeAll()

        for imported in output.segments {
            let segment = TranscriptSegment(
                speakerId: imported.speakerID,
                startTime: imported.startTime,
                endTime: imported.endTime,
                text: imported.text
            )
            context.insert(segment)
            meeting.segments.append(segment)
        }

        meeting.transcriptRevision = replacingExistingTranscript
            ? max(meeting.transcriptRevision + 1, output.revision)
            : max(output.revision, 1)
        meeting.summaryTranscriptRevision = -1
        meeting.summarySpeakerMapJSON = "{}"
        meeting.errorMessage = nil
        meeting.status = output.segments.isEmpty
            ? .readyWithoutSummary
            : .awaitingSpeakerReview
        if output.segments.isEmpty {
            meeting.errorMessage = "录音中未识别到可转写的语音。"
        }
        project.updatedAt = Date()

        try ArchiveFileManager.shared.installRawASR(
            from: output.rawASRURL,
            for: meeting
        )
        try ArchiveFileManager.shared.writeTranscript(meeting)
        try context.save()
        try ArchiveFileManager.shared.writeMeetingManifest(
            meeting,
            project: project
        )
    }

    private func outputWasEmpty(_ error: Error) -> Bool {
        if let bridgeError = error as? PythonBridgeError {
            return bridgeError.message.contains("未识别到")
        }
        return false
    }
}
