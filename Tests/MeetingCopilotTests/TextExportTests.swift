import XCTest
@testable import MeetingCopilot

final class TextExportTests: XCTestCase {
    func testTranscriptExportIncludesTimestampAndResolvedName() {
        let project = Project(name: "产品研发")
        let meeting = MeetingRecord(title: "交付周会")
        meeting.setSpeakerName("王工", for: "SPEAKER_00")
        meeting.segments = [
            TranscriptSegment(
                speakerId: "SPEAKER_00",
                startTime: 83,
                endTime: 91,
                text: "材料周五到场。"
            )
        ]

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
        meeting.summaryMarkdown = "## 关键决议\n- 周五前完成材料确认。"
        meeting.segments = [
            TranscriptSegment(
                speakerId: "SPEAKER_00",
                startTime: 5,
                endTime: 8,
                text: "周五前完成材料确认。"
            )
        ]

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
