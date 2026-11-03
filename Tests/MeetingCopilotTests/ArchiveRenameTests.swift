import Foundation
import SwiftData
import XCTest
@testable import MeetingCopilot

@MainActor
final class ArchiveRenameTests: XCTestCase {
    func testProjectAndMeetingRenameKeepArchiveAndUpdatePaths() throws {
        let schema = Schema([
            Project.self,
            MeetingRecord.self,
            TranscriptSegment.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
        let context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCopilotRename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ArchiveFileManager(rootURL: root)
        let project = Project(name: "旧项目")
        context.insert(project)
        project.folderPath = try manager.createProjectDirectory(
            for: project
        ).path

        let meeting = MeetingRecord(title: "旧会议")
        context.insert(meeting)
        project.meetings.append(meeting)
        meeting.folderPath = try manager.createMeetingDirectory(
            for: meeting,
            in: project
        ).path
        try manager.writeProjectManifest(project)
        try manager.writeMeetingManifest(meeting, project: project)
        try context.save()

        try manager.renameProject(
            project,
            to: "新项目",
            context: context
        )
        try manager.renameMeeting(
            meeting,
            in: project,
            to: "新会议",
            context: context
        )

        XCTAssertEqual(project.name, "新项目")
        XCTAssertEqual(meeting.title, "新会议")
        XCTAssertTrue(
            URL(fileURLWithPath: project.folderPath).lastPathComponent
                .contains("新项目")
        )
        XCTAssertTrue(
            URL(fileURLWithPath: meeting.folderPath).lastPathComponent
                .contains("新会议")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: meeting.folderPath
            )
        )
    }
}
