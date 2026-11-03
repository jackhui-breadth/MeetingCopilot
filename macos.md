# macOS 现场会议录音与 AI 纪要归档系统（MeetingCopilot）

> 版本：2.0  
> 目标平台：Apple Silicon 上的 macOS 14 Sonoma 及以上  
> 文档状态：MVP 实施规范  
> 核心场景：多位参会人坐在同一张桌子旁，使用一个现场麦克风连续录音；会议结束后自动转写、区分说话人，并在人工认领姓名后生成结构化纪要。

---

## 1. 产品定义

MeetingCopilot 是一个本地优先的 macOS 原生会议工具，用“项目 + 会议时间线 + 会议详情”组织现场会议的录音、逐字稿和纪要。

### 1.1 首版必须完成

1. 选择一个内置或外接麦克风，采集同一房间内的混合音轨。
2. 从会议时间线快速新建会议并开始录音。
3. 支持暂停、继续、停止、中止恢复，以及每十分钟滚动分片。
4. 使用 `mlx-whisper` 完成带时间戳的语音转写。
5. 使用 `pyannote.audio` 做软件说话人分离，并按时间轴对齐文字。
6. 允许把说话人标签认领为真实姓名。
7. 支持编辑逐字稿，并明确提示已有纪要是否过期。
8. 使用本地 Ollama 或用户显式配置的 OpenAI 兼容接口生成纪要。
9. 以磁盘明文档案为权威数据源，SwiftData 作为可重建索引。
10. 支持逐字稿搜索、音频时间点跳转、纪要编辑和归档包导出。

### 1.2 首版明确不做

- 不采集摄像头画面，不生成 MP4，不提供视频预览或视频播放器。
- 不导入已有视频或已有音频。
- 不做多麦克风多轨录制。
- 不在正常录制中无提示切换输入设备。
- 不做跨会议自动声纹识别。
- 不做实时字幕或录音过程中的实时转写。
- 不做多人协同、云同步或远程会议接入。
- 不做项目级或跨会议全文搜索。
- 不以 Mac App Store 沙盒分发为首版目标。

### 1.3 MVP 规模基线

- 标准验收会议：2 小时、最多 6 位说话人、中文为主、可含少量英文。
- 允许处理更长的会议，但硬上限为 4 小时。
- 目标机器：Apple Silicon M1、8 GB 内存。
- Whisper、Pyannote 和 LLM 处理必须串行，避免 M1 8 GB 机器内存争抢。
- 首次模型下载时间不计入处理性能验收。

---

## 2. 不可变设计原则

1. **录音安全优先。** 任何转写或 AI 服务失败都不能导致录音丢失。
2. **磁盘档案是事实源。** SwiftData 可删除、重建或修复，不得反向覆盖更新过的磁盘档案。
3. **处理可恢复。** 每个阶段成功后立即持久化产物，失败或退出后从断点继续。
4. **人工内容优先。** AI 重生成不得静默覆盖用户编辑过的纪要或逐字稿。
5. **本地隐私默认。** 录音和文字默认不上传；调用云端 LLM 必须由用户显式配置并看到发送提示。
6. **不确定就显示不确定。** 未认领的说话人、缺失的负责人和期限不得由模型编造。
7. **纯音频架构。** 产品模型、UI、目录、处理脚本中都不存在视频依赖。

---

## 3. 技术栈

- Swift 5.10+、SwiftUI、SwiftData
- AVFoundation 音频采集与 AAC 编码
- AVFoundation 音频播放器，不使用 AVKit 视频界面
- Python 3.10+
- `ffmpeg`，用于生成 16 kHz 单声道处理音频及必要的媒体校验
- `mlx-whisper`
- `pyannote.audio`
- `requests`
- Ollama 原生 `/api/generate` 或 OpenAI 兼容 `/v1/chat/completions`

依赖版本必须在真机和目标 Python 版本上验证后锁定。不要在未经测试时同时采用多个大版本范围；仓库应提交实际验证通过的 `requirements.txt` 或锁文件。

---

## 4. 总体架构

```text
SwiftUI
  ├── ProjectSidebarView
  ├── TimelineColumnView
  ├── MeetingDetailView
  └── LiveRecordingSheet
        │
        ▼
Application Services
  ├── ArchiveStore
  ├── AudioCaptureManager
  ├── RecordingSessionController
  ├── ProcessingCoordinator
  ├── PythonBridgeService
  └── SettingsStore
        │
        ├── SwiftData 索引
        └── 磁盘会议档案
                │
                ▼
Python process_meeting.py
  ├── audio extraction
  ├── mlx-whisper
  ├── pyannote
  ├── speaker alignment
  └── LLM summary
```

