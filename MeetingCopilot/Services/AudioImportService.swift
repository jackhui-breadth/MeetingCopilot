import AVFoundation
import Foundation
import SwiftData

enum AudioImportError: LocalizedError {
    case conversionFailed

    var errorDescription: String? {
        "无法从该文件提取音频。请确认文件未损坏且包含音轨。"
    }
}

@MainActor
enum AudioImportService {
    static func importAudio(
        from sourceURL: URL,
        into project: Project,
        context: ModelContext
    ) async throws -> MeetingRecord {
        let rawTitle = sourceURL
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = MeetingRecord(
            title: rawTitle.isEmpty ? "导入录音" : rawTitle,
            date: Date()
        )
        meeting.status = .recorded
        let directory = try ArchiveFileManager.shared.createMeetingDirectory(
            for: meeting,
            in: project
        )
        meeting.folderPath = directory.path

        let destination = directory.appendingPathComponent("audio.m4a")
        let converted = await convertToM4A(
            source: sourceURL,
            destination: destination
        )
        if !converted {
            try? FileManager.default.removeItem(at: directory)
            throw AudioImportError.conversionFailed
        }
        meeting.audioFileName = destination.lastPathComponent

        if let audioURL = meeting.audioURL {
            let asset = AVURLAsset(url: audioURL)
            if let duration = try? await asset.load(.duration) {
                meeting.durationSeconds = max(
                    duration.seconds.isFinite ? duration.seconds : 0,
                    0
                )
            }
        }

        context.insert(meeting)
        project.meetings.append(meeting)
        project.updatedAt = Date()
        try context.save()
        try ArchiveFileManager.shared.writeProjectManifest(project)
        try ArchiveFileManager.shared.writeMeetingManifest(
            meeting,
            project: project
        )
        return meeting
    }

    private static func convertToM4A(
        source: URL,
        destination: URL
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: "/opt/homebrew/bin/ffmpeg"
            )
            process.arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", source.path,
                "-vn",
                "-ac", "1",
                "-ar", "48000",
                "-c:a", "aac",
                "-b:a", "96k",
                destination.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
                    && FileManager.default.fileExists(
                        atPath: destination.path
                    )
            } catch {
                return false
            }
        }.value
    }
}
