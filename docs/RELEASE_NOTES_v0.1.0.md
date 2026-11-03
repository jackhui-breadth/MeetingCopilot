# MeetingCopilot v0.1.0 Developer Preview

首个开发者预览版，包含：

- macOS 本地录音和音频增强
- Fun-ASR Nano / SenseVoice / MLX Whisper 本地转写
- cam++ 说话人聚类与预计参会人数控制
- 时间戳逐字稿、播放高亮、参会人认领
- 本地 Ollama 会议纪要和 6 种会议模板
- 行动项提取与 macOS 提醒事项同步
- 音频/视频导入、TXT 导出、项目/会议管理

## 安装说明

模型文件不包含在发布包中。建议从源码构建并运行
`./scripts/setup-transcription.sh`。当前附件使用 ad-hoc 开发签名，不是面向普通用户的
Developer ID 公证发行版。

## 已知限制

- 录音结束后批处理，暂未实时增量转写
- ASR 准确率受收音、混响和重叠说话影响
- 说话人聚类只生成匿名标签，真实姓名需要人工认领