### 4.1 分层职责

- **Views**：只负责展示状态和提交用户意图，不直接写文件。
- **ArchiveStore**：档案扫描、创建、移动、原子写入、删除到废纸篓、归档包导出。
- **AudioCaptureManager**：设备枚举、权限、音频采样、电平、分片编码。
- **RecordingSessionController**：暂停/继续/停止、计时、设备断开恢复和录音状态。
- **ProcessingCoordinator**：阶段状态机、任务队列、断点恢复和重试。
- **PythonBridgeService**：子进程生命周期、JSON Lines 协议、取消和错误转换。
- **SettingsStore**：非敏感设置与 Keychain 中秘密的访问边界。

---

## 5. 磁盘档案契约

归档根目录默认：

```text
~/Movies/MeetingCopilot/
```

建议目录：

```text
~/Movies/MeetingCopilot/
├── 产品研发-A1B2C3/
│   ├── project.json
│   └── 2026-10-28_周会-7F2A9C/
│       ├── meeting.json
│       ├── audio.m4a
│       ├── transcript.json
│       ├── asr.raw.json
│       ├── minutes.md
│       ├── revisions/
│       │   ├── transcript-2026-10-28T14-30-00Z.json
│       │   └── minutes-2026-10-28T15-00-00Z.md
│       ├── .cache/
│       │   └── audio_16k.wav
│       └── .recording-session-<uuid>/
│           ├── chunk-0001.m4a
│           └── chunk-0002.m4a
└── 运营-9D8E7F/
```

以点开头的目录为临时目录，不参与普通档案扫描和归档包导出。

### 5.1 文件职责

| 文件 | 权威性 | 内容 |
|---|---|---|
| `project.json` | 权威 | 项目 UUID、名称、描述、颜色、时间戳 |
| `meeting.json` | 权威 | 会议元数据、说话人映射、阶段状态、摘要代际信息 |
| `audio.m4a` | 权威 | 最终合并后的 48 kHz 单声道 AAC 录音 |
| `transcript.json` | 权威 | 当前可编辑逐字稿与文本修订版本 |
| `asr.raw.json` | 权威历史产物 | ASR 原始输出，作为只读审计依据 |
| `minutes.md` | 权威 | 用户当前纪要内容 |
| `revisions/` | 历史 | 人工编辑被替换前的逐字稿或纪要版本 |
| `.cache/audio_16k.wav` | 可重建缓存 | 供 Whisper 和 Pyannote 使用 |
| `.recording-session-*` | 临时 | 未合并录音分片 |

### 5.2 身份与命名

- 项目与会议都有随机稳定 UUID，UUID 是真正身份。
- 目录名由“人类可读名称 + 6 位大写短 ID”组成，短 ID 由 UUID 派生或单独生成。
- 修改名称时先更新 manifest，再原子移动目录，最后更新 SwiftData 索引。
- 重名目录必须自动增加短 ID；不得仅靠标题和日期避免冲突。
- 文件名禁止路径分隔符、控制字符和以点开头的用户名称。
- 单段文件名建议限制在 120 个 Unicode 字符以内。
- manifest 内部只保存相对于会议目录或项目目录的路径，不保存可迁移性较差的绝对路径。
- SwiftData 可额外保存绝对目录路径作为索引缓存；启动扫描必须能重新计算它。

### 5.3 写入规则

1. 在目标文件同一目录创建临时文件。
2. 写入全部内容并同步到磁盘。
3. 验证 JSON 可解码或 Markdown 非空。
4. 若已有文件，将旧文件保留为 `.bak` 或移入 `revisions/`。
5. 使用原子替换提交正式文件。
6. 正式文件提交成功后再更新 SwiftData。

禁止从 SwiftData 向磁盘反向覆盖一个更新时间更新的现有文件。

### 5.4 启动一致性修复

应用启动和用户主动刷新时：

1. 扫描归档根目录下的 `project.json` 和会议目录。
2. 根据 manifest UUID 去重并重建 SwiftData 索引。
3. 校验关键文件是否存在，重新计算缓存与摘要是否过期。
4. 发现损坏 manifest 时把该会议放入“需要恢复”状态，不得自动用空数据覆盖。
5. 发现在 Finder 中被移动但没有离开根目录的档案时，根据 UUID 重新挂接。
6. 发现位于废纸篓中的档案时不自动恢复，但用户可以手动移回并重新扫描。

