import AVFoundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MainWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var processingCoordinator: ProcessingCoordinator
    @Query(sort: \Project.updatedAt, order: .reverse)
    private var projects: [Project]

    @State private var selectedProjectID: UUID?
    @State private var selectedMeetingID: UUID?
    @State private var showingNewProject = false
    @State private var showingRecording = false
    @State private var showingAudioImporter = false
    @State private var projectPendingDeletion: Project?
    @State private var meetingPendingDeletion: MeetingRecord?
    @State private var projectPendingRename: Project?
    @State private var meetingPendingRename: MeetingRecord?
    @State private var renameDraft = ""
    @State private var operationErrorMessage: String?

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    private var selectedMeeting: MeetingRecord? {
        selectedProject?.meetings.first { $0.id == selectedMeetingID }
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebarView(
                projects: projects,
                selection: $selectedProjectID,
                onCreateProject: { showingNewProject = true },
                onDeleteProject: { projectPendingDeletion = $0 },
                onRenameProject: beginRenaming
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 310)
        } content: {
            if let selectedProject {
                TimelineColumnView(
                    project: selectedProject,
                    selection: $selectedMeetingID,
                    onCreateMeeting: { showingRecording = true },
                    onImportAudio: { showingAudioImporter = true },
                    onDeleteMeeting: { meetingPendingDeletion = $0 },
                    onRenameMeeting: beginRenaming
                )
                .navigationSplitViewColumnWidth(min: 300, ideal: 370, max: 450)
            } else {
                ContentUnavailableView(
                    "选择一个项目",
                    systemImage: "rectangle.3.group",
                    description: Text("从左侧选择项目，或新建一个项目。")
                )
            }
        } detail: {
            if let project = selectedProject, let meeting = selectedMeeting {
                MeetingDetailView(
                    project: project,
                    meeting: meeting,
                    onDelete: { meetingPendingDeletion = meeting }
                )
                    .id(
                        "\(meeting.id.uuidString)-"
                        + "\(meeting.folderPath)-"
                        + "\(meeting.transcriptRevision)"
                    )
            } else {
                WelcomeDetailView(onCreateProject: { showingNewProject = true })
            }
        }
        .task {
            DemoDataSeeder.seedIfNeeded(context: modelContext)
            processingCoordinator.recoverInterruptedMeetings(
                context: modelContext
            )
            syncSelection()
        }
        .onChange(of: projects.count) {
            syncSelection()
        }
        .onChange(of: selectedProjectID) {
            selectedMeetingID = selectedProject?.sortedMeetings.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMeetingRequested)) { _ in
            if selectedProject != nil {
                showingRecording = true
            }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet { project in
                selectedProjectID = project.id
                selectedMeetingID = project.sortedMeetings.first?.id
            }
        }
        .sheet(isPresented: $showingRecording) {
            if let selectedProject {
                LiveRecordingSheet(project: selectedProject) { meeting in
                    selectedMeetingID = meeting.id
                }
            }
        }
        .fileImporter(
            isPresented: $showingAudioImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first,
                  let project = selectedProject
            else {
                if case .failure(let error) = result {
                    operationErrorMessage = error.localizedDescription
                }
                return
            }
            importAudio(url, into: project)
        }
        .confirmationDialog(
            "删除项目「\(projectPendingDeletion?.name ?? "")」？",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                if let project = projectPendingDeletion {
                    deleteProject(project)
                }
            }
            Button("取消", role: .cancel) {
                projectPendingDeletion = nil
            }
        } message: {
            Text("项目中的全部会议、录音、逐字稿和纪要都会移到废纸篓，可从 Finder 恢复。")
        }
        .confirmationDialog(
            "删除会议「\(meetingPendingDeletion?.title ?? "")」？",
            isPresented: Binding(
                get: { meetingPendingDeletion != nil },
                set: { if !$0 { meetingPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                if let meeting = meetingPendingDeletion {
                    deleteMeeting(meeting)
                }
            }
            Button("取消", role: .cancel) {
                meetingPendingDeletion = nil
            }
        } message: {
            Text("该会议的录音、逐字稿和纪要都会移到废纸篓，可从 Finder 恢复。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { operationErrorMessage != nil },
                set: { if !$0 { operationErrorMessage = nil } }
            )
        ) {
            Button("好") { operationErrorMessage = nil }
        } message: {
            Text(operationErrorMessage ?? "未知错误")
        }
        .alert(
            "重命名项目",
            isPresented: Binding(
                get: { projectPendingRename != nil },
                set: {
                    if !$0 {
                        projectPendingRename = nil
                        renameDraft = ""
                    }
                }
            )
        ) {
            TextField("项目名称", text: $renameDraft)
            Button("取消", role: .cancel) {
                projectPendingRename = nil
                renameDraft = ""
            }
            Button("保存") {
                commitProjectRename()
            }
            .disabled(
                renameDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        } message: {
            Text("项目目录和会议档案会同步更新名称。")
        }
        .alert(
            "重命名会议",
            isPresented: Binding(
                get: { meetingPendingRename != nil },
                set: {
                    if !$0 {
                        meetingPendingRename = nil
                        renameDraft = ""
                    }
                }
            )
        ) {
            TextField("会议标题", text: $renameDraft)
            Button("取消", role: .cancel) {
                meetingPendingRename = nil
                renameDraft = ""
            }
            Button("保存") {
                commitMeetingRename()
            }
            .disabled(
                renameDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        } message: {
            Text("会议文件夹、录音和纪要会保留，只更新标题与目录名称。")
        }
    }

    private func syncSelection() {
        if selectedProjectID == nil
            || !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = projects.first?.id
        }
        if selectedMeetingID == nil
            || !(selectedProject?.meetings.contains {
                $0.id == selectedMeetingID
            } ?? false) {
            selectedMeetingID = selectedProject?.sortedMeetings.first?.id
        }
    }

    private func deleteProject(_ project: Project) {
        if project.meetings.contains(where: hasActiveProcessing) {
            operationErrorMessage = "该项目中有会议正在转写，请等待处理完成后再删除。"
            return
        }

        let originalURL = project.folderPath.isEmpty
            ? nil
            : URL(fileURLWithPath: project.folderPath, isDirectory: true)
        var trashedURL: URL?
        do {
            if let originalURL {
                trashedURL = try ArchiveFileManager.shared.moveToTrash(originalURL)
            }
            let remaining = projects.filter { $0.id != project.id }
            if selectedProjectID == project.id {
                selectedProjectID = remaining.first?.id
                selectedMeetingID = remaining.first?.sortedMeetings.first?.id
            }
            modelContext.delete(project)
            try modelContext.save()
            projectPendingDeletion = nil
            syncSelection()
        } catch {
            modelContext.rollback()
            if let originalURL, let trashedURL {
                try? FileManager.default.moveItem(
                    at: trashedURL,
                    to: originalURL
                )
            }
            operationErrorMessage = error.localizedDescription
        }
    }

    private func deleteMeeting(_ meeting: MeetingRecord) {
        if hasActiveProcessing(meeting) {
            operationErrorMessage = "该会议正在转写，请等待处理完成后再删除。"
            return
        }

        let originalURL = meeting.folderPath.isEmpty
            ? nil
            : URL(fileURLWithPath: meeting.folderPath, isDirectory: true)
        var trashedURL: URL?
        do {
            if let originalURL {
                trashedURL = try ArchiveFileManager.shared.moveToTrash(originalURL)
            }
            let project = meeting.project
            let remaining = project?.sortedMeetings.filter {
                $0.id != meeting.id
            } ?? []
            if selectedMeetingID == meeting.id {
                selectedMeetingID = remaining.first?.id
            }
            project?.updatedAt = Date()
            modelContext.delete(meeting)
            try modelContext.save()
            meetingPendingDeletion = nil
            syncSelection()
        } catch {
            modelContext.rollback()
            if let originalURL, let trashedURL {
                try? FileManager.default.moveItem(
                    at: trashedURL,
                    to: originalURL
                )
            }
            operationErrorMessage = error.localizedDescription
        }
    }

    private func hasActiveProcessing(_ meeting: MeetingRecord) -> Bool {
        meeting.status == .processing
            || processingCoordinator.progress(for: meeting.id) != nil
    }

    private func importAudio(_ url: URL, into project: Project) {
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let meeting = try await AudioImportService.importAudio(
                    from: url,
                    into: project,
                    context: modelContext
                )
                selectedMeetingID = meeting.id
                processingCoordinator.enqueue(
                    meeting: meeting,
                    project: project,
                    context: modelContext
                )
            } catch {
                operationErrorMessage = "无法导入音频：\(error.localizedDescription)"
            }
        }
    }

    private func beginRenaming(_ project: Project) {
        renameDraft = project.name
        projectPendingRename = project
    }

    private func beginRenaming(_ meeting: MeetingRecord) {
        renameDraft = meeting.title
        meetingPendingRename = meeting
    }

    private func commitProjectRename() {
        guard let project = projectPendingRename else { return }
        do {
            try ArchiveFileManager.shared.renameProject(
                project,
                to: renameDraft,
                context: modelContext
            )
            projectPendingRename = nil
            renameDraft = ""
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    private func commitMeetingRename() {
        guard let meeting = meetingPendingRename,
              let project = meeting.project
        else { return }
        do {
            try ArchiveFileManager.shared.renameMeeting(
                meeting,
                in: project,
                to: renameDraft,
                context: modelContext
            )
            meetingPendingRename = nil
            renameDraft = ""
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }
}

private struct ProjectSidebarView: View {
    let projects: [Project]
    @Binding var selection: UUID?
    let onCreateProject: () -> Void
    let onDeleteProject: (Project) -> Void
    let onRenameProject: (Project) -> Void

    private var selectedProject: Project? {
        projects.first { $0.id == selection }
    }

    var body: some View {
        List(selection: $selection) {
            Section("项目") {
                ForEach(projects) { project in
                    HStack(spacing: 11) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(hex: project.colorHex))
                            .frame(width: 10, height: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(project.meetings.count) 场会议")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    .tag(project.id)
                    .contextMenu {
                        Button("重命名项目", systemImage: "pencil") {
                            onRenameProject(project)
                        }
                        Button(
                            "删除项目",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            onDeleteProject(project)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MeetingCopilot")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: onCreateProject) {
                    Label("新建项目", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#E8674A"))

                Button {
                    if let selectedProject {
                        onDeleteProject(selectedProject)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selectedProject == nil)
                .help("删除所选项目")
            }
            .controlSize(.large)
            .padding()
            .background(.regularMaterial)
        }
    }
}

private struct TimelineColumnView: View {
    let project: Project
    @Binding var selection: UUID?
    let onCreateMeeting: () -> Void
    let onImportAudio: () -> Void
    let onDeleteMeeting: (MeetingRecord) -> Void
    let onRenameMeeting: (MeetingRecord) -> Void

    private var selectedMeeting: MeetingRecord? {
        project.meetings.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(project.projectDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    if let selectedMeeting {
                        onDeleteMeeting(selectedMeeting)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selectedMeeting == nil)
                .help("删除所选会议")
            }
            .padding(20)

            Divider()

            if project.sortedMeetings.isEmpty {
                ContentUnavailableView(
                    "还没有会议",
                    systemImage: "waveform.badge.plus",
                    description: Text("坐下开会时，点一下就开始录音。")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(project.sortedMeetings.enumerated()), id: \.element.id) { index, meeting in
                            TimelineMeetingRow(
                                meeting: meeting,
                                isFirst: index == 0,
                                isLast: index == project.sortedMeetings.count - 1,
                                isSelected: selection == meeting.id
                            )
                            .onTapGesture {
                                selection = meeting.id
                            }
                            .contextMenu {
                                Button(
                                    "重命名会议",
                                    systemImage: "pencil"
                                ) {
                                    onRenameMeeting(meeting)
                                }
                                Button(
                                    "删除会议",
                                    systemImage: "trash",
                                    role: .destructive
                                ) {
                                    onDeleteMeeting(meeting)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
            }

            HStack(spacing: 10) {
                Button(action: onCreateMeeting) {
                    Label("新建会议", systemImage: "record.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#E8674A"))

                Button(action: onImportAudio) {
                    Label("导入音视频", systemImage: "square.and.arrow.down")
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TimelineMeetingRow: View {
    let meeting: MeetingRecord
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.secondary.opacity(0.22))
                    .frame(width: 2, height: 22)
                Circle()
                    .fill(isSelected ? Color(hex: "#E8674A") : Color.secondary.opacity(0.45))
                    .frame(width: 11, height: 11)
                    .overlay {
                        Circle()
                            .stroke(.background, lineWidth: 3)
                    }
                Rectangle()
                    .fill(isLast ? Color.clear : Color.secondary.opacity(0.22))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(meeting.title)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    StatusBadge(meeting: meeting)
                }

                HStack(spacing: 8) {
                    Label(formatDuration(meeting.durationSeconds), systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if !meeting.participantNames.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(meeting.participantNames.prefix(3), id: \.self) { name in
                            Text(name)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(hex: "#E8674A").opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(14)
            .background(isSelected ? Color(hex: "#E8674A").opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected ? Color(hex: "#E8674A").opacity(0.5) : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.trailing, 14)
        }
        .contentShape(Rectangle())
    }
}

struct StatusBadge: View {
    let meeting: MeetingRecord

    var body: some View {
        Text(meeting.status.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(statusColor)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch meeting.status {
        case .recording: .red
        case .readyWithSummary: .green
        case .needsRecovery: .orange
        case .awaitingSpeakerReview: .blue
        default: .secondary
        }
    }
}

private struct WelcomeDetailView: View {
    let onCreateProject: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color(hex: "#E8674A").opacity(0.1))
                    .frame(width: 120, height: 120)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color(hex: "#E8674A"))
            }

            VStack(spacing: 8) {
                Text("开会，从点一下开始")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("录音、逐字稿和会议纪要，都留在你的 Mac 上。")
                    .foregroundStyle(.secondary)
            }

            Button("新建第一个项目", action: onCreateProject)
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#E8674A"))
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(hex: "#E8674A").opacity(0.04)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        switch cleaned.count {
        case 3:
            red = (value >> 8) * 17
            green = ((value >> 4) & 0xF) * 17
            blue = (value & 0xF) * 17
        default:
            red = value >> 16
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
        }
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: 1
        )
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = max(Int(seconds.rounded()), 0)
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}
