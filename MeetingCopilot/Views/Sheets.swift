import AVFoundation
import SwiftData
import SwiftUI

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let onCreated: (Project) -> Void

    @State private var name = ""
    @State private var projectDescription = ""
    @State private var colorHex = "#E8674A"
    @State private var errorMessage: String?

    private let colors = [
        "#E8674A", "#3A7AFE", "#2C9C68", "#A25DDC", "#D69A22", "#4B5563"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("新建项目")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Text("项目名称").font(.headline)
                TextField("例如：产品研发", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("项目说明").font(.headline)
                TextField("这个项目主要用于哪些会议？", text: $projectDescription)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("项目颜色").font(.headline)
                HStack(spacing: 12) {
                    ForEach(colors, id: \.self) { color in
                        Button {
                            colorHex = color
                        } label: {
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if colorHex == color {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("创建项目") {
                    createProject()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#E8674A"))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 520, height: 430)
    }

    private func createProject() {
        let project = Project(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            projectDescription: projectDescription,
            colorHex: colorHex
        )

        do {
            let directory = try ArchiveFileManager.shared.createProjectDirectory(for: project)
            try ArchiveFileManager.shared.writeProjectManifest(project, to: directory)
            modelContext.insert(project)
            try modelContext.save()
            onCreated(project)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LiveRecordingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var processingCoordinator: ProcessingCoordinator
    let project: Project
    let onCreated: (MeetingRecord) -> Void

    @StateObject private var capture = AudioCaptureManager()
    @State private var title = ""
    @State private var permissionState: AudioPermissionState = .checking
    @State private var activeMeeting: MeetingRecord?
    @State private var isPreparing = false
    @State private var isStopping = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(capture.isRecording ? "现场录音" : "新建会议")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("大家坐在同一张桌子旁，使用一个麦克风收录全场声音。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !capture.isRecording {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(26)

            Divider()

            VStack(spacing: 28) {
                VStack(spacing: 13) {
                    Text(capture.isRecording ? capture.isPaused ? "录音已暂停" : "正在录音" : "准备开始")
                        .font(.headline)
                        .foregroundStyle(capture.isPaused ? .orange : .secondary)
                    Text(formatDuration(capture.elapsedSeconds))
                        .font(.system(size: 58, weight: .light, design: .rounded))
                        .monospacedDigit()

                    HStack(alignment: .center, spacing: 4) {
                        ForEach(0..<28, id: \.self) { index in
                            Capsule()
                                .fill(levelColor(index))
                                .frame(
                                    width: 4,
                                    height: 8 + barHeight(index)
                                )
                        }
                    }
                    .frame(height: 52)
                    .animation(.easeOut(duration: 0.1), value: capture.audioLevel)

                    if capture.isRecording {
                        Text(
                            capture.currentGainDB > 0.4
                                ? String(format: "自动增益 +%.1f dB", capture.currentGainDB)
                                : "自动增益已启用"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 16)

                VStack(alignment: .leading, spacing: 16) {
                    if !capture.isRecording {
                        LabeledContent("会议标题") {
                            TextField("默认使用日期和序号", text: $title)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 330)
                        }
                    }

                    LabeledContent("麦克风") {
                        Picker("麦克风", selection: $capture.selectedDeviceID) {
                            if capture.devices.isEmpty {
                                Text("没有可用输入设备").tag("")
                            }
                            ForEach(capture.devices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 330)
                        .disabled(capture.isRecording)
                    }
                }
                .frame(maxWidth: 520)

                if permissionState == .denied {
                    VStack(spacing: 10) {
                        Label("需要麦克风权限才能开始录音", systemImage: "mic.slash.fill")
                            .foregroundStyle(.orange)
                        Button("打开系统设置") {
                            if let url = URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                            ) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .padding(14)
                    .background(.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if let message = errorMessage ?? capture.errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 14) {
                    if !capture.isRecording {
                        Button {
                            startRecording()
                        } label: {
                            Label(
                                isPreparing ? "正在准备…" : "开始录音",
                                systemImage: "record.circle"
                            )
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 180)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "#E8674A"))
                        .controlSize(.large)
                        .disabled(isPreparing || permissionState != .authorized || capture.devices.isEmpty)
                    } else {
                        Button(capture.isPaused ? "继续" : "暂停") {
                            capture.togglePause()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            stopRecording()
                        } label: {
                            Label(
                                isStopping ? "正在保存…" : "停止并保存",
                                systemImage: "stop.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        .disabled(isStopping)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        }
        .frame(width: 720, height: 570)
        .interactiveDismissDisabled(capture.isRecording || isPreparing || isStopping)
        .task {
            if title.isEmpty {
                title = defaultMeetingTitle()
            }
            permissionState = await capture.requestPermission()
                ? .authorized
                : .denied
        }
    }

    private func startRecording() {
        isPreparing = true
        errorMessage = nil

        let meeting = MeetingRecord(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? defaultMeetingTitle()
                : title.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        meeting.status = .recording

        Task {
            do {
                project.meetings.append(meeting)
                modelContext.insert(meeting)
                meeting.folderPath = try ArchiveFileManager.shared.createMeetingDirectory(
                    for: meeting,
                    in: project
                ).path
                try ArchiveFileManager.shared.writeMeetingManifest(
                    meeting,
                    project: project
                )
                try ArchiveFileManager.shared.writeProjectManifest(project)

                let rawURL = URL(fileURLWithPath: meeting.folderPath)
                    .appendingPathComponent("audio-source.caf")
                try await capture.startRecording(
                    rawURL: rawURL,
                    deviceID: capture.selectedDeviceID
                )
                activeMeeting = meeting
            } catch {
                meeting.status = .needsRecovery
                meeting.errorMessage = error.localizedDescription
                try? modelContext.save()
                errorMessage = "无法开始录音：\(error.localizedDescription)"
            }
            isPreparing = false
        }
    }

    private func stopRecording() {
        guard let meeting = activeMeeting else { return }
        isStopping = true
        errorMessage = nil

        Task {
            do {
                let result = try await capture.stopRecording()
                meeting.durationSeconds = result.durationSeconds
                meeting.audioFileName = result.url.lastPathComponent
                meeting.status = .recorded
                meeting.errorMessage = capture.errorMessage
                try modelContext.save()
                try ArchiveFileManager.shared.writeMeetingManifest(
                    meeting,
                    project: project
                )
                processingCoordinator.enqueue(
                    meeting: meeting,
                    project: project,
                    context: modelContext
                )
                onCreated(meeting)
                dismiss()
            } catch {
                meeting.status = .needsRecovery
                meeting.errorMessage = error.localizedDescription
                try? modelContext.save()
                errorMessage = error.localizedDescription
            }
            isStopping = false
        }
    }

    private func defaultMeetingTitle() -> String {
        let day = Date().formatted(.dateTime.month().day())
        let count = project.meetings.filter {
            Calendar.current.isDate($0.date, inSameDayAs: Date())
        }.count + 1
        return "\(day)会议 \(count)"
    }

    private func barHeight(_ index: Int) -> Double {
        let centerDistance = abs(Double(index) - 13.5) / 13.5
        let envelope = 1 - centerDistance * 0.55
        let variation = 0.45 + 0.55 * abs(sin(Double(index) * 1.73))
        return 40 * capture.audioLevel * envelope * variation
    }

    private func levelColor(_ index: Int) -> Color {
        let threshold = Double(index) / 28
        if capture.audioLevel > threshold {
            return capture.audioLevel > 0.78
                ? .red
                : Color(hex: "#E8674A")
        }
        return Color.secondary.opacity(0.16)
    }
}

private enum AudioPermissionState {
    case checking
    case authorized
    case denied
}
