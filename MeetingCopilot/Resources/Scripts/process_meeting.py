#!/usr/bin/env python3
"""Local transcription pipeline for MeetingCopilot.

Swift owns the authoritative meeting archive. This process writes only to the
staging directory supplied on the command line and reports events as JSON Lines
on stdout.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import traceback
import uuid
from typing import Any, Iterable


DEFAULT_DIARIZATION_MODEL = "pyannote/speaker-diarization-3.1"
DEFAULT_FUNASR_MODEL = "FunAudioLLM/Fun-ASR-Nano-2512"
DEFAULT_SENSEVOICE_MODEL = "iic/SenseVoiceSmall"
DEFAULT_FUNASR_VAD_MODEL = "fsmn-vad"


class PipelineError(Exception):
    def __init__(
        self,
        message: str,
        *,
        stage: str = "transcription",
        code: str = "PROCESSING_FAILED",
        recoverable: bool = True,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.stage = stage
        self.code = code
        self.recoverable = recoverable


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


def emit_progress(
    stage: str,
    message: str,
    fraction: float | None = None,
) -> None:
    event: dict[str, Any] = {
        "type": "progress",
        "stage": stage,
        "indeterminate": fraction is None,
        "message": message,
    }
    if fraction is not None:
        event["fraction"] = max(0.0, min(float(fraction), 1.0))
    emit(event)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except Exception:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary_name)
        raise


def json_safe(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool, int, float)):
        return value
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    if hasattr(value, "tolist"):
        return json_safe(value.tolist())
    return str(value)


def extract_audio(
    ffmpeg_path: str,
    source: Path,
    destination: Path,
) -> None:
    if not Path(ffmpeg_path).is_file():
        raise PipelineError(
            "找不到 FFmpeg，无法准备转写音频。",
            stage="audioExtraction",
            code="FFMPEG_MISSING",
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    command = [
        ffmpeg_path,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
        "-vn",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        str(destination),
    ]
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=3_600,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise PipelineError(
            "音频准备超时。",
            stage="audioExtraction",
            code="AUDIO_EXTRACTION_TIMEOUT",
        ) from error

    if result.returncode != 0:
        detail = (result.stderr or "").strip()
        raise PipelineError(
            f"FFmpeg 无法读取会议录音。{detail[-1_000:]}".strip(),
            stage="audioExtraction",
            code="AUDIO_EXTRACTION_FAILED",
        )
    if not destination.exists() or destination.stat().st_size == 0:
        raise PipelineError(
            "音频准备完成，但没有生成有效文件。",
            stage="audioExtraction",
            code="EMPTY_AUDIO",
        )


def load_mlx_whisper() -> Any:
    try:
        with contextlib.redirect_stdout(sys.stderr):
            import mlx_whisper
    except ImportError as error:
        raise PipelineError(
            "本机尚未安装 MLX Whisper。请在项目目录运行 "
            "./scripts/setup-transcription.sh 后重试。",
            stage="transcription",
            code="MLX_WHISPER_MISSING",
        ) from error
    return mlx_whisper


def transcribe_audio(
    mlx_whisper: Any,
    audio_path: Path,
    language: str,
    model: str,
) -> dict[str, Any]:
    emit_progress(
        "transcription",
        "正在加载 Whisper 模型并识别语音。首次使用可能需要下载模型。",
    )
    language_value = None if language == "auto" else language
    try:
        with contextlib.redirect_stdout(sys.stderr):
            result = mlx_whisper.transcribe(
                str(audio_path),
                path_or_hf_repo=model,
                language=language_value,
                task="transcribe",
                word_timestamps=True,
                condition_on_previous_text=False,
                verbose=False,
            )
    except Exception as error:
        raise PipelineError(
            f"Whisper 转写失败：{error}",
            stage="transcription",
            code="TRANSCRIPTION_FAILED",
        ) from error

    if not isinstance(result, dict):
        raise PipelineError(
            "Whisper 返回了无法识别的结果格式。",
            stage="transcription",
            code="INVALID_WHISPER_RESULT",
        )
    return result


def safe_float(value: Any, fallback: float = 0.0) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return fallback
    return result if result == result else fallback


def clean_model_text(text: Any) -> str:
    value = str(text or "")
    while "<|" in value and "|>" in value:
        start = value.find("<|")
        end = value.find("|>", start)
        if end < 0:
            break
        value = value[:start] + value[end + 2 :]
    return value.strip()


@contextlib.contextmanager
def time_limit(seconds: int):
    def timeout_handler(_signum, _frame):
        raise TimeoutError(f"操作超过 {seconds} 秒")

    previous_handler = signal.signal(signal.SIGALRM, timeout_handler)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)


def split_vad_spans(
    spans: list[tuple[float, float]],
    max_duration_ms: float = 12_000,
) -> list[tuple[float, float]]:
    result: list[tuple[float, float]] = []
    for start, end in spans:
        cursor = start
        while cursor < end:
            chunk_end = min(end, cursor + max_duration_ms)
            if chunk_end - cursor >= 150:
                result.append((cursor, chunk_end))
            cursor = chunk_end
    return result


def join_segment_text(left: str, right: str) -> str:
    left = left.rstrip()
    right = right.lstrip()
    if (
        left
        and right
        and left[-1].isascii()
        and right[0].isascii()
        and (left[-1].isalnum() or left[-1] in ".!?")
    ):
        return f"{left} {right}"
    return left + right


def assign_local_speakers(
    audio_path: Path,
    segments: list[dict[str, Any]],
    expected_speaker_count: int = 0,
) -> tuple[list[dict[str, Any]], int, str | None]:
    if expected_speaker_count == 1:
        for segment in segments:
            segment["speakerId"] = "SPEAKER_00"
        return segments, 1, None
    if len(segments) <= 1:
        for segment in segments:
            segment["speakerId"] = "SPEAKER_00"
        return segments, 1, None

    try:
        import numpy as np
        import soundfile as sf
        import torch
        from funasr import AutoModel
        from sklearn.cluster import AgglomerativeClustering
    except ImportError as error:
        return (
            segments,
            1,
            f"本地说话人模型不可用，已保留单说话人：{error}",
        )

    emit_progress("diarization", "正在提取本地声纹并区分发言人。")
    try:
        speaker_device = (
            "mps"
            if torch.backends.mps.is_available()
            else "cpu"
        )
        with contextlib.redirect_stdout(sys.stderr):
            speaker_model = AutoModel(
                model="cam++",
                hub="ms",
                device=speaker_device,
                disable_update=True,
                check_latest=False,
            )

        samples, sample_rate = sf.read(
            str(audio_path),
            dtype="float32",
            always_2d=False,
        )
        if getattr(samples, "ndim", 1) > 1:
            samples = samples.mean(axis=1)

        window_chunks = []
        window_owners: list[int] = []
        window_samples = max(1, int(sample_rate * 1.5))
        minimum_samples = int(sample_rate * 0.4)
        for index, segment in enumerate(segments):
            start = max(0, int(segment["startTime"] * sample_rate))
            end = min(len(samples), int(segment["endTime"] * sample_rate))
            if end - start < minimum_samples:
                continue
            cursor = start
            while cursor < end:
                window_end = min(end, cursor + window_samples)
                if window_end - cursor >= int(sample_rate * 0.25):
                    window_chunks.append(samples[cursor:window_end])
                    window_owners.append(index)
                cursor = window_end

        valid_indexes = sorted(set(window_owners))
        if len(valid_indexes) < 2:
            for segment in segments:
                segment["speakerId"] = "SPEAKER_00"
            return segments, 1, None

        emit_progress(
            "diarization",
            f"正在批量提取 {len(window_chunks)} 个声纹窗口。",
            0.94,
        )
        with contextlib.redirect_stdout(sys.stderr):
            with time_limit(120):
                result = speaker_model.generate(
                    input=window_chunks,
                    batch_size=min(256, len(window_chunks)),
                )
        if not result:
            raise RuntimeError("声纹模型没有返回嵌入向量")
        embedding_batches = []
        for batch in result:
            if "spk_embedding" not in batch:
                continue
            batch_matrix = (
                batch["spk_embedding"]
                .detach()
                .cpu()
                .numpy()
            )
            if batch_matrix.ndim == 1:
                batch_matrix = batch_matrix.reshape(1, -1)
            embedding_batches.append(batch_matrix[:, :192])
        if not embedding_batches:
            raise RuntimeError("声纹模型没有返回有效嵌入向量")
        matrix = np.concatenate(embedding_batches, axis=0)
        if matrix.shape[0] != len(window_chunks):
            raise RuntimeError(
                "声纹批量结果数量不匹配："
                f"{matrix.shape[0]} != {len(window_chunks)}"
            )
        segment_embeddings = []
        durations = []
        for segment_index in valid_indexes:
            rows = [
                row
                for row, owner in enumerate(window_owners)
                if owner == segment_index
            ]
            segment_embeddings.append(matrix[rows].mean(axis=0))
            segment = segments[segment_index]
            durations.append(
                float(segment["endTime"] - segment["startTime"])
            )
        matrix = np.stack(segment_embeddings)
        anchor_positions = [
            index
            for index, duration in enumerate(durations)
            if duration >= 1.5
        ]
        if len(anchor_positions) < 2:
            anchor_positions = list(range(len(embeddings)))
        anchor_matrix = matrix[anchor_positions]
        if expected_speaker_count >= 2:
            requested = min(
                expected_speaker_count,
                anchor_matrix.shape[0],
            )
            labels = AgglomerativeClustering(
                n_clusters=requested,
                metric="cosine",
                linkage="average",
            ).fit_predict(anchor_matrix)
        else:
            labels = AgglomerativeClustering(
                n_clusters=None,
                distance_threshold=0.37,
                metric="cosine",
                linkage="average",
            ).fit_predict(anchor_matrix)
        speaker_count = len(set(labels.tolist()))
        if speaker_count > 6:
            labels = AgglomerativeClustering(
                n_clusters=6,
                metric="cosine",
                linkage="average",
            ).fit_predict(anchor_matrix)
            speaker_count = 6

        first_seen: list[int] = []
        for value in labels.tolist():
            if value not in first_seen:
                first_seen.append(value)
        label_map = {
            raw: f"SPEAKER_{index:02d}"
            for index, raw in enumerate(first_seen)
        }
        centroids = np.stack([
            anchor_matrix[labels == raw_label].mean(axis=0)
            for raw_label in first_seen
        ])
        centroid_norms = np.linalg.norm(
            centroids,
            axis=1,
            keepdims=True,
        )
        normalized_centroids = centroids / np.maximum(
            centroid_norms,
            1e-8,
        )
        normalized_matrix = matrix / np.maximum(
            np.linalg.norm(matrix, axis=1, keepdims=True),
            1e-8,
        )
        similarities = normalized_matrix @ normalized_centroids.T
        for row, segment_index in enumerate(valid_indexes):
            raw_label = first_seen[int(np.argmax(similarities[row]))]
            segments[segment_index]["speakerId"] = label_map[raw_label]

        # Very short grunts usually inherit the surrounding speaker.
        for index, segment in enumerate(segments):
            if index in valid_indexes:
                continue
            previous = segments[index - 1] if index > 0 else None
            following = (
                segments[index + 1]
                if index + 1 < len(segments)
                else None
            )
            if previous and segment["startTime"] - previous["endTime"] <= 1.5:
                segment["speakerId"] = previous["speakerId"]
            elif following:
                segment["speakerId"] = following["speakerId"]
            else:
                segment["speakerId"] = "SPEAKER_00"

        return segments, speaker_count, None
    except Exception as error:
        for segment in segments:
            segment["speakerId"] = "SPEAKER_00"
        return (
            segments,
            1,
            f"本地说话人分离失败，已降级为单说话人：{error}",
        )


def merge_same_speaker_segments(
    segments: list[dict[str, Any]],
    max_gap_seconds: float = 3.0,
    max_duration_seconds: float = 45.0,
    max_characters: int = 480,
) -> list[dict[str, Any]]:
    merged: list[dict[str, Any]] = []
    for segment in sorted(segments, key=lambda item: item["startTime"]):
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        segment["text"] = text
        if merged:
            previous = merged[-1]
            combined_duration = (
                segment["endTime"] - previous["startTime"]
            )
            combined_text = join_segment_text(
                previous["text"],
                text,
            )
            can_merge = (
                previous["speakerId"] == segment["speakerId"]
                and segment["startTime"] - previous["endTime"]
                <= max_gap_seconds
                and combined_duration <= max_duration_seconds
                and len(combined_text) <= max_characters
            )
            if can_merge:
                previous["endTime"] = max(
                    previous["endTime"],
                    segment["endTime"],
                )
                previous["text"] = combined_text
                continue
        merged.append(dict(segment))
    return merged


def transcribe_with_funasr_nano(
    audio_path: Path,
    output_dir: Path,
    language: str,
    model_name: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
    try:
        import soundfile as sf
        from funasr import AutoModel
    except ImportError as error:
        raise PipelineError(
            "中文识别引擎尚未安装。请在项目目录运行 "
            "./scripts/setup-transcription.sh 后重试。",
            stage="transcription",
            code="FUNASR_MISSING",
        ) from error

    emit_progress(
        "transcription",
        "正在加载 Fun-ASR Nano 中文模型。首次使用可能需要下载约 4 GB 模型。",
    )
    try:
        import torch
        transcription_device = (
            "mps"
            if torch.backends.mps.is_available()
            else "cpu"
        )
        with contextlib.redirect_stdout(sys.stderr):
            vad_model = AutoModel(
                model=DEFAULT_FUNASR_VAD_MODEL,
                hub="hf",
                device="cpu",
                disable_update=True,
            )
            vad_result = vad_model.generate(
                input=str(audio_path),
                batch_size=1,
                max_single_segment_time=30_000,
                max_end_silence_time=600,
            )

        spans = split_vad_spans([
            (float(start), float(end))
            for start, end in (vad_result[0].get("value") or [])
            if float(end) > float(start)
        ])
        if not spans:
            return [], {
                "engine": "funasr-nano",
                "model": model_name,
                "language": language,
                "vad": {"spans": [], "results": []},
            }

        emit_progress(
            "transcription",
            f"检测到 {len(spans)} 个说话区间，正在逐段识别。",
            0.15,
        )
        with contextlib.redirect_stdout(sys.stderr):
            model = AutoModel(
                model=model_name,
                hub="hf",
                device=transcription_device,
                disable_update=True,
            )

        samples, sample_rate = sf.read(
            str(audio_path),
            dtype="float32",
            always_2d=False,
        )
        if getattr(samples, "ndim", 1) > 1:
            samples = samples.mean(axis=1)

        segments: list[dict[str, Any]] = []
        chunk_results: list[dict[str, Any]] = []
        with tempfile.TemporaryDirectory(
            prefix=".funasr-",
            dir=output_dir,
        ) as chunks_dir:
            for index, (start_ms, end_ms) in enumerate(spans):
                start_sample = max(0, int(start_ms * sample_rate / 1_000))
                end_sample = min(
                    len(samples),
                    int(end_ms * sample_rate / 1_000),
                )
                if end_sample <= start_sample:
                    continue

                chunk_path = Path(chunks_dir) / f"speech-{index:05d}.wav"
                sf.write(
                    str(chunk_path),
                    samples[start_sample:end_sample],
                    sample_rate,
                    subtype="PCM_16",
                )
                try:
                    with contextlib.redirect_stdout(sys.stderr):
                        result = model.generate(
                            input=str(chunk_path),
                            batch_size=1,
                            language=language,
                        )
                except Exception as error:
                    raise PipelineError(
                        f"Fun-ASR Nano 识别失败：{error}",
                        stage="transcription",
                        code="FUNASR_INFERENCE_FAILED",
                    ) from error

                text = clean_model_text(
                    result[0].get("text") if result else ""
                )
                chunk_results.append(
                    {
                        "start": round(start_ms / 1_000, 3),
                        "end": round(end_ms / 1_000, 3),
                        "text": text,
                        "raw": json_safe(result),
                    }
                )
                if text:
                    segments.append(
                        {
                            "id": str(uuid.uuid4()).upper(),
                            "speakerId": "SPEAKER_00",
                            "startTime": round(start_ms / 1_000, 3),
                            "endTime": round(end_ms / 1_000, 3),
                            "text": text,
                            "edited": False,
                        }
                    )

                fraction = 0.15 + 0.75 * ((index + 1) / len(spans))
                emit_progress(
                    "transcription",
                    f"已识别 {index + 1}/{len(spans)} 个说话区间。",
                    fraction,
                )

        raw_result = {
            "engine": "funasr-nano",
            "model": model_name,
            "language": language,
            "vad": {
                "model": DEFAULT_FUNASR_VAD_MODEL,
                "spans": [
                    {
                        "start": round(start / 1_000, 3),
                        "end": round(end / 1_000, 3),
                    }
                    for start, end in spans
                ],
                "results": chunk_results,
            },
        }
        return segments, raw_result
    except PipelineError:
        raise
    except Exception as error:
        raise PipelineError(
            f"Fun-ASR Nano 模型加载或推理失败：{error}",
            stage="transcription",
            code="FUNASR_FAILED",
        ) from error


def transcribe_with_sensevoice(
    audio_path: Path,
    output_dir: Path,
    language: str,
    model_name: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    try:
        import soundfile as sf
        from funasr import AutoModel
    except ImportError as error:
        raise PipelineError(
            "快速中文识别引擎尚未安装。请在项目目录运行 "
            "./scripts/setup-transcription.sh 后重试。",
            stage="transcription",
            code="SENSEVOICE_MISSING",
        ) from error

    emit_progress(
        "transcription",
        "正在加载 SenseVoice 中文快速识别模型。",
    )
    try:
        with contextlib.redirect_stdout(sys.stderr):
            vad_model = AutoModel(
                model=DEFAULT_FUNASR_VAD_MODEL,
                hub="ms",
                device="cpu",
                disable_update=True,
                check_latest=False,
            )
            vad_result = vad_model.generate(
                input=str(audio_path),
                batch_size=1,
                max_single_segment_time=30_000,
                max_end_silence_time=600,
            )

        spans = split_vad_spans([
            (float(start), float(end))
            for start, end in (vad_result[0].get("value") or [])
            if float(end) > float(start)
        ])
        if not spans:
            return [], {
                "engine": "sensevoice",
                "model": model_name,
                "language": language,
                "vad": {"spans": [], "results": []},
            }

        emit_progress(
            "transcription",
            f"检测到 {len(spans)} 个说话区间，正在快速识别。",
            0.15,
        )
        with contextlib.redirect_stdout(sys.stderr):
            model = AutoModel(
                model=model_name,
                hub="ms",
                device="cpu",
                disable_update=True,
                check_latest=False,
            )

        samples, sample_rate = sf.read(
            str(audio_path),
            dtype="float32",
            always_2d=False,
        )
        if getattr(samples, "ndim", 1) > 1:
            samples = samples.mean(axis=1)

        segments: list[dict[str, Any]] = []
        chunk_results: list[dict[str, Any]] = []
        with tempfile.TemporaryDirectory(
            prefix=".sensevoice-",
            dir=output_dir,
        ) as chunks_dir:
            for index, (start_ms, end_ms) in enumerate(spans):
                start_sample = max(0, int(start_ms * sample_rate / 1_000))
                end_sample = min(
                    len(samples),
                    int(end_ms * sample_rate / 1_000),
                )
                if end_sample <= start_sample:
                    continue

                chunk_path = Path(chunks_dir) / f"speech-{index:05d}.wav"
                sf.write(
                    str(chunk_path),
                    samples[start_sample:end_sample],
                    sample_rate,
                    subtype="PCM_16",
                )
                with contextlib.redirect_stdout(sys.stderr):
                    result = model.generate(
                        input=str(chunk_path),
                        batch_size=1,
                        language=language,
                    )
                text = clean_model_text(
                    result[0].get("text") if result else ""
                )
                chunk_results.append(
                    {
                        "start": round(start_ms / 1_000, 3),
                        "end": round(end_ms / 1_000, 3),
                        "text": text,
                        "raw": json_safe(result),
                    }
                )
                if text:
                    segments.append(
                        {
                            "id": str(uuid.uuid4()).upper(),
                            "speakerId": "SPEAKER_00",
                            "startTime": round(start_ms / 1_000, 3),
                            "endTime": round(end_ms / 1_000, 3),
                            "text": text,
                            "edited": False,
                        }
                    )

                fraction = 0.15 + 0.75 * ((index + 1) / len(spans))
                emit_progress(
                    "transcription",
                    f"已快速识别 {index + 1}/{len(spans)} 个区间。",
                    fraction,
                )

        return segments, {
            "engine": "sensevoice",
            "model": model_name,
            "language": language,
            "vad": {
                "model": DEFAULT_FUNASR_VAD_MODEL,
                "spans": [
                    {
                        "start": round(start / 1_000, 3),
                        "end": round(end / 1_000, 3),
                    }
                    for start, end in spans
                ],
                "results": chunk_results,
            },
        }
    except PipelineError:
        raise
    except Exception as error:
        raise PipelineError(
            f"SenseVoice 快速识别失败：{error}",
            stage="transcription",
            code="SENSEVOICE_FAILED",
        ) from error


def assign_segment_speakers(
    segments: list[dict[str, Any]],
    turns: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    if not turns:
        return segments
    for segment in segments:
        speaker = speaker_for_span(
            turns,
            segment["startTime"],
            segment["endTime"],
        )
        if speaker:
            segment["speakerId"] = speaker
    return segments


def load_diarization_turns(
    audio_path: Path,
    model: str,
) -> tuple[list[dict[str, Any]], str | None]:
    token = os.environ.get("MEETINGCOPILOT_HF_TOKEN", "").strip()
    if not token:
        return [], None

    emit_progress("diarization", "正在区分会议中的不同发言人。")
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from pyannote.audio import Pipeline

            pipeline = Pipeline.from_pretrained(model, use_auth_token=token)
            if pipeline is None:
                raise RuntimeError("HuggingFace 模型载入失败")
            try:
                import torch

                if torch.backends.mps.is_available():
                    pipeline.to(torch.device("mps"))
            except Exception:
                pass
            annotation = pipeline(str(audio_path))

        raw_turns = [
            {
                "start": safe_float(turn.start),
                "end": safe_float(turn.end),
                "speaker": str(speaker),
            }
            for turn, _, speaker in annotation.itertracks(yield_label=True)
        ]
    except Exception as error:
        return [], f"发言人识别不可用，已降级为单说话人：{error}"

    labels = sorted({turn["speaker"] for turn in raw_turns})
    label_map = {
        label: f"SPEAKER_{index:02d}" for index, label in enumerate(labels)
    }
    turns = [
        {
            "start": max(turn["start"], 0.0),
            "end": max(turn["end"], turn["start"]),
            "speakerId": label_map[turn["speaker"]],
        }
        for turn in raw_turns
        if turn["end"] > turn["start"]
    ]
    return turns, None


def join_words(words: Iterable[str]) -> str:
    result = ""
    for raw_word in words:
        word = raw_word.strip()
        if not word:
            continue
        if result and result[-1].isascii() and word[0].isascii():
            result += " "
        result += word
    return result.strip()


def speaker_for_span(
    turns: list[dict[str, Any]],
    start: float,
    end: float,
) -> str | None:
    best_speaker = None
    best_overlap = 0.0
    for turn in turns:
        overlap = max(0.0, min(end, turn["end"]) - max(start, turn["start"]))
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = turn["speakerId"]
    return best_speaker


def plain_segments(result: dict[str, Any]) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    for raw in result.get("segments", []):
        text = str(raw.get("text", "")).strip()
        if not text:
            continue
        start = max(safe_float(raw.get("start")), 0.0)
        end = max(safe_float(raw.get("end"), start), start)
        segments.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "speakerId": "SPEAKER_00",
                "startTime": round(start, 3),
                "endTime": round(end, 3),
                "text": text,
                "edited": False,
            }
        )
    return segments


def diarized_segments(
    result: dict[str, Any],
    turns: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    words: list[dict[str, Any]] = []
    for raw_segment in result.get("segments", []):
        raw_words = raw_segment.get("words") or []
        if not raw_words:
            text = str(raw_segment.get("text", "")).strip()
            if text:
                raw_words = [
                    {
                        "word": text,
                        "start": raw_segment.get("start"),
                        "end": raw_segment.get("end"),
                    }
                ]
        for raw_word in raw_words:
            word = str(raw_word.get("word", "")).strip()
            if not word:
                continue
            start = max(safe_float(raw_word.get("start")), 0.0)
            end = max(safe_float(raw_word.get("end"), start), start)
            speaker = speaker_for_span(turns, start, end) or "SPEAKER_00"
            words.append(
                {
                    "word": word,
                    "start": start,
                    "end": end,
                    "speaker": speaker,
                }
            )

    words.sort(key=lambda item: (item["start"], item["end"]))
    groups: list[dict[str, Any]] = []
    for word in words:
        can_merge = (
            groups
            and groups[-1]["speakerId"] == word["speaker"]
            and word["start"] - groups[-1]["endTime"] <= 1.5
        )
        if can_merge:
            groups[-1]["endTime"] = max(groups[-1]["endTime"], word["end"])
            groups[-1]["words"].append(word["word"])
        else:
            groups.append(
                {
                    "speakerId": word["speaker"],
                    "startTime": word["start"],
                    "endTime": word["end"],
                    "words": [word["word"]],
                }
            )

    segments: list[dict[str, Any]] = []
    for group in groups:
        text = join_words(group["words"])
        if not text:
            continue
        segments.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "speakerId": group["speakerId"],
                "startTime": round(group["startTime"], 3),
                "endTime": round(group["endTime"], 3),
                "text": text,
                "edited": False,
            }
        )
    return segments


def process(args: argparse.Namespace) -> None:
    source = Path(args.audio).expanduser().resolve()
    output_dir = Path(args.output_stage_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    if not source.is_file():
        raise PipelineError(
            f"找不到会议录音：{source}",
            stage="audioExtraction",
            code="AUDIO_NOT_FOUND",
        )

    emit_progress("audioExtraction", "正在准备 16 kHz 单声道转写音频。", 0.05)
    audio_path = output_dir / "audio_16k.wav"
    extract_audio(args.ffmpeg_path, source, audio_path)
    emit_progress("audioExtraction", "音频准备完成。", 0.1)

    if args.engine == "funasr-nano":
        segments, raw_result = transcribe_with_funasr_nano(
            audio_path,
            output_dir,
            args.language,
            args.funasr_model,
        )
    elif args.engine == "sensevoice":
        segments, raw_result = transcribe_with_sensevoice(
            audio_path,
            output_dir,
            args.language,
            args.sensevoice_model,
        )
    else:
        mlx_whisper = load_mlx_whisper()
        whisper_result = transcribe_audio(
            mlx_whisper,
            audio_path,
            args.language,
            args.whisper_model,
        )
        segments = plain_segments(whisper_result)
        raw_result = {
            "engine": "mlx-whisper",
            "model": args.whisper_model,
            "language": whisper_result.get("language", args.language),
            "whisper": json_safe(whisper_result),
        }

    turns: list[dict[str, Any]] = []
    diarization_warning = None
    speaker_count = 1
    diarization_source = "single_speaker"
    if args.diarization_model:
        turns, diarization_warning = load_diarization_turns(
            audio_path,
            args.diarization_model,
        )

    emit_progress("alignment", "正在对齐文字、时间戳与发言人。", 0.92)
    if turns:
        segments = assign_segment_speakers(segments, turns)
        speaker_count = len({
            turn["speakerId"] for turn in turns
        })
        diarization_source = "pyannote"
    elif args.engine == "whisper":
        (
            segments,
            speaker_count,
            local_warning,
        ) = assign_local_speakers(
            audio_path,
            segments,
            args.speaker_count,
        )
        diarization_warning = local_warning or diarization_warning
        if local_warning is None:
            diarization_source = "cam++"
    else:
        (
            segments,
            speaker_count,
            local_warning,
        ) = assign_local_speakers(
            audio_path,
            segments,
            args.speaker_count,
        )
        diarization_warning = local_warning or diarization_warning
        if local_warning is None:
            diarization_source = "cam++"

    segments = merge_same_speaker_segments(segments)
    segments.sort(key=lambda item: item["startTime"])

    recognized_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    raw_result["schemaVersion"] = 1
    raw_result["recognizedAt"] = recognized_at
    raw_result["diarization"] = {
            "status": (
                "used"
                if speaker_count > 1
                else "single_speaker"
            ),
            "model": (
                args.diarization_model
                if diarization_source == "pyannote"
                else "cam++"
            ),
            "source": diarization_source,
            "speakerCount": speaker_count,
            "warning": diarization_warning,
            "turns": turns,
        }
    raw_path = output_dir / "asr.raw.json"
    atomic_write_json(raw_path, raw_result)

    raw_digest = hashlib.sha256(raw_path.read_bytes()).hexdigest()
    transcript = {
        "schemaVersion": 1,
        "revision": 1,
        "sourceAsrSha256": f"sha256:{raw_digest}",
        "updatedAt": recognized_at,
        "segments": segments,
    }
    transcript_path = output_dir / "transcript.json"
    atomic_write_json(transcript_path, transcript)

    if not segments:
        message = "未识别到可转写的语音内容。录音已安全保留。"
    elif diarization_warning:
        message = diarization_warning
    else:
        message = f"逐字稿已生成，共 {len(segments)} 段。"
    emit(
        {
            "type": "completed",
            "stage": "alignment",
            "message": message,
            "segmentCount": len(segments),
            "artifacts": {
                "transcript": transcript_path.name,
                "rawASR": raw_path.name,
            },
        }
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="MeetingCopilot local transcription")
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output-stage-dir", required=True)
    parser.add_argument(
        "--engine",
        default="funasr-nano",
        choices=("sensevoice", "funasr-nano", "whisper"),
    )
    parser.add_argument("--language", default="zh", choices=("zh", "auto", "en"))
    parser.add_argument("--speaker-count", type=int, default=0)
    parser.add_argument(
        "--whisper-model",
        default="mlx-community/whisper-large-v3-turbo",
    )
    parser.add_argument(
        "--funasr-model",
        default=DEFAULT_FUNASR_MODEL,
    )
    parser.add_argument(
        "--sensevoice-model",
        default=DEFAULT_SENSEVOICE_MODEL,
    )
    parser.add_argument(
        "--diarization-model",
        default=DEFAULT_DIARIZATION_MODEL,
    )
    parser.add_argument(
        "--disable-diarization",
        action="store_true",
        help="Force single-speaker transcription",
    )
    parser.add_argument("--ffmpeg-path", default="/opt/homebrew/bin/ffmpeg")
    return parser.parse_args(argv)


def main() -> int:
    try:
        args = parse_args()
        if args.disable_diarization:
            args.diarization_model = None
        process(args)
        return 0
    except PipelineError as error:
        emit(
            {
                "type": "error",
                "stage": error.stage,
                "code": error.code,
                "message": error.message,
                "recoverable": error.recoverable,
            }
        )
        return 2
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit(
            {
                "type": "error",
                "stage": "transcription",
                "code": "UNEXPECTED_ERROR",
                "message": f"本地转写发生未预期错误：{error}",
                "recoverable": True,
            }
        )
        return 2


if __name__ == "__main__":
    sys.exit(main())