---

## 6. 数据契约

### 6.1 `meeting.json` 示例

```json
{
  "schemaVersion": 1,
  "id": "0E74D43A-2C27-4F04-9B85-D779DE05E1D2",
  "projectId": "E27A596A-C82B-4F75-84B7-94BC23C67C53",
  "title": "周会",
  "createdAt": "2026-10-28T06:00:00Z",
  "updatedAt": "2026-10-28T08:10:00Z",
  "durationSeconds": 6512.4,
  "language": "zh",
  "status": "ready_with_summary",
  "errorMessage": null,
  "audio": {
    "fileName": "audio.m4a",
    "codec": "aac",
    "sampleRate": 48000,
    "channels": 1,
    "bitRate": 96000,
    "sha256": "sha256:...",
    "devices": [
      {
        "uid": "AppleUSBAudioEngine:...",
        "name": "USB Conference Microphone",
        "startedAt": "2026-10-28T06:00:00Z"
      }
    ]
  },
  "speakerMap": {
    "SPEAKER_00": "王总",
    "SPEAKER_01": "李工"
  },
  "processing": {
    "mergeChunks": {
      "status": "succeeded",
      "finishedAt": "2026-10-28T07:50:00Z",
      "error": null
    },
    "audioExtraction": {
      "status": "succeeded",
      "finishedAt": "2026-10-28T07:51:00Z",
      "error": null
    },
    "transcription": {
      "status": "succeeded",
      "finishedAt": "2026-10-28T08:01:00Z",
      "error": null
    },
    "diarization": {
      "status": "succeeded",
      "finishedAt": "2026-10-28T08:04:00Z",
      "error": null
    },
    "alignment": {
      "status": "succeeded",
      "finishedAt": "2026-10-28T08:04:20Z",
      "error": null
    },
    "summary": {
      "status": "succeeded",
      "finishedAt": "2026-10-28T08:10:00Z",
      "error": null
    }
  },
  "summaryGeneration": {
    "transcriptRevision": 4,
    "transcriptSha256": "sha256:...",
    "provider": "ollama",
    "model": "qwen2.5:14b",
    "promptVersion": 1,
    "generatedAt": "2026-10-28T08:10:00Z",
    "usedRealNames": true
  }
}
```

### 6.2 阶段状态

每个处理阶段独立使用以下状态：

```text
pending
running
succeeded
failed
cancelled
```

阶段列表固定为：

```text
mergeChunks
audioExtraction
transcription
diarization
alignment
summary
```

阶段成功且所需产物仍存在时，重试或重启必须跳过该阶段。若输入指纹变化，例如逐字稿发生编辑，只允许重新执行依赖它的 `summary`。

### 6.3 会议级状态

```text
recording
recorded
processing
awaiting_speaker_review
ready_with_summary
ready_without_summary
needs_recovery
```

阶段失败不把整场会议标为完全不可用。录音已完成但 LLM 失败时，状态应为 `ready_without_summary`。

### 6.4 `transcript.json`

```json
{
  "schemaVersion": 1,
  "revision": 4,
  "sourceAsrSha256": "sha256:...",
  "updatedAt": "2026-10-28T08:06:00Z",
  "segments": [
    {
      "id": "0BCC22BB-2481-40D7-BCD7-8AE92D62EB50",
      "speakerId": "SPEAKER_00",
      "startTime": 12.44,
      "endTime": 18.91,
      "text": "这周的现场问题主要集中在施工节点。",
      "edited": false
    }
  ]
}
```

`asr.raw.json` 保存 ASR 与说话人分离的原始对齐结果，不随人工文字修改而改变。`transcript.json` 保存当前可编辑版本。

### 6.5 SwiftData 模型边界

SwiftData 至少包含：

- `Project`
- `MeetingRecord`
- `TranscriptSegment`
- `SpeakerMapping`

关键字段包括稳定 UUID、显示名称、显示排序、处理状态、最后错误、绝对目录索引、录音时长、文本修订版本和摘要代际信息。

SwiftData 模型不得保存 HuggingFace Token、LLM API Key 或云端 Authorization Header。敏感秘密只存 macOS Keychain。

---

## 7. 现场音频录制

### 7.1 设备与权限

