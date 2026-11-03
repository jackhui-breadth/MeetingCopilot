from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import wave


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "MeetingCopilot/Resources/Scripts/process_meeting.py"
FFMPEG = Path("/opt/homebrew/bin/ffmpeg")


@unittest.skipUnless(FFMPEG.is_file(), "FFmpeg is required for this integration test")
class ProcessMeetingTests(unittest.TestCase):
    def test_pipeline_writes_valid_single_speaker_transcript(self) -> None:
        with tempfile.TemporaryDirectory(prefix="meetingcopilot-test-") as temporary:
            root = Path(temporary)
            audio_path = root / "input.wav"
            with wave.open(str(audio_path), "wb") as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16_000)
                audio.writeframes(b"\0\0" * 16_000)

            mock_modules = root / "mock_modules"
            mock_modules.mkdir()
            (mock_modules / "mlx_whisper.py").write_text(
                """
def transcribe(path, **kwargs):
    return {
        "language": "zh",
        "segments": [
            {"start": 0.2, "end": 1.0, "text": "第一段测试内容。"},
            {"start": 1.2, "end": 1.8, "text": "第二段测试内容。"},
        ],
    }
""".strip(),
                encoding="utf-8",
            )
            output = root / "output"
            environment = os.environ.copy()
            environment["PYTHONPATH"] = str(mock_modules)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--audio",
                    str(audio_path),
                    "--output-stage-dir",
                    str(output),
                    "--engine",
                    "whisper",
                    "--language",
                    "zh",
                    "--whisper-model",
                    "test-model",
                    "--ffmpeg-path",
                    str(FFMPEG),
                    "--disable-diarization",
                ],
                capture_output=True,
                text=True,
                env=environment,
                timeout=30,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            events = [
                json.loads(line)
                for line in result.stdout.splitlines()
                if line.strip()
            ]
            self.assertTrue(any(event["type"] == "completed" for event in events))

            transcript = json.loads(
                (output / "transcript.json").read_text(encoding="utf-8")
            )
            self.assertEqual(transcript["schemaVersion"], 1)
            self.assertEqual(transcript["revision"], 1)
            self.assertEqual(len(transcript["segments"]), 1)
            self.assertTrue(
                all(
                    segment["speakerId"] == "SPEAKER_00"
                    for segment in transcript["segments"]
                )
            )
            self.assertEqual(transcript["segments"][0]["startTime"], 0.2)
            self.assertEqual(transcript["segments"][0]["endTime"], 1.8)
            self.assertIn("第一段测试内容", transcript["segments"][0]["text"])
            self.assertIn("第二段测试内容", transcript["segments"][0]["text"])
            self.assertTrue((output / "asr.raw.json").is_file())


if __name__ == "__main__":
    unittest.main()
