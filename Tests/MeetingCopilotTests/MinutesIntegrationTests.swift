import XCTest
@testable import MeetingCopilot

@MainActor
final class MinutesIntegrationTests: XCTestCase {
    func testLocalOllamaGeneratesStructuredMinutes() async throws {
        guard ProcessInfo.processInfo.environment["RUN_OLLAMA_TESTS"] == "1"
        else {
            throw XCTSkip("Set RUN_OLLAMA_TESTS=1 to run the local model test")
        }

        UserDefaults.standard.set(
            "http://127.0.0.1:11434/api/generate",
            forKey: "minutesEndpoint"
        )
        UserDefaults.standard.set("qwen3.5:9b", forKey: "minutesModel")

        let meeting = MeetingRecord(title: "交付周会")
        meeting.setSpeakerName("王工", for: "SPEAKER_00")
        meeting.setSpeakerName("李工", for: "SPEAKER_01")
        meeting.segments = [
            TranscriptSegment(
                speakerId: "SPEAKER_00",
                startTime: 12,
                endTime: 18,
                text: "关键材料周三前确认到场时间。"
            ),
            TranscriptSegment(
                speakerId: "SPEAKER_01",
                startTime: 35,
                endTime: 42,
                text: "周五前整理安装计划并发给现场。"
            ),
            TranscriptSegment(
                speakerId: "SPEAKER_00",
                startTime: 52,
                endTime: 57,
                text: "确认这两项，今天开始执行。"
            )
        ]

        let result = try await MinutesGenerator().generate(for: meeting)
        XCTAssertTrue(result.contains("关键决议"))
        XCTAssertTrue(result.contains("待办"))
        XCTAssertTrue(result.contains("[00:12]"))
        XCTAssertTrue(result.contains("王工"))
    }
}
