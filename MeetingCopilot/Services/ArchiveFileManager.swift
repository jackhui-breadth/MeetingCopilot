import Foundation
import SwiftData

struct ArchiveWriteError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ArchiveFileManager {
    static let shared = ArchiveFileManager()

    let rootURL: URL

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("MeetingCopilot", isDirectory: true)
    ) {
        self.rootURL = rootURL
    }

    func ensureRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func createProjectDirectory(for project: Project) throws -> URL {
        try ensureRootDirectory()
        if !project.folderPath.isEmpty {
            let existing = URL(fileURLWithPath: project.folderPath, isDirectory: true)
            try FileManager.default.createDirectory(
                at: existing,
                withIntermediateDirectories: true
            )
            return existing
        }

        let directory = try uniqueDirectory(
            at: rootURL,
            baseName: "\(safeComponent(project.name))-\(shortID(project.id))"
        )
        project.folderPath = directory.path
        return directory
    }

    func createMeetingDirectory(
        for meeting: MeetingRecord,
        in project: Project
    ) throws -> URL {
        try ensureRootDirectory()
        let projectDirectory = try createProjectDirectory(for: project)
        let baseName = meetingDirectoryBaseName(
            date: meeting.date,
            title: meeting.title,
            id: meeting.id
        )

        return try uniqueDirectory(
            at: projectDirectory,
            baseName: baseName
        )
    }

    @MainActor
    func renameProject(
        _ project: Project,
        to proposedName: String,
        context: ModelContext
    ) throws {
        let newName = proposedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !newName.isEmpty else {
            throw ArchiveWriteError(message: "项目名称不能为空")
        }
        guard newName != project.name else { return }

        let previousName = project.name
        let previousUpdatedAt = project.updatedAt
        let previousFolderPath = project.folderPath
        let previousMeetingPaths = Dictionary(
            uniqueKeysWithValues: project.meetings.map {
                ($0.id, $0.folderPath)
            }
        )
        let oldURL = previousFolderPath.isEmpty
            ? nil
            : URL(fileURLWithPath: previousFolderPath, isDirectory: true)

        project.name = newName
        project.updatedAt = Date()

        do {
            if let oldURL,
               FileManager.default.fileExists(atPath: oldURL.path) {
                let newURL = uniqueAvailableDirectory(
                    at: oldURL.deletingLastPathComponent(),
                    baseName: "\(safeComponent(newName))-\(shortID(project.id))"
                )
                try writeProjectManifest(project, to: oldURL)
                if oldURL.standardizedFileURL != newURL.standardizedFileURL {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                }

                let oldPrefix = oldURL.path + "/"
                for meeting in project.meetings {
                    if meeting.folderPath.hasPrefix(oldPrefix) {
                        meeting.folderPath = newURL.path
                            + String(meeting.folderPath.dropFirst(oldPrefix.count))
                    }
                }
                project.folderPath = newURL.path
                try writeProjectManifest(project, to: newURL)
                for meeting in project.meetings {
                    try writeMeetingManifest(meeting, project: project)
                }
            }
            try context.save()
        } catch {
            if let oldURL,
               FileManager.default.fileExists(atPath: project.folderPath),
               project.folderPath != oldURL.path {
                try? FileManager.default.moveItem(
                    at: URL(fileURLWithPath: project.folderPath),
                    to: oldURL
                )
            }
            project.name = previousName
            project.updatedAt = previousUpdatedAt
            project.folderPath = previousFolderPath
            for meeting in project.meetings {
                if let path = previousMeetingPaths[meeting.id] {
                    meeting.folderPath = path
                }
            }
            context.rollback()
            if let oldURL {
                try? writeProjectManifest(project, to: oldURL)
            }
            throw error
        }
    }

    @MainActor
    func renameMeeting(
        _ meeting: MeetingRecord,
        in project: Project,
        to proposedTitle: String,
        context: ModelContext
    ) throws {
        let newTitle = proposedTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !newTitle.isEmpty else {
            throw ArchiveWriteError(message: "会议标题不能为空")
        }
        guard newTitle != meeting.title else { return }

        let previousTitle = meeting.title
        let previousFolderPath = meeting.folderPath
        let previousProjectUpdatedAt = project.updatedAt
        let oldURL = previousFolderPath.isEmpty
            ? nil
            : URL(fileURLWithPath: previousFolderPath, isDirectory: true)

        meeting.title = newTitle
        project.updatedAt = Date()

        do {
            if let oldURL,
               FileManager.default.fileExists(atPath: oldURL.path) {
                let newURL = uniqueAvailableDirectory(
                    at: oldURL.deletingLastPathComponent(),
                    baseName: meetingDirectoryBaseName(
                        date: meeting.date,
                        title: newTitle,
                        id: meeting.id
                    )
                )
                try writeMeetingManifest(meeting, project: project)
                if oldURL.standardizedFileURL != newURL.standardizedFileURL {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                }
                meeting.folderPath = newURL.path
                try writeMeetingManifest(meeting, project: project)
                try writeProjectManifest(project)
            }
            try context.save()
        } catch {
            if let oldURL,
               FileManager.default.fileExists(atPath: meeting.folderPath),
               meeting.folderPath != oldURL.path {
                try? FileManager.default.moveItem(
                    at: URL(fileURLWithPath: meeting.folderPath),
                    to: oldURL
                )
            }
            meeting.title = previousTitle
            meeting.folderPath = previousFolderPath
            project.updatedAt = previousProjectUpdatedAt
            context.rollback()
            if oldURL != nil {
                try? writeMeetingManifest(meeting, project: project)
            }
            throw error
        }
    }

    func writeProjectManifest(_ project: Project) throws {
        let directory = try createProjectDirectory(for: project)
        try writeProjectManifest(project, to: directory)
    }

    func writeProjectManifest(
        _ project: Project,
        to directory: URL
    ) throws {
        let manifest = ProjectManifest(
            schemaVersion: 1,
            id: project.id,
            name: project.name,
            projectDescription: project.projectDescription,
            colorHex: project.colorHex,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
        try writeJSON(manifest, to: directory.appendingPathComponent("project.json"))
    }

    func writeMeetingManifest(
        _ meeting: MeetingRecord,
        project: Project
    ) throws {
        guard !meeting.folderPath.isEmpty else { return }

        let stages = Dictionary(
            uniqueKeysWithValues: MeetingManifest.stageNames.map { stage in
                let snapshot = StageManifest(
                    status: inferredStageStatus(for: stage, meeting: meeting),
                    finishedAt: nil,
                    error: meeting.errorMessage
                )
                return (stage, snapshot)
            }
        )

        let manifest = MeetingManifest(
            schemaVersion: 1,
            id: meeting.id,
            projectId: project.id,
            title: meeting.title,
            createdAt: meeting.date,
            updatedAt: Date(),
            durationSeconds: meeting.durationSeconds,
            language: "zh",
            status: meeting.status.rawValue,
            errorMessage: meeting.errorMessage,
            audio: AudioManifest(
                fileName: meeting.audioFileName,
                codec: meeting.audioFileName.hasSuffix(".caf") ? "pcm" : "aac",
                sampleRate: 48_000,
                channels: 1,
                bitRate: meeting.audioFileName.hasSuffix(".caf") ? nil : 96_000,
                sha256: nil,
                devices: []
            ),
            speakerMap: meeting.speakerMap,
            processing: stages,
            summaryGeneration: meeting.summaryGeneratedAt.map {
                SummaryGenerationManifest(
                    transcriptRevision: meeting.summaryTranscriptRevision,
                    transcriptSha256: nil,
                    provider: "ollama",
                    model: UserDefaults.standard.string(
                        forKey: "minutesModel"
                    ) ?? "qwen3.5:9b",
                    promptVersion: 2,
                    generatedAt: $0,
                    usedRealNames: !meeting.participantNames.isEmpty
                )
            }
        )

        try writeJSON(
            manifest,
            to: URL(fileURLWithPath: meeting.folderPath)
                .appendingPathComponent("meeting.json")
        )
    }

    func writeTranscript(_ meeting: MeetingRecord) throws {
        guard !meeting.folderPath.isEmpty else { return }

        let transcript = TranscriptManifest(
            schemaVersion: 1,
            revision: meeting.transcriptRevision,
            sourceAsrSha256: nil,
            updatedAt: Date(),
            segments: meeting.sortedSegments.map {
                TranscriptManifestSegment(
                    id: $0.id,
                    speakerId: $0.speakerId,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text,
                    edited: false
                )
            }
        )
        try writeJSON(
            transcript,
            to: URL(fileURLWithPath: meeting.folderPath)
                .appendingPathComponent("transcript.json")
        )
    }

    func archiveCurrentTranscript(_ meeting: MeetingRecord) throws {
        guard !meeting.folderPath.isEmpty, !meeting.segments.isEmpty else {
            return
        }
        let transcript = TranscriptManifest(
            schemaVersion: 1,
            revision: meeting.transcriptRevision,
            sourceAsrSha256: nil,
            updatedAt: Date(),
            segments: meeting.sortedSegments.map {
                TranscriptManifestSegment(
                    id: $0.id,
                    speakerId: $0.speakerId,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text,
                    edited: false
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transcript)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        try atomicWrite(
            data,
            to: URL(fileURLWithPath: meeting.folderPath)
                .appendingPathComponent("revisions", isDirectory: true)
                .appendingPathComponent("transcript-\(stamp).json")
        )
    }

    func writeSummary(_ meeting: MeetingRecord) throws {
        guard !meeting.folderPath.isEmpty else { return }
        try writeText(
            meeting.summaryMarkdown,
            to: URL(fileURLWithPath: meeting.folderPath)
                .appendingPathComponent("minutes.md")
        )
    }

    func installRawASR(
        from stagingURL: URL,
        for meeting: MeetingRecord
    ) throws {
        guard !meeting.folderPath.isEmpty else {
            throw ArchiveWriteError(message: "会议目录尚未创建")
        }
        let data = try Data(contentsOf: stagingURL)
        guard !data.isEmpty,
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            throw ArchiveWriteError(message: "原始转写结果不是有效的 JSON")
        }
        try atomicWrite(
            data,
            to: URL(fileURLWithPath: meeting.folderPath)
                .appendingPathComponent("asr.raw.json")
        )
    }

    func writeAll(
        project: Project,
        meeting: MeetingRecord
    ) throws {
        try writeProjectManifest(project)
        try writeMeetingManifest(meeting, project: project)
        try writeTranscript(meeting)
        try writeSummary(meeting)
    }

    @discardableResult
    func moveToTrash(_ url: URL) throws -> URL? {
        let fileManager = FileManager.default
        let target = url.standardizedFileURL
        let archiveRoot = rootURL.standardizedFileURL
        let rootPath = archiveRoot.path
        guard target.path != rootPath,
              target.path.hasPrefix(rootPath + "/"),
              fileManager.fileExists(atPath: target.path)
        else {
            if !fileManager.fileExists(atPath: target.path) {
                return nil
            }
            throw ArchiveWriteError(
                message: "拒绝删除归档目录之外的路径：\(target.path)"
            )
        }

        var resultingURL: NSURL?
        try fileManager.trashItem(
            at: target,
            resultingItemURL: &resultingURL
        )
        return resultingURL as URL?
    }

    func folderComponent(_ value: String, fallback: String) -> String {
        let result = safeComponent(value)
        return result.isEmpty ? fallback : result
    }

    private func uniqueDirectory(
        at parent: URL,
        baseName: String
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent(
                "\(baseName)-\(suffix)",
                isDirectory: true
            )
            suffix += 1
        }
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: false
        )
        return candidate
    }

    private func uniqueAvailableDirectory(
        at parent: URL,
        baseName: String
    ) -> URL {
        var candidate = parent.appendingPathComponent(
            baseName,
            isDirectory: true
        )
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent(
                "\(baseName)-\(suffix)",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }

    private func meetingDirectoryBaseName(
        date: Date,
        title: String,
        id: UUID
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return [
            dateFormatter.string(from: date),
            safeComponent(title),
            shortID(id)
        ].joined(separator: "_")
    }

    private func safeComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let pieces = value.components(separatedBy: invalid)
        let joined = pieces.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = joined.isEmpty ? "未命名" : joined
        return String(normalized.prefix(50))
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(6)).uppercased()
    }

    private func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try atomicWrite(data, to: url)
    }

    private func writeText(
        _ text: String,
        to url: URL
    ) throws {
        guard let data = text.data(using: .utf8) else {
            throw ArchiveWriteError(message: "文本无法编码为 UTF-8")
        }
        try atomicWrite(data, to: url)
    }

    private func atomicWrite(
        _ data: Data,
        to url: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: "\(url.lastPathComponent).bak",
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    private func inferredStageStatus(
        for stage: String,
        meeting: MeetingRecord
    ) -> String {
        switch stage {
        case "mergeChunks", "audioExtraction":
            return meeting.status == .recording ? "pending" : "succeeded"
        case "transcription", "diarization", "alignment":
            switch meeting.status {
            case .recording, .recorded:
                return "pending"
            case .processing:
                return "running"
            default:
                return "succeeded"
            }
        case "summary":
            return meeting.summaryMarkdown.isEmpty ? "pending" : "succeeded"
        default:
            return "pending"
        }
    }
}

