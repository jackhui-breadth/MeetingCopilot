import SwiftData
import XCTest
@testable import MeetingCopilot

@MainActor
final class ProcessingRecoveryTests: XCTestCase {
    func testInterruptedMeetingWithoutTranscriptReturnsToRecorded() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let project = Project(name: "测试项目")
        let meeting = MeetingRecord(title: "测试会议")
        meeting.status = .processing
        context.insert(project)
        context.insert(meeting)
        project.meetings.append(meeting)
        try context.save()

        ProcessingCoordinator().recoverInterruptedMeetings(
            context: context
        )

        XCTAssertEqual(meeting.status, .recorded)
        XCTAssertTrue(meeting.errorMessage?.contains("中断") == true)
    }

    func testInterruptedMeetingWithTranscriptReturnsToSpeakerReview() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let project = Project(name: "测试项目")
        let meeting = MeetingRecord(title: "测试会议")
        meeting.status = .processing
        let segment = TranscriptSegment(
            speakerId: "SPEAKER_00",
            startTime: 0,
            endTime: 2,
            text: "已生成的逐字稿"
        )
        context.insert(project)
        context.insert(meeting)
        context.insert(segment)
        project.meetings.append(meeting)
        meeting.segments.append(segment)
        try context.save()

        ProcessingCoordinator().recoverInterruptedMeetings(
            context: context
        )

        XCTAssertEqual(meeting.status, .awaitingSpeakerReview)
        XCTAssertEqual(meeting.segments.count, 1)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Project.self,
            MeetingRecord.self,
            TranscriptSegment.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
    }
}