- 使用 `AVCaptureDevice.DiscoverySession` 枚举 `.audio` 输入。
- 首版只允许选择一个音频输入设备，不采集系统声和摄像头。
- 应用启动时检测麦克风权限；获得权限后才能枚举可用设备。
- `Info.plist` 必须包含：

```xml
<key>NSMicrophoneUsageDescription</key>
<string>用于录制现场会议中多位参会人的发言</string>
```

- 默认选择上次成功使用的设备 UID；设备不存在时选择系统默认输入并显示提示。

### 7.2 音频采集实现约束

使用仅音频的 `AVCaptureSession` 和 `AVCaptureAudioDataOutput` 获取样本缓冲区，使用 `AVAssetWriter` 编码 AAC 分段文件。

推荐格式：

```text
编码：AAC
采样率：48 kHz
声道：单声道
目标码率：96 kbps
分片时长：10 分钟
最终文件：audio.m4a
```

不要使用 `AVCaptureMovieFileOutput`，也不要引入视频文件格式。音频电平应从实时样本计算 RMS 或使用适用的音频通道功率，显示平滑后的电平表，并避免采样导致主线程卡顿。

### 7.3 录音流程

1. 用户点击“新建会议”。
2. 默认填入当天日期和递增序号，例如“10 月 28 日会议 1”。
3. 用户可立即点击红色录音按钮。
4. 创建会议目录和 manifest，状态设为 `recording`。
5. 启动 `.recording-session-<uuid>/chunk-0001.m4a`。
6. 显示计时、电平、暂停和停止按钮。
7. 每 10 分钟安全结束当前分片并开始下一分片。
8. 暂停时结束当前分片；继续时创建新分片。
9. 停止时结束当前分片，写入分片清单。
10. 验证所有分片可读取，合并为 `audio.m4a`。
11. 校验最终音频时长和文件大小后进入处理状态机。

计时使用单调时钟，不能依赖系统墙上时间，避免用户修改系统时间导致时长错误。

### 7.4 后台与休眠

- 窗口最小化、切换前台应用或遮挡时继续录音。
- 菜单栏显示录音时长和红色状态点。
- 使用 `ProcessInfo` 活动断言禁止系统自动休眠。
- 允许显示器进入休眠。
- 系统被迫休眠、用户退出应用或进入关键系统更新前，先尝试结束当前分片并落盘。
- 录音期间关闭应用必须二次确认；默认操作为“取消关闭，继续录音”。

### 7.5 麦克风断开

- 立即结束当前分片，防止持续写入无效或静音内容。
- 暂停累计录音时长，显示明确错误和恢复按钮。
- 用户重新连接设备后，可以选择相同或新的输入设备。
- 新设备信息追加到 `meeting.json` 的 `audio.devices` 历史。
- 恢复后继续写新分片，属于同一场会议。
- 正常录制中没有错误时，不提供无提示热切换。

### 7.6 崩溃恢复

- 已完成并关闭的十分钟分片是崩溃后的主要恢复依据。
- 当前正在写入且未完成收尾的分片不得假定可用。
- 下次启动扫描未合并的 `.recording-session-*`。
- 若有至少一个已完成分片，提示“发现未完成录音”，允许验证、合并并继续处理。
- 若分片不可读，保留文件并显示恢复错误，不自动删除。

### 7.7 磁盘空间

- 开始录音前至少检查可用空间。
- 根据目标码率预估两小时录音所需空间，并额外预留 1 GB。
- 录制期间定期检查空间；低于安全阈值时暂停并提示，不等待写入失败后才报错。

---

## 8. 音频处理与状态机

### 8.1 标准流程

```text
停止录音
  → 合并分片
  → 生成并校验 audio.m4a
  → 生成 .cache/audio_16k.wav
  → Whisper 转写
  → Pyannote 说话人分离
  → 时间轴对齐
  → 等待人工认领说话人
  → 生成 AI 纪要
```

录音结束后自动执行到“等待人工认领说话人”，不要求用户留在处理页面。同一时间只运行一场重任务，其他会议排队。

### 8.2 转写

- 默认语言为中文 `zh`；设置允许单场改为自动检测或英文。
- 启用字级时间戳。
- 保存模型标识、语言、识别时间、原始输出哈希和警告。
- 空音频或完全无语音时，保留录音并标记转写为空，不删除任务。

### 8.3 说话人分离与对齐

