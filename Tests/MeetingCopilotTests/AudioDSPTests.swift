import AVFoundation
import XCTest
@testable import MeetingCopilot

final class AudioDSPTests: XCTestCase {
    func testAutomaticGainComfortablyLiftsQuietSpeech() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1
            )
        )
        let processor = RealtimeVoiceProcessor(
            channelCount: 1,
            autoGainEnabled: true
        )
        var reportedGain = 0.0

        for _ in 0..<16 {
            let buffer = try makeToneBuffer(
                format: format,
                amplitude: 0.015,
                frequency: 220
            )
            reportedGain = processor.process(buffer, sampleRate: 48_000).gainDB
        }

        XCTAssertGreaterThan(reportedGain, 3)
    }

    func testLimiterPreventsOutputClipping() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1
            )
        )
        let processor = RealtimeVoiceProcessor(
            channelCount: 1,
            autoGainEnabled: true
        )

        let quiet = try makeToneBuffer(
            format: format,
            amplitude: 0.015,
            frequency: 220
        )
        for _ in 0..<16 {
            _ = processor.process(quiet, sampleRate: 48_000)
        }

        let loud = try makeToneBuffer(
            format: format,
            amplitude: 1.8,
            frequency: 440
        )
        let output = processor.process(loud, sampleRate: 48_000)
        let samples = try XCTUnwrap(loud.floatChannelData?[0])
        let peak = (0..<Int(loud.frameLength))
            .map { abs(samples[$0]) }
            .max() ?? 0

        XCTAssertTrue(output.level.isFinite)
        XCTAssertLessThan(peak, 0.98)
    }

    private func makeToneBuffer(
        format: AVAudioFormat,
        amplitude: Float,
        frequency: Double
    ) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(format.sampleRate / 2)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        )
        buffer.frameLength = frameCount
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            channel[index] = amplitude * sin(
                Float(2 * Double.pi * frequency * Double(index) / format.sampleRate)
            )
        }
        return buffer
    }
}
