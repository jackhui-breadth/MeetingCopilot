# MeetingCopilot

一款面向线下会议的本地优先 macOS 会议工作台：录音、逐字稿、说话人区分、
结构化纪要和行动项都在同一个项目时间线中完成。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](Package.swift)

> 当前是开发者预览版。语音模型不随源码分发，首次使用时需要单独下载。

## 功能

- 原生 SwiftUI 三栏界面：项目、会议时间线和会议详情
- 麦克风录音、暂停/继续、电平、计时和 AAC 转换
- 自动增益、峰值压缩、低切、频谱降噪和软限幅
- Fun-ASR Nano 高精度中文转写，可切换 SenseVoice 快速模式或 MLX Whisper
- 本地 cam++ 说话人聚类，支持指定预计参会人数
- 逐字稿搜索、编辑、播放跟随高亮和发言人认领
- 导入本地音频或视频，自动提取音轨并开始转写
- 本机 Ollama 生成结构化会议纪要，支持长逐字稿分块
- 6 种会议模板：通用会议、周会、需求评审、1 对 1、项目复盘、客户拜访
- 从纪要提取行动项，并同步到 macOS 提醒事项
- 逐字稿和会议纪要导出为带时间戳、参会人姓名的 TXT
- 项目/会议重命名、删除到废纸篓、档案恢复

## 隐私模型

MeetingCopilot 默认本地优先：

- 录音、逐字稿、纪要和索引保存在本机。
- 语音识别、说话人聚类默认在本机运行。
- 不包含遥测、埋点、广告或远程账号系统。
- 纪要默认发送到用户配置的本机 Ollama 接口。
- 如果配置了云端模型端点，必要的会议文本会发送到该端点；请根据组织的合规要求选择服务。
- Token 和 API Key 不写入会议档案或 Git 仓库。

详细说明见 [PRIVACY.md](PRIVACY.md) 和 [SECURITY.md](SECURITY.md)。

## 系统要求

- macOS 14 Sonoma 或更高版本
- Apple Silicon 推荐
- Swift 5.10+
- Python 3.10+
- FFmpeg
- 可选：Ollama，用于生成会议纪要

## 快速开始

```bash
brew install ffmpeg
./scripts/setup-transcription.sh
./scripts/build-app.sh
open dist/MeetingCopilot.app
```

首次录音时 macOS 会请求麦克风权限。使用“行动项 → 提醒事项”时还会请求提醒事项权限。

`setup-transcription.sh` 会在项目目录创建独立的 `.venv`，不会修改系统 Python。
首次转写需要下载模型；模型大小和下载时间取决于所选引擎。

### Python 路径

应用优先使用项目内 `.venv`。也可以显式指定：

```bash
export MEETINGCOPILOT_PYTHON="/path/to/python3"
export MEETINGCOPILOT_FFMPEG="/opt/homebrew/bin/ffmpeg"
```

### Ollama

应用会自动启动本机 Ollama 服务。默认模型为 `qwen3.5:9b`，可在设置中修改接口和模型。

## 使用流程

1. 新建项目。
2. 新建会议并开始录音，或导入已有音视频。
3. 停止录音后等待本地转写完成。
4. 设置“预计参会人数”，重新转写可改善音色相近说话人的聚类。
5. 在“认领参会人”中把 `SPEAKER_00` 等匿名标签改成真实姓名。
6. 选择纪要模板并生成会议纪要。
7. 从纪要同步行动项到提醒事项，或导出 TXT。

## 本地档案

默认目录：

```text
~/Movies/MeetingCopilot/
```

每场会议包含：

```text
audio.m4a
meeting.json
transcript.json
asr.raw.json
minutes.md
revisions/
```

SwiftData 仅作为可重建索引，磁盘档案是权威数据源。

## 构建与测试

```bash
swift test
python3 -m unittest discover -s scripts/tests -v
```

GitHub Actions 会在 macOS runner 上执行 Swift 和 Python 测试。

## 架构

```text
SwiftUI
  ├── Recording + Audio DSP
  ├── SwiftData index
  ├── ArchiveFileManager
  ├── ProcessingCoordinator
  └── Ollama minutes generator
        │
        ▼
Python ASR pipeline
  ├── FFmpeg
  ├── Fun-ASR Nano / SenseVoice / MLX Whisper
  ├── FSMN VAD
  └── cam++ speaker embeddings + clustering
```

## 当前边界

- 目前是录音结束后的批处理，不是飞书妙记式的实时增量字幕。
- 准确率受麦克风距离、混响、重叠说话和模型影响，不承诺固定 WER。
- 说话人聚类只能区分“不同声音”，不能仅凭音频知道真实姓名。
- 源码构建使用 ad-hoc 签名；正式二进制分发包应使用 Developer ID 签名并完成 Apple 公证。

## 路线图

- 录音期间增量转写
- 麦克风和系统音频双路录制
- 会前资料和热点词注入
- SRT/VTT 导出
- 系统级全局听写

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。不要在 Issue、日志或测试夹具中上传真实会议录音、
参会人姓名、Token、API Key 或其他敏感数据。

## 许可证

项目代码采用 [MIT License](LICENSE)。第三方依赖和模型许可见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
