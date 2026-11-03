import AVFoundation
import SwiftUI

struct SettingsView: View {
    private let archive = ArchiveFileManager.shared
    @AppStorage("transcriptionEngine") private var transcriptionEngine = "auto"
    @AppStorage("audioAutoGainEnabled") private var autoGainEnabled = true
    @AppStorage("audioNoiseReductionEnabled") private var noiseReductionEnabled = true
    @AppStorage("minutesModel") private var minutesModel = "qwen3.5:9b"
    @AppStorage("minutesEndpoint") private var minutesEndpoint = "http://127.0.0.1:11434/api/generate"

    var body: some View {
        Form {
            Section("本地归档") {
                LabeledContent("目录") {
                    Text(archive.rootURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Button("在 Finder 中打开") {
                    NSWorkspace.shared.open(archive.rootURL)
                }
            }

            Section("音频") {
                LabeledContent("默认格式", value: "48 kHz 单声道 AAC")
                LabeledContent("分片目标", value: "每 10 分钟")
                LabeledContent(
                    "麦克风权限",
                    value: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                        ? "已允许"
                        : "未允许"
                )
                Toggle("自动增益与削波保护", isOn: $autoGainEnabled)
                Toggle("频谱降噪与响度标准化", isOn: $noiseReductionEnabled)
                Text("录制时先做低切、温和压缩和自动增益，保存时再做降噪与限幅。处理从下一次录音生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("处理服务") {
                LabeledContent("Python 解释器") {
                    Text(PythonBridgeService.pythonExecutableForDisplay())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Picker("中文转写引擎", selection: $transcriptionEngine) {
                    Text("自动（准确率优先）")
                        .tag("auto")
                    Text("SenseVoice（快速中文）")
                        .tag("sensevoice")
                    Text("Fun-ASR Nano（高精度）")
                        .tag("funasr-nano")
                    Text("MLX Whisper Large v3 Turbo")
                        .tag("whisper")
                }
                Text(engineDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                LabeledContent("会议纪要模型") {
                    TextField("例如 qwen3.5:9b", text: $minutesModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                LabeledContent("Ollama 接口") {
                    TextField("接口地址", text: $minutesEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                Text("纪要只发送到配置的本机 Ollama 接口，不会上传会议内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 12)
    }

    private var engineDescription: String {
        switch transcriptionEngine {
        case "auto":
            "默认使用 Fun-ASR Nano 高精度识别，并启用 Apple GPU 加速；优先保证逐字稿准确率。"
        case "sensevoice":
            "中文速度优先，保留分段时间戳；长会议通常比高精度模式快约 8 倍。"
        case "whisper":
            "多语言与词级时间戳优先，首次使用需下载较大模型。"
        default:
            "中文准确率优先。长篇会议耗时较长，但错误率明显低于快速模式。"
        }
    }
}