private struct ProjectManifest: Codable {
    let schemaVersion: Int
    let id: UUID
    let name: String
    let projectDescription: String
    let colorHex: String
    let createdAt: Date
    let updatedAt: Date
}

private struct MeetingManifest: Codable {
    static let stageNames = [
        "mergeChunks",
        "audioExtraction",
        "transcription",
        "diarization",
        "alignment",
        "summary"
    ]

    let schemaVersion: Int
    let id: UUID
    let projectId: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let durationSeconds: Double
    let language: String
    let status: String
    let errorMessage: String?
    let audio: AudioManifest
    let speakerMap: [String: String]
    let processing: [String: StageManifest]
    let summaryGeneration: SummaryGenerationManifest?
}

private struct AudioManifest: Codable {
    let fileName: String
    let codec: String
    let sampleRate: Double
    let channels: Int
    let bitRate: Int?
    let sha256: String?
    let devices: [AudioDeviceManifest]
}

private struct AudioDeviceManifest: Codable {
    let uid: String
    let name: String
    let startedAt: Date
}

private struct StageManifest: Codable {
    let status: String
    let finishedAt: Date?
    let error: String?
}

private struct SummaryGenerationManifest: Codable {
    let transcriptRevision: Int
    let transcriptSha256: String?
    let provider: String
    let model: String
    let promptVersion: Int
    let generatedAt: Date
    let usedRealNames: Bool
}

private struct TranscriptManifest: Codable {
    let schemaVersion: Int
    let revision: Int
    let sourceAsrSha256: String?
    let updatedAt: Date
    let segments: [TranscriptManifestSegment]
}

private struct TranscriptManifestSegment: Codable {
    let id: UUID
    let speakerId: String
    let startTime: Double
    let endTime: Double
    let text: String
    let edited: Bool
}
