import Foundation

enum MeetingTextExportKind {
    case transcript
    case minutes

    var defaultSuffix: String {
        switch self {
        case .transcript: "逐字稿"
        case .minutes: "会议纪要"
        }
    }
}

enum MeetingTextExportService {
    static func content(
        for meeting: MeetingRecord,
        project: Project,
        kind: MeetingTextExportKind
    ) -> String {
        switch kind {
        case .transcript:
            return transcript(meeting: meeting, project: project)
        case .minutes:
            return minutes(meeting: meeting, project: project)
        }
    }

    static func suggestedFileName(
        for meeting: MeetingRecord,
        kind: MeetingTextExportKind
    ) -> String {
        let date = meeting.date.formatted(
            .dateTime.year().month().day()
        )
        return "\(sanitized(meeting.title))_\(date)_\(kind.defaultSuffix).txt"
    }

    private static func transcript(
        meeting: MeetingRecord,
        project: Project
    ) -> String {
        let body = meeting.sortedSegments.map { segment in
            "[\(formatDuration(segment.startTime))] "
                + "\(speakerName(segment.speakerId, meeting: meeting))："
                + segment.text
        }
        .joined(separator: "\n\n")

        return """
        会议逐字稿
        项目：\(project.name)
        会议：\(meeting.title)
        时间：\(meeting.date.formatted(date: .long, time: .shortened))
        时长：\(formatDuration(meeting.durationSeconds))
        参会人：\(participantSummary(meeting))
        导出时间：\(Date().formatted(date: .long, time: .shortened))

        ========================================

        \(body.isEmpty ? "暂无逐字稿内容。" : body)
        """
    }

    private static func minutes(
        meeting: MeetingRecord,
        project: Project
    ) -> String {
        let index = meeting.sortedSegments.map { segment in
            "[\(formatDuration(segment.startTime))] "
                + "\(speakerName(segment.speakerId, meeting: meeting))："
                + segment.text
        }
        .joined(separator: "\n")

        return """
        会议纪要
        项目：\(project.name)
        会议：\(meeting.title)
        时间：\(meeting.date.formatted(date: .long, time: .shortened))
        时长：\(formatDuration(meeting.durationSeconds))
        参会人：\(participantSummary(meeting))
        导出时间：\(Date().formatted(date: .long, time: .shortened))

        ========================================

        \(meeting.summaryMarkdown.isEmpty ? "暂无会议纪要。" : meeting.summaryMarkdown)

        ========================================
        逐字稿时间索引

        \(index.isEmpty ? "暂无逐字稿内容。" : index)
        """
    }

    private static func participantSummary(_ meeting: MeetingRecord) -> String {
        var seen = Set<String>()
        let labels = meeting.sortedSegments.compactMap {
            (segment: TranscriptSegment) -> String? in
            guard seen.insert(segment.speakerId).inserted else {
                return nil
            }
            return speakerName(segment.speakerId, meeting: meeting)
        }
        return labels.isEmpty ? "未识别" : labels.joined(separator: "、")
    }

    private static func speakerName(
        _ speakerID: String,
        meeting: MeetingRecord
    ) -> String {
        let mapped = meeting.speakerName(for: speakerID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !mapped.isEmpty {
            return mapped
        }
        let index = allSpeakerIDs(meeting).firstIndex(of: speakerID) ?? 0
        return "待确认发言人 \(index + 1)（\(speakerID)）"
    }

    private static func allSpeakerIDs(_ meeting: MeetingRecord) -> [String] {
        var seen = Set<String>()
        return meeting.sortedSegments.compactMap {
            (segment: TranscriptSegment) -> String? in
            seen.insert(segment.speakerId).inserted
                ? segment.speakerId
                : nil
        }
    }

    private static func sanitized(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let result = value.components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "未命名会议" : String(result.prefix(80))
    }
}
