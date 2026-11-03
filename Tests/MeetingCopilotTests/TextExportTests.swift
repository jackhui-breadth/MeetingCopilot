import SwiftData
import XCTest
@testable import MeetingCopilot

@MainActor
final class TextExportTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([
            Project.self,
            MeetingRecord.self,
            TranscriptSegment.self
        ])
        container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
        context = ModelContext(container)
    }

    func testTranscriptExportIncludesTimestampAndResolvedName() {
        let project = Project(name: "产品研发")
        let meeting = MeetingRecord(title: "交付周会")
        context.insert(project)
        context.insert(meeting)
        meeting.setSpeakerName("王工", for: "SPEAKER_00")
        project.meetings.append(meeting)
        let segment = TranscriptSegment(
            speakerId: "SPEAKER_00",
            startTime: 83,
            endTime: 91,
            text: "材料周五到场。"
        )
        context.insert(segment)
        meeting.segments.append(segment)

        let content = MeetingTextExportService.content(
            for: meeting,
            project: project,
            kind: .transcript
        )

        XCTAssertTrue(content.contains("参会人：王工"))
        XCTAssertTrue(content.contains("[01:23] 王工：材料周五到场。"))
    }

    func testMinutesExportAddsTranscriptTimestampIndex() {
        let project = Project(name: "产品研发")
        let meeting = MeetingRecord(title: "交付周会")
        context.insert(project)
        context.insert(meeting)
        meeting.summaryMarkdown = "## 关键决议\n- 周五前完成材料确认。"
        project.meetings.append(meeting)
        let segment = TranscriptSegment(
            speakerId: "SPEAKER_00",
            startTime: 5,
            endTime: 8,
            text: "周五前完成材料确认。"
        )
        context.insert(segment)
        meeting.segments.append(segment)

        let content = MeetingTextExportService.content(
            for: meeting,
            project: project,
            kind: .minutes
        )

        XCTAssertTrue(content.contains("会议纪要"))
        XCTAssertTrue(content.contains("逐字稿时间索引"))
        XCTAssertTrue(content.contains("[00:05] 待确认发言人 1（SPEAKER_00）"))
    }
}