1. Pyannote 返回带开始、结束和匿名标签的说话人 turn。
2. 优先把 Whisper 给每个 word 分配与其时间重叠最大的说话人。
3. 按连续说话人和停顿组合成可读段落。
4. 只有连续同说话人、中间没有其他说话人且停顿小于 1.5 秒时，才合并相邻片段。
5. 无法命中任何 turn 的文字归入当前最近说话人；若没有任何说话人，则使用 `SPEAKER_00`。
6. 必须防止时间倒置、负时长和重叠超出音频总长。

Pyannote 需要用户提供有效的 HuggingFace Token，并完成相应模型许可证确认。Token 缺失或模型不可用时，允许降级为单说话人转写，保留录音和文字，并允许以后只重跑说话人分离与对齐。

### 8.4 发言人认领

- 从当前会议提取所有原始 `speakerId`。
- 认领界面提供原始标签、发言时长、片段数和试听按钮。
- 用户至少认领一个说话人后才允许生成纪要。
- 未认领标签显示为“待确认发言人 1/2…”，不得伪造姓名。
- 认领修改立即更新 SwiftData 和 `meeting.json`，逐字稿实时刷新显示名。
- 修改认领后现有纪要标记为过期，不自动调用 LLM。

### 8.5 纪要生成

纪要固定包含：

1. 会议核心议题与背景
2. 参会人核心观点汇总
3. 关键决议
4. 待办任务与行动计划

约束：

- 关键决议和行动项尽量引用支持它们的发言时间，例如 `[01:23:45]`。
- 负责人或期限没有明确说出时写“未明确”。
- 禁止编造人员、日期、承诺、共识和决议。
- 区分“讨论意见”“已确认决议”“待办任务”。
- Markdown 是权威纪要格式。
- 短会议可一次生成；长逐字稿必须分块提取证据，再进行汇总。
- 分块摘要不得丢失时间戳和说话人。

### 8.6 过期判断

以下任一变化都会让已有纪要过期：

- `transcript.json.revision` 改变。
- 说话人映射进入纪要时使用的版本改变。
- 摘要模型、提示词版本或转录哈希改变。

过期只显示提示，不自动重新调用 LLM。

### 8.7 重新生成保护

- `minutes.md` 始终代表用户当前内容。
- 重新生成结果先写入临时候选文件。
- UI 展示新候选与现有内容的差异。
- 用户可选择替换、另存或取消。
- 替换前把当前 `minutes.md` 保存到 `revisions/minutes-<timestamp>.md`。
- 重新生成纪要只使用现有转写，不重跑 Whisper 和 Pyannote。

### 8.8 恢复与取消

- 每个阶段完成后原子写入产物和状态。
- 应用重启后从第一个未成功阶段继续。
- 取消时先保存已完成的阶段和产物。
- 取消 Python 任务必须终止整个进程组及其 FFmpeg 子进程。
- 重试失败阶段不得重新执行已经成功的阶段。

---

## 9. Python 子进程协议

### 9.1 输入

Python 脚本接受：

```text
--audio <audio.m4a>
--output-stage-dir <temporary-staging-directory>
--language <zh|auto|en>
--whisper-model <model>
--diarization-model <model>
--llm-provider <ollama|openai-compatible>
--llm-endpoint <url>
--llm-model <model>
--ffmpeg-path <path>
--resume-stage <optional-stage>
```

HuggingFace Token 和 API Key 不得出现在命令行参数中，因为其他本机进程可能读取进程参数。Swift 从 Keychain 读取后通过受控环境变量注入 Python，例如：

```text
MEETINGCOPILOT_HF_TOKEN
MEETINGCOPILOT_LLM_API_KEY
```

如果秘密必须写入临时配置，文件权限必须为 `0600`，任务结束后立即删除。

### 9.2 标准输出协议

`stdout` 只输出一行一个 JSON 对象。普通日志全部写入 `stderr`。

进度事件：

```json
{"type":"progress","stage":"transcription","fraction":0.42,"indeterminate":false,"message":"正在转写"}
```

错误事件：

```json
{"type":"error","stage":"diarization","code":"HF_TOKEN_MISSING","message":"未配置 HuggingFace Token","recoverable":true}
```

完成事件：

```json
{"type":"completed","stage":"summary","artifacts":{"candidateMinutes":"summary.candidate.md"}}
```

Python 只向 staging 目录写产物。Swift 验证 JSON、Markdown 和哈希后，再原子提升为权威档案文件。不得让 Python 直接覆盖 `transcript.json` 或 `minutes.md`。

