# macOS 开源会议工具研究

研究日期：2026-11-03

## 结论摘要

1. MeetMemo 仓库真实存在，产品方向和 MeetingCopilot 最接近，但它是 2026 年
   新项目，GitHub 采用量远低于 Buzz，且使用 PolyForm Noncommercial
   许可证。可以借鉴产品结构和交互，不应直接复制代码到商业产品。
2. Buzz 是采用量更高、MIT 许可的成熟本地转录工具。最值得借鉴的是
   “音频/视频导入、实时麦克风转录、多种后端、导出 TXT/SRT/VTT”。
3. 真正改善长会议体验的核心不是换更大模型，而是录音期间做增量转录。
   MeetMemo README 明确描述“录制过程中持续接收流式语音识别结果”。
4. 会议模板、会前资料、Action Items 到系统提醒事项，是比单纯 ASR
   更能形成产品闭环的功能。
5. 我们的本地 cam++ 说话人聚类、Ollama 纪要、TXT 导出、重命名、删除、
   废纸篓恢复和本地隐私路径已经覆盖大部分会议工作流。

## 一手资料

### MeetMemo

- 仓库：<https://github.com/abcwyc/MeetMemo>
- README：<https://github.com/abcwyc/MeetMemo/blob/main/README.md>
- 事实：README 描述麦克风与系统音频双路录制、实时转录、SenseVoice /
  Fun-ASR-Nano / macOS SpeechAnalyzer、说话人识别、会前资料、模板、
  Action Items 到提醒事项、系统级语音输入、本地数据存储。
- 事实：README 标明 SenseVoice 和 Fun-ASR-Nano 基于 sherpa-onnx。
- 事实：README 标明许可证为 PolyForm Noncommercial License 1.0.0，
  商业使用需要单独授权。
- 事实：GitHub API 显示仓库创建于 2026-05，研究时约 57 stars、13 forks。
- 判断：“功能契合度高”成立，但“非常成熟”的说法证据不足，应按新项目
  评估稳定性、迁移和维护风险。

### Buzz

- 仓库：<https://github.com/chidiwilliams/buzz>
- README：<https://github.com/chidiwilliams/buzz/blob/main/README.md>
- 事实：支持音频、视频、YouTube 链接、麦克风实时转录、搜索、播放、
  语速、声源分离、说话人识别和 TXT/SRT/VTT 导出。
- 事实：支持 whisper.cpp 与 Apple Silicon 加速，项目采用 MIT 许可证。
- 事实：GitHub API 显示研究时约 22,381 stars、1,653 forks。
- 判断：Buzz 的采用量、许可证和成熟度都明显高于 MeetMemo。它的 UI
  工作流值得借鉴，但它是转录工具，不是完整的项目会议档案系统。

## 值得集成的功能与取舍

| 功能 | 来源参考 | 价值 | 当前状态 |
|---|---|---|---|
| 音频/视频导入 | Buzz、MeetMemo | 复用已有录音，扩大输入场景 | 已集成 |
| 录制期间增量转写 | Buzz、MeetMemo | 消除会议结束后的整场等待 | 下一阶段重点 |
| 会议模板 | MeetMemo | 不同会议输出不同结构 | 已集成 |
| Action Items 提取 | MeetMemo、Buzz 插件 | 把纪要变成任务 | 已集成 |
| 同步到 macOS 提醒事项 | MeetMemo | 形成系统级任务闭环 | 已集成 |
| 会前资料注入 | MeetMemo | 提高行业术语和业务上下文准确率 | 建议下一阶段 |
| 自定义系统提示词 | MeetMemo | 适配个人和团队纪要习惯 | 可由模板机制继续扩展 |
| 双路音频（麦克风 + 系统声） | MeetMemo | 兼顾现场与在线会议 | 架构改动较大 |
| 系统级全局听写 | MeetMemo | 把 ASR 扩展到其他应用 | 与会议主流程独立，后置 |
| 本地多 ASR 引擎 | Buzz、MeetMemo | 速度/准确率按场景选择 | 已有自动快速/高精度模式 |
| 本地说话人分离 | Buzz、MeetMemo | 解决“谁说了什么” | 已有 cam++ 本地聚类 |
| 本地 LLM 纪要 | MeetMemo、Ollama | 隐私与可控性 | 已有 Ollama |
| TXT/SRT/VTT 导出 | Buzz | 互操作和归档 | 已有 TXT，SRT/VTT 可补 |

## 本次已落地

- 会议模板：通用会议、周会、需求评审、1 对 1、项目复盘、客户拜访。
- 从 Markdown 纪要表格解析行动项，并同步到 macOS 提醒事项。
- 导入本地音频或视频，自动提取 48 kHz 单声道 AAC 音轨、建立会议
  档案并启动转写。

## 不建议直接照搬

- 不复制 MeetMemo 代码：其非商业许可证不适合未经确认的商业分发。
- 不直接换成 sherpa-onnx 整套框架：当前 Apple Silicon 上的
  SenseVoice/Fun-ASR/cam++ 管线已经验证可用，迁移必须有性能基准。
- 不把 pyannote 设为唯一说话人方案：它通常需要 HuggingFace Token 和
  模型许可确认；当前 cam++ 方案无需 Token。
- 不把“系统音频双路录制、全局听写、实时增量字幕”一次性全塞入同一版：
  这三项都会改变录音、权限和状态机，应分阶段验证。

## 推荐下一阶段

1. 录音期间按 VAD 句子增量识别，会议结束时只处理尾部音频。
2. 增量结果写入独立的 partial/final 状态，最终句子允许后台校正。
3. 会前资料与热点词注入 ASR/LLM，降低专有名词错误。
4. 增加 SRT/VTT 导出，满足视频剪辑和字幕工具使用。
5. 在稳定后再评估双路音频和系统级全局听写。
