import Foundation
import XCTest
@testable import MeetingCopilot

final class ArchiveDeletionTests: XCTestCase {
    func testNestedArchiveCanBeMovedToTrashAndRestored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCopilotDelete-\(UUID().uuidString)")
        let meeting = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(
            at: meeting,
            withIntermediateDirectories: true
        )
        let recording = meeting.appendingPathComponent("audio.m4a")
        try Data("test".utf8).write(to: recording)

        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ArchiveFileManager(rootURL: root)
        let trashedURL = try XCTUnwrap(
            try manager.moveToTrash(meeting)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path))

        try FileManager.default.moveItem(at: trashedURL, to: meeting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
    }

    func testArchiveRefusesDeletionOutsideRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCopilotRoot-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCopilotOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let manager = ArchiveFileManager(rootURL: root)
        XCTAssertThrowsError(try manager.moveToTrash(outside))
    }
}
