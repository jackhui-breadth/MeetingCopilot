import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var processingCoordinator: ProcessingCoordinator
    let project: Project
    let meeting: MeetingRecord
    let onDelete: () -> Void

    @StateObject private var player = AudioPlayerController()
    @State private var tab: DetailTab = .transcript
    @State private var showingRetranscribeConfirmation = false
    @State private var exportErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            fixedMeetingControls

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    detailTabContent
                        .padding(24)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: activePlaybackSegmentID) { _, segmentID in
                    guard player.isPlaying,
                          tab == .transcript,
                          let segmentID
                    else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(segmentID, anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(meeting.title)
        .onAppear {
            player.load(url: meeting.audioURL)
        }
        .confirmationDialog(
            "重新生成整份逐字稿？",
            isPresented: $showingRetranscribeConfirmation,
            titleVisibility: .visible
        ) {
            Button("重新转写并保留旧版本") {
                processingCoordinator.enqueue(
                    meeting: meeting,
                    project: project,
                    context: modelContext,
                    replaceExisting: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前逐字稿会先保存到 revisions 目录，再使用设置中的引擎重新识别。")
        }
        .alert(
            "无法导出",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("好") { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "未知错误")
        }
    }

    private var fixedMeetingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            detailHeader

            processingStatus

            HStack(alignment: .top, spacing: 16) {
                AudioPlayerCard(player: player, meeting: meeting)
                    .frame(minWidth: 340)
                SpeakerMappingCard(
                    meeting: meeting,
                    onChanged: persist
                )
                .frame(maxWidth: 430)
            }

            if meeting.isSummaryStale {
                Label(
                    "逐字稿或发言人信息已变化，当前纪要可能已过期。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Picker("详情", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var detailTabContent: some View {
        switch tab {
        case .transcript:
            TranscriptListView(
                meeting: meeting,
                activeSegmentID: activePlaybackSegmentID,
                onSeek: { player.seek(to: $0) },
                onEdited: persist
            )
        case .summary:
            SummaryEditorView(
                meeting: meeting,
                onSave: persist
            )
        }
    }

    private var activePlaybackSegmentID: UUID? {
        let segments = meeting.sortedSegments
        guard let first = segments.first,
              let last = segments.last,
              player.currentTime >= first.startTime - 0.1,
              player.currentTime <= last.endTime + 1.5
        else {
            return nil
        }
        return segments.last {
            $0.startTime <= player.currentTime + 0.05
        }?.id
    }

    private func export(_ kind: MeetingTextExportKind) {
        let panel = NSSavePanel()
        panel.title = "导出\(kind.defaultSuffix)"
        panel.nameFieldStringValue = MeetingTextExportService.suggestedFileName(
            for: meeting,
            kind: kind
        )
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let content = MeetingTextExportService.content(
                    for: meeting,
                    project: project,
                    kind: kind
                )
                try content.write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(meeting.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                HStack(spacing: 12) {
                    Label(
                        meeting.date.formatted(date: .long, time: .shortened),
                        systemImage: "calendar"
                    )
                    Label(
                        formatDuration(meeting.durationSeconds),
                        systemImage: "clock"
                    )
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                if meeting.hasAudio,
                   !meeting.segments.isEmpty,
                   meeting.status != .processing {
                    Button("重新转写", systemImage: "arrow.clockwise") {
                        showingRetranscribeConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
                Menu {
                    Button("导出逐字稿 TXT") {
                        export(.transcript)
                    }
                    .disabled(meeting.segments.isEmpty)
                    Button("导出会议纪要 TXT") {
                        export(.minutes)
                    }
                    .disabled(meeting.summaryMarkdown.isEmpty)
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                Button("删除", systemImage: "trash", role: .destructive) {
                    onDelete()
                }
                .buttonStyle(.bordered)
                .disabled(meeting.status == .processing)
                StatusBadge(meeting: meeting)
            }
        }
    }

    @ViewBuilder
    private var processingStatus: some View {
        if let progress = processingCoordinator.progress(for: meeting.id) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(progress.stage.title, systemImage: "waveform.badge.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    if let fraction = progress.fraction {
                        Text("\(Int(fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(Color(hex: "#E8674A"))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#E8674A"))
                }
                Text(progress.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(hex: "#E8674A").opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else if meeting.hasAudio
            && meeting.segments.isEmpty
            && meeting.status != .recording {
            HStack(spacing: 12) {
                Image(
                    systemName: meeting.status == .processing
                        ? "exclamationmark.arrow.triangle.2.circlepath"
                        : "waveform.badge.magnifyingglass"
                )
                .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        meeting.status == .processing
                            ? "转写任务已中断"
                            : "录音已保存，尚无逐字稿"
                    )
                    .font(.headline)
                    if let error = meeting.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else {
                        Text("转写在本机完成，原录音始终保留。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("开始转写") {
                    processingCoordinator.enqueue(
                        meeting: meeting,
                        project: project,
                        context: modelContext
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#E8674A"))
                .disabled(!meeting.hasAudio)
            }
            .padding(16)
            .background(.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func persist() {
        meeting.project?.updatedAt = Date()
        try? modelContext.save()
        try? ArchiveFileManager.shared.writeTranscript(meeting)
        try? ArchiveFileManager.shared.writeSummary(meeting)
        try? ArchiveFileManager.shared.writeMeetingManifest(meeting, project: project)
    }
}

private enum DetailTab: Hashable, CaseIterable {
    case transcript
    case summary

    var title: String {
        switch self {
        case .transcript: "逐字稿"
        case .summary: "会议纪要"
        }
    }
}

private struct AudioPlayerCard: View {
    @ObservedObject var player: AudioPlayerController
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("会议录音", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                if !meeting.hasAudio {
                    Text("演示记录，无音频")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(Color(hex: "#E8674A"))
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!meeting.hasAudio)

                VStack(spacing: 7) {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0, play: false) }
                        ),
                        in: 0...max(player.duration, 0.1)
                    )
                    .tint(Color(hex: "#E8674A"))

                    HStack {
                        Text(formatDuration(player.currentTime))
                        Spacer()
                        Text(formatDuration(player.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("播放速度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("播放速度", selection: Binding(
                    get: { player.playbackRate },
                    set: { player.setPlaybackRate($0) }
                )) {
                    Text("0.8×").tag(Float(0.8))
                    Text("1.0×").tag(Float(1.0))
                    Text("1.2×").tag(Float(1.2))
                    Text("1.5×").tag(Float(1.5))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct SpeakerMappingCard: View {
    let meeting: MeetingRecord
    let onChanged: () -> Void

    private var speakerIDs: [String] {
        guard meeting.status != .processing else {
            return []
        }
        return Array(Set(meeting.segments.map(\.speakerId))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("认领参会人", systemImage: "person.2.badge.key")
                .font(.headline)

            HStack {
                Text("预计参会人数")
                    .font(.callout)
                Spacer()
                Picker(
                    "预计参会人数",
                    selection: Binding(
                        get: {
                            meeting.expectedSpeakerCount ?? 0
                        },
                        set: { value in
                            meeting.expectedSpeakerCount = value == 0
                                ? nil
                                : value
                            onChanged()
                        }
                    )
                ) {
                    Text("自动判断").tag(0)
                    ForEach(2...6, id: \.self) { count in
                        Text("\(count) 人").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            if speakerIDs.isEmpty {
                Text(
                    meeting.status == .processing
                        ? "正在重新识别说话人，完成后会更新这里的标签。"
                        : "录音完成并生成逐字稿后，可在这里认领发言人。"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if meeting.expectedSpeakerCount != nil {
                    Text("修改人数后需要点击“重新转写”才会重新分配说话人。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(Array(speakerIDs.enumerated()), id: \.element) { index, speakerID in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(speakerColor(index))
                            .frame(width: 9, height: 9)
                        Text(speakerID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .leading)
                        TextField(
                            "待确认发言人 \(index + 1)",
                            text: Binding(
                                get: { meeting.speakerName(for: speakerID) },
                                set: {
                                    meeting.setSpeakerName($0, for: speakerID)
                                    onChanged()
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func speakerColor(_ index: Int) -> Color {
        Color(
            hex: ["#E8674A", "#3A7AFE", "#2C9C68", "#A25DDC", "#D69A22"][index % 5]
        )
    }
}

private struct TranscriptListView: View {
    let meeting: MeetingRecord
    let activeSegmentID: UUID?
    let onSeek: (Double) -> Void
    let onEdited: () -> Void

    @State private var query = ""
    @State private var editingSegment: TranscriptSegment?

    private var filteredSegments: [TranscriptSegment] {
        if meeting.status == .processing {
            return []
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return meeting.sortedSegments
        }
        return meeting.sortedSegments.filter {
            $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("逐字稿", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                Text(
                    meeting.status == .processing
                        ? "重新生成中"
                        : "版本 \(meeting.transcriptRevision)"
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(filteredSegments.count) 段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("搜索当前会议", text: $query)
                .textFieldStyle(.roundedBorder)

            if filteredSegments.isEmpty {
                ContentUnavailableView(
                    "暂无逐字稿",
                    systemImage: "text.bubble",
                    description: Text(emptyStateDescription)
                )
                .frame(minHeight: 230)
            } else {
                VStack(spacing: 8) {
                    ForEach(filteredSegments) { segment in
                        TranscriptRow(
                            segment: segment,
                            speakerName: displayName(for: segment.speakerId),
                            isActive: segment.id == activeSegmentID,
                            onSelect: { onSeek(segment.startTime) },
                            onEdit: { editingSegment = segment }
                        )
                        .id(segment.id)
                    }
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .sheet(item: $editingSegment) { segment in
            TranscriptEditSheet(segment: segment) {
                meeting.markTranscriptEdited()
                onEdited()
            }
        }
    }

    private func displayName(for speakerID: String) -> String {
        let mapped = meeting.speakerName(for: speakerID)
        return mapped.isEmpty ? speakerID : mapped
    }

    private var emptyStateDescription: String {
        if meeting.status == .processing {
            return meeting.segments.isEmpty
                ? "正在本机识别会议语音，完成后逐字稿会出现在这里。"
                : "旧逐字稿已暂时隐藏，新版本完成后会整体刷新到这里。"
        }
        if meeting.hasAudio {
            return meeting.errorMessage ?? "录音已保存，可在上方开始本地转写。"
        }
        return "这是演示会议，没有关联音频。"
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let speakerName: String
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onSelect) {
                Text(formatDuration(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(hex: "#E8674A"))
                    .frame(width: 48, alignment: .leading)
            }
            .buttonStyle(.plain)

            Text(speakerName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(hex: "#E8674A").opacity(0.11))
                .clipShape(Capsule())

            Text(segment.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("编辑这段文字")
        }
        .padding(12)
        .background(
            isActive
                ? Color(hex: "#E8674A").opacity(0.16)
                : Color.clear
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isActive
                        ? Color(hex: "#E8674A").opacity(0.55)
                        : Color.clear,
                    lineWidth: 1.5
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}

private struct TranscriptEditSheet: View {
    let segment: TranscriptSegment
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑逐字稿")
                .font(.title2.bold())
            Text("对应的原始 ASR 输出会保留，不会被这次人工修改覆盖。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 15))
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    segment.text = text
                    onSave()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#E8674A"))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { text = segment.text }
    }
}

private struct SummaryEditorView: View {
    let meeting: MeetingRecord
    let onSave: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var mode: SummaryMode = .preview
    @State private var draft = ""
    @State private var showingCandidate = false
    @State private var generatedCandidate = ""
    @State private var generationErrorMessage: String?
    @StateObject private var generator = MinutesGenerator()
    @AppStorage("minutesTemplate") private var minutesTemplate = MinutesTemplate.general.rawValue
    @State private var isSyncingReminders = false
    @State private var remindersMessage: String?

    private var selectedTemplate: MinutesTemplate {
        MinutesTemplate(rawValue: minutesTemplate) ?? .general
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("会议纪要", systemImage: "doc.richtext")
                    .font(.headline)
                if meeting.isSummaryStale {
                    Text("已过期")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Picker("纪要模板", selection: $minutesTemplate) {
                    ForEach(MinutesTemplate.allCases) { template in
                        Text(template.title).tag(template.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                Picker("模式", selection: $mode) {
                    Text("预览").tag(SummaryMode.preview)
                    Text("编辑").tag(SummaryMode.edit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            if meeting.summaryMarkdown.isEmpty && generatedCandidate.isEmpty {
                ContentUnavailableView(
                    "尚无会议纪要",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text(
                        "将根据当前逐字稿，按“\(selectedTemplate.title)”模板在本机生成会议纪要。"
                    )
                )
                .frame(minHeight: 250)
            } else {
                Group {
                    if mode == .preview {
                        let source = generatedCandidate.isEmpty
                            ? meeting.summaryMarkdown
                            : generatedCandidate
                        MarkdownPreview(markdown: source)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    } else {
                        TextEditor(text: $draft)
                            .font(.system(size: 14, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(14)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(minHeight: 360)
                    }
                }
                .frame(minHeight: 360)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if !actionItems.isEmpty {
                actionItemsCard
            }

            HStack {
                Button {
                    generateMinutes()
                } label: {
                    HStack(spacing: 8) {
                        if generator.isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(
                            generator.isGenerating
                                ? generator.progressMessage
                                : "生成会议纪要"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    generator.isGenerating || meeting.segments.isEmpty
                )

                Spacer()

                if mode == .edit {
                    Button("保存修改") {
                        meeting.summaryMarkdown = draft
                        onSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#E8674A"))
                }

                if !generatedCandidate.isEmpty {
                    Button("应用候选纪要") {
                        showingCandidate = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#E8674A"))
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { draft = meeting.summaryMarkdown }
        .onChange(of: mode) {
            if mode == .edit {
                draft = meeting.summaryMarkdown
            }
        }
        .confirmationDialog(
            "用候选内容替换当前纪要？",
            isPresented: $showingCandidate,
            titleVisibility: .visible
        ) {
            Button("替换并保留旧版本") {
                archiveCurrentMinutes()
                meeting.summaryMarkdown = generatedCandidate
                meeting.summaryTranscriptRevision = meeting.transcriptRevision
                meeting.summarySpeakerMapJSON = meeting.speakerMapJSON
                meeting.summaryGeneratedAt = Date()
                meeting.status = .readyWithSummary
                draft = generatedCandidate
                generatedCandidate = ""
                onSave()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前内容会先保存到 revisions 目录，不会被静默覆盖。")
        }
        .alert(
            "无法生成会议纪要",
            isPresented: Binding(
                get: { generationErrorMessage != nil },
                set: { if !$0 { generationErrorMessage = nil } }
            )
        ) {
            Button("好") { generationErrorMessage = nil }
        } message: {
            Text(generationErrorMessage ?? "未知错误")
        }
        .alert(
            "提醒事项",
            isPresented: Binding(
                get: { remindersMessage != nil },
                set: { if !$0 { remindersMessage = nil } }
            )
        ) {
            Button("好") { remindersMessage = nil }
        } message: {
            Text(remindersMessage ?? "")
        }
    }

    private var activeMarkdown: String {
        generatedCandidate.isEmpty
            ? meeting.summaryMarkdown
            : generatedCandidate
    }

    private var actionItems: [MeetingActionItem] {
        ActionItemParser.parse(markdown: activeMarkdown)
    }

    private var actionItemsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    "可执行行动项 \(actionItems.count)",
                    systemImage: "checklist"
                )
                .font(.headline)
                Spacer()
                Button {
                    syncReminders()
                } label: {
                    if isSyncingReminders {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            "同步到提醒事项",
                            systemImage: "checkmark.circle.badge.plus"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isSyncingReminders)
            }

            ForEach(actionItems.prefix(6)) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    Text(
                        "负责人：\(item.owner) · 期限：\(item.deadline)"
                            + (item.source.isEmpty
                                ? ""
                                : " · \(item.source)")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if actionItems.count > 6 {
                Text("另有 \(actionItems.count - 6) 项，请查看完整纪要。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(hex: "#E8674A").opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func syncReminders() {
        isSyncingReminders = true
        Task {
            do {
                let result = try await RemindersService.sync(
                    items: actionItems,
                    meeting: meeting
                )
                remindersMessage = "新增 \(result.added) 项，跳过重复 \(result.skipped) 项。"
            } catch {
                remindersMessage = error.localizedDescription
            }
            isSyncingReminders = false
        }
    }

    private func generateMinutes() {
        generationErrorMessage = nil
        generatedCandidate = ""
        Task {
            do {
                generatedCandidate = try await generator.generate(
                    for: meeting,
                    template: selectedTemplate
                )
                mode = .preview
            } catch {
                generationErrorMessage = error.localizedDescription
            }
        }
    }

    private func archiveCurrentMinutes() {
        guard !meeting.summaryMarkdown.isEmpty, !meeting.folderPath.isEmpty else { return }
        let root = URL(fileURLWithPath: meeting.folderPath)
        let revisions = root.appendingPathComponent("revisions", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: revisions,
            withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        try? meeting.summaryMarkdown.write(
            to: revisions.appendingPathComponent("minutes-\(stamp).md"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private enum SummaryMode: Hashable {
    case preview
    case edit
}

private struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ) {
            Text(attributed)
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .textSelection(.enabled)
        }
    }
}