### 9.3 退出与网络

- 成功退出码为 `0`。
- 可恢复错误使用非零退出码并通过 JSON 事件解释。
- Swift 同时监听退出码、`stdout` 协议和 `stderr`。
- 任何网络请求都需要明确超时。
- 云端 LLM 请求前显示模型名称和数据发送提示。
- 用户未配置云端 API 时，默认只访问本机 Ollama。

---

## 10. AI 提供方

### 10.1 本地 Ollama

默认端点：

```text
http://localhost:11434/api/generate
```

默认模型只作为初始建议，必须在设置向导中检测本机实际已安装模型。不得假定用户已经安装特定模型。

### 10.2 OpenAI 兼容接口

- 支持用户填写完整 `/v1/chat/completions` 地址。
- API Key 存 Keychain。
- 不将 Key 写入项目档案、导出包、日志或崩溃报告。
- 云端调用是显式选择，不是录音完成后的默认动作。

### 10.3 长文本摘要

- 优先按时间顺序分块。
- 每块生成带时间戳的议题、观点、决议和行动项证据。
- 最终用第二轮调用合并，不允许简单拼接后丢失来源。
- 提示词版本记入 `meeting.json`。
- 超过模型上下文限制时必须分块，不得静默截断后半场会议。

---

## 11. 用户界面

### 11.1 主工作区

采用 macOS 原生三栏布局：

- **左侧**：项目列表、新建项目、项目颜色、会议数量。
- **中间**：当前项目的纵向会议时间线，按日期倒序排列。
- **右侧**：选中会议详情。

时间线卡片显示：

- 日期与标题
- 录音时长
- 已认领发言人胶囊
- 处理状态或当前阶段
- 是否存在过期纪要或错误

顶部主操作只有“新建会议”，不存在“导入视频”或“导入音频”入口。

### 11.2 新建与录制

- 点击“新建会议”进入录制弹窗。
- 默认日期、序号、上次使用的麦克风和中文识别语言。
- 标题允许稍后修改。
- 显示输入设备、实时电平、累计时长、暂停/继续、停止和后台录制提示。
- 停止后关闭录制弹窗，会议出现在时间线并自动进入处理。

### 11.3 会议详情

顶部：

- 音频播放器
- 播放速度
- 当前时间与总时长
- 播放/暂停
- 录音设备与文件状态

中部：

- 发言人认领栏
- 原始标签、真实姓名、发言片段数、试听
- 生成或重新生成纪要按钮

底部使用“逐字稿 / 会议纪要”两个 Tab。

### 11.4 逐字稿

- 每行显示彩色说话人标签、时间和文字。
- 点击任意行，音频跳转到对应开始时间并播放。
- 支持当前会议关键词过滤。
- 支持内联修改文字。
- 文本编辑自动保存，但必须防抖并保证退出前 flush。
- 顶部显示纪要是否基于旧逐字稿。
- 不提供跨会议搜索。

### 11.5 会议纪要

- 提供 Markdown 预览与源码两种模式。
- 支持人工编辑并原子保存。
- 重新生成前显示差异。
- 提供“导出 Markdown”和“导出整个会议归档包”。
- 可以手动把纪要复制到剪贴板。

### 11.6 设置

设置页面至少包含：

- 音频设备偏好
- 默认识别语言
- Python 虚拟环境路径与健康状态
- FFmpeg 路径与版本
- HuggingFace Token 状态
- Ollama 地址与模型
- OpenAI 兼容地址与模型
- 模型缓存位置和已下载模型
- 云端数据提示与隐私设置

Token 输入框只显示是否已保存和测试结果，不回显 Keychain 中的完整秘密。

---

## 12. 首次运行与环境体检

### 12.1 健康检查项

- Apple Silicon 架构
- macOS 版本
- 麦克风权限
- 音频输入设备数量
- 归档根目录可写
- 可用磁盘空间
- Python 可执行文件
- 应用管理的虚拟环境是否完整
- Python 依赖能否导入
- FFmpeg 是否可执行
- 模型文件是否存在
- HF Token 是否有效、模型许可证是否已接受
- Ollama 服务与模型是否可用
- 云端接口配置是否有效

### 12.2 安装边界

