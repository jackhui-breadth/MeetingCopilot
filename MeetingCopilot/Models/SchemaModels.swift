import Foundation
import SwiftData

enum MeetingStatus: String, Codable, CaseIterable {
    case recording
    case recorded
    case processing
    case awaitingSpeakerReview = "awaiting_speaker_review"
    case readyWithSummary = "ready_with_summary"
    case readyWithoutSummary = "ready_without_summary"
    case needsRecovery = "needs_recovery"

    var title: String {
        switch self {
        case .recording: "录音中"
        case .recorded: "已录音"
        case .processing: "处理中"
        case .awaitingSpeakerReview: "待认领"
        case .readyWithSummary: "已完成"
        case .readyWithoutSummary: "待生成纪要"
        case .needsRecovery: "需要恢复"
        }
    }
}

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var projectDescription: String
    var colorHex: String
    var folderPath: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \MeetingRecord.project)
    var meetings: [MeetingRecord] = []

    init(
        name: String,
        projectDescription: String = "",
        colorHex: String = "#E8674A"
    ) {
        id = UUID()
        self.name = name
        self.projectDescription = projectDescription
        self.colorHex = colorHex
        folderPath = ""
        createdAt = Date()
        updatedAt = Date()
    }

    var sortedMeetings: [MeetingRecord] {
        meetings.sorted { $0.date > $1.date }
    }
}

@Model
final class MeetingRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var date: Date
    var durationSeconds: Double
    var folderPath: String
    var audioFileName: String
    var summaryMarkdown: String
    var statusRaw: String
    var errorMessage: String?
    var speakerMapJSON: String
    var transcriptRevision: Int
    var summaryTranscriptRevision: Int
    var summarySpeakerMapJSON: String
    var summaryGeneratedAt: Date?
    var expectedSpeakerCount: Int?
    var project: Project?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment] = []

    init(
        title: String,
        date: Date = Date(),
        folderPath: String = ""
    ) {
        id = UUID()
        self.title = title
        self.date = date
        durationSeconds = 0
        self.folderPath = folderPath
        audioFileName = "audio.m4a"
        summaryMarkdown = ""
        statusRaw = MeetingStatus.recording.rawValue
        errorMessage = nil
        speakerMapJSON = "{}"
        transcriptRevision = 0
        summaryTranscriptRevision = -1
        summarySpeakerMapJSON = "{}"
        summaryGeneratedAt = nil
        expectedSpeakerCount = nil
    }

    var status: MeetingStatus {
        get { MeetingStatus(rawValue: statusRaw) ?? .recorded }
        set { statusRaw = newValue.rawValue }
    }

    var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.startTime < $1.startTime }
    }

    var audioURL: URL? {
        guard !folderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: folderPath)
            .appendingPathComponent(audioFileName)
    }

    var hasAudio: Bool {
        guard let audioURL else { return false }
        return FileManager.default.fileExists(atPath: audioURL.path)
    }

    var speakerMap: [String: String] {
        guard let data = speakerMapJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return value
    }

    var participantNames: [String] {
        let names = speakerMap.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }

    var isSummaryStale: Bool {
        !summaryMarkdown.isEmpty
            && (summaryTranscriptRevision != transcriptRevision
                || decodedSpeakerMap(summarySpeakerMapJSON) != speakerMap)
    }

    func speakerName(for speakerID: String) -> String {
        speakerMap[speakerID] ?? ""
    }

    func setSpeakerName(_ name: String, for speakerID: String) {
        var mapping = speakerMap
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            mapping.removeValue(forKey: speakerID)
        } else {
            mapping[speakerID] = trimmed
        }

        if let data = try? JSONEncoder().encode(mapping),
           let encoded = String(data: data, encoding: .utf8) {
            speakerMapJSON = encoded
        }
    }

    func markTranscriptEdited() {
        transcriptRevision += 1
        project?.updatedAt = Date()
    }

    private func decodedSpeakerMap(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return value
    }
}

@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    var speakerId: String
    var startTime: Double
    var endTime: Double
    var text: String
    var meeting: MeetingRecord?

    init(
        speakerId: String,
        startTime: Double,
        endTime: Double,
        text: String
    ) {
        id = UUID()
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