- 应用可以创建自己的 venv，并在用户确认后安装 `requirements`。
- 不在后台静默安装 Homebrew、FFmpeg、Python 或大模型。
- FFmpeg 缺失时提供明确状态和可复制的 Homebrew 安装命令。
- 模型下载必须由用户确认，显示预计大小和目标缓存位置。
- 所有下载失败都允许重试，不得破坏已完成的录音。

### 12.3 降级路径

- 无 HF Token：仍可录音并做单说话人转写。
- Pyannote 失败：保留 ASR 结果，允许以后重跑分离。
- FFmpeg 缺失：保留录音和分片，阻止音频提取并向用户说明修复方法。
- Ollama/云端 LLM 不可用：保留录音和逐字稿，状态为 `ready_without_summary`。
- 麦克风缺失：允许浏览已有会议，不允许开始新录音。

---

## 13. 安全与隐私

- 录音、逐字稿、纪要默认只在本机。
- 归档为明文文件，不上传、不加密同步。
- 默认日志不得记录完整逐字稿、录音内容、HF Token、API Key 或 Authorization Header。
- 错误日志只记录阶段、错误码、文件状态和必要上下文。
- Keychain 用于保存：

```text
HuggingFace Token
云端 LLM API Key
```

- 向云端发送文字前展示目标服务、模型和发送范围。
- 导出 ZIP 不包含：

```text
.cache/
.recording-session-*/
模型文件
日志
Token
API Key
临时候选文件
```

- 首版为非 App Store 沙盒化的直接构建。未来启用 App Sandbox 时，必须改用用户选取目录和 security-scoped bookmark，不得依赖硬编码绝对路径。

---

## 14. 错误处理

至少定义以下错误类别：

- 麦克风权限拒绝
- 音频设备消失
- 音频写入失败
- 磁盘空间不足
- 分片合并失败
- Python 未安装或环境损坏
- FFmpeg 缺失
- ASR 模型加载失败
- HF Token 缺失或许可证未接受
- Pyannote 运行失败
- LLM 服务不可用
- 云端鉴权失败
- 归档 manifest 损坏
- 导出失败
- 数据库更新失败

UI 必须显示：

- 出错阶段
- 用户可理解的原因
- 当前已保存哪些资产
- 哪些操作可重试
- 是否会影响已有录音或人工纪要

任何错误都不得静默写入空文件覆盖现有权威文件。

---

## 15. 搜索、导出与删除

### 15.1 搜索

- 首版只搜索当前会议的 `transcript.json`。
- 大小写不敏感，支持中文子串。
- 显示过滤数量。
- 点击结果跳转并播放对应时间点。
- 后续可增加全局全文索引，但首版不实现。

### 15.2 导出归档包

导出的 ZIP 包含：

```text
meeting.json
audio.m4a
transcript.json
asr.raw.json
minutes.md
有效历史修订
```

要求：

- ZIP 根目录只有一个会议文件夹。
- 内部全部使用相对路径。
- 先写临时 ZIP，成功后再移动到正式位置。
- 用户可以在没有 MeetingCopilot 的情况下阅读 JSON 和 Markdown。
- 如果纪要不存在，明确记录“尚无纪要”，不伪造空内容。

### 15.3 删除

- 删除单场会议：确认后把整个会议目录移入废纸篓。
- 删除项目：展示会议数量并要求二次确认，然后把整个项目目录移入废纸篓。
- 文件移动成功后才删除 SwiftData 索引。
- 文件移动失败时数据库保持不变。
- 首版不提供无确认的永久删除入口。

---

## 16. 性能与资源

- 录音与后处理不得阻塞主线程。
- 读取音频样本、写入文件和 JSON 解析使用合适的后台队列或 actor。
- 录音写入 CPU/IO 预算优先于 UI 动画。
- Whisper、Pyannote、LLM 串行运行。
- 处理 Python 任务时显示真实阶段；无法获得细粒度进度时使用不确定进度条，不伪造百分比。
- 两小时会议不得一次性把完整 PCM 音频和全部模型同时载入内存。
- 长时间逐字稿编辑和搜索应分页、懒加载或增量过滤。
- M1 8 GB 目标是不发生内存崩溃；若 Pyannote MPS 兼容问题导致失败，允许回退 CPU，并在错误与日志中明确记录。

---

## 17. 实现阶段

### Phase 0：工程契约

- 初始化 macOS SwiftUI + SwiftData 工程。
- 建立 `schemaVersion`、manifest 编解码、错误类型和测试夹具。
- 固化磁盘档案与 SwiftData 的写入顺序。

完成标准：档案往返、原子写入、索引重建测试通过。

### Phase 1：项目与档案层

- 实现 `Project`、`MeetingRecord`、`TranscriptSegment`、`SpeakerMapping`。
- 实现 `ArchiveStore`、扫描修复、重命名、导出和删除到废纸篓。
- 不包含任何视频字段或视频文件逻辑。

完成标准：JSON/Markdown 修改后重启可重建索引；Finder 移动后可重新挂接。

### Phase 2：三栏 UI

- 实现项目栏、会议时间线、会议详情、音频播放器、说话人认领、逐字稿和纪要编辑。
- 提供可控 Mock 数据，但 Mock 不得进入正式档案。

完成标准：说话人改名即时刷新；逐字稿行可跳转音频；纪要过期提示准确。

### Phase 3：音频录制

- 实现设备枚举、权限、只录音频采集、电平、计时、暂停、继续、分片和崩溃恢复。
- 禁止使用视频采集或 `AVCaptureMovieFileOutput`。

完成标准：30 分钟真实录音可分片、合并、暂停继续；拔出麦克风后可恢复；异常退出后保留已完成分片。

### Phase 4：Python 处理管线

- 实现 staging 目录、JSON Lines 协议、16 kHz 音频提取、Whisper、Pyannote、时间轴对齐和取消。
- 实现环境体检和断点恢复。

完成标准：无 HF Token 时可单说话人转写；Pyannote 失败不影响 ASR；重启后不重复已完成阶段。

### Phase 5：LLM、设置与加固

- 实现 Ollama/OpenAI 兼容纪要、长文本分块、候选纪要、差异确认和版本保留。
- 实现 Keychain、隐私提示、日志脱敏、完整导出与验收。

完成标准：LLM 不可用时录音和逐字稿完整；人工纪要不会被自动覆盖；云端调用前有明确提示。

---

## 18. 测试与验收

### 18.1 自动测试

- manifest 编解码与 schema 迁移
- 阶段状态转换与断点恢复
- 原子写入与 `.bak` 恢复
- 稳定 UUID 去重
- 目录命名、重名与路径净化
- 外部移动后的索引重建
- 摘要过期哈希判断
- 删除失败时数据库不提交
- ZIP 相对路径与秘密排除
- Python JSON Lines 协议解析
- 子进程取消和子进程组清理

### 18.2 集成测试

- 30 分钟固定音频样本的完整处理。
- 无 HF Token 降级。
- Pyannote 失败后单独重试。
- LLM 断开后恢复摘要。
- 修改逐字稿后只重跑摘要。
- 修改纪要时保留历史修订。
- 录音分片中断后从已完成分片恢复。

### 18.3 端到端 MVP 验收

必须完成一次真实桌边测试：

- 30 分钟
- 至少 3 位说话人
- 有少量中英混杂
- 中途暂停并继续
- 模拟或实际断开一次输入设备并恢复
- 停止后自动处理
- 部分说话人认领
- 生成纪要
- 修改一条逐字稿并重新生成候选纪要
- 退出应用后重新打开，状态与内容保持
- 导出 ZIP 并独立解压检查
- 删除会议并确认可从废纸篓恢复

另用固定两小时任务模拟验证：

- 断点恢复
- 长文本分块
- 不重复完成阶段
- M1 8 GB 下不因一次性加载全部音频而内存崩溃

全部通过后才算 MVP 可用。

---

## 19. Definition of Done

一个会议只有同时满足以下条件才算“完成”：

1. 至少存在可播放的 `audio.m4a`。
2. `meeting.json` 与其录音、逐字稿和纪要保持一致。
3. 转写完成或明确记录失败的阶段，不得显示为成功。
4. 说话人标签使用真实姓名或明确显示为待确认。
5. 用户编辑后的逐字稿和纪要可跨重启恢复。
6. 任何 AI 重生成都不会静默覆盖人工内容。
7. 应用关闭、LLM 断开或单项处理失败都不会删除录音。
8. 导出的会议包不依赖本机数据库，且不包含秘密。

---

## 20. 后续候选能力

以下能力明确不属于首版，但数据模型和目录结构应允许后续扩展：

- 跨会议声纹库与显式声纹登记
- 多 USB 麦克风多轨录制
- 已有音频导入
- 全局全文搜索
- PDF/Word 纪要导出
- 多人协同和云同步
- 实时字幕
- App Store 沙盒分发

