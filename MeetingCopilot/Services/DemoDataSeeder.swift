import Foundation
import SwiftData

enum DemoDataSeeder {
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        let seedKey = "meetingCopilotDidSeedDemoData"
        guard !UserDefaults.standard.bool(forKey: seedKey) else { return }

        let descriptor = FetchDescriptor<Project>()
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else {
            UserDefaults.standard.set(true, forKey: seedKey)
            return
        }
        UserDefaults.standard.set(true, forKey: seedKey)

        let archive = ArchiveFileManager.shared
        let project = Project(
            name: "产品研发",
            projectDescription: "现场问题、产品讨论与交付复盘",
            colorHex: "#E8674A"
        )
        context.insert(project)

        do {
            let projectDirectory = try archive.createProjectDirectory(for: project)

            let first = MeetingRecord(
                title: "现场问题复盘",
                date: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            )
            first.durationSeconds = 3_842
            first.status = .readyWithSummary
            first.summaryTranscriptRevision = 1
            first.summaryGeneratedAt = Date()
            first.transcriptRevision = 1
            first.setSpeakerName("王工", for: "SPEAKER_00")
            first.setSpeakerName("李工", for: "SPEAKER_01")
            first.setSpeakerName("陈工", for: "SPEAKER_02")
            first.summarySpeakerMapJSON = first.speakerMapJSON
            first.summaryMarkdown = """
            # 现场问题复盘

            ## 一、核心议题

            讨论当前项目在现场推进中最影响交付节奏的问题，并明确本周的处理优先级。

            ## 二、核心观点

            - 王工：现场反馈集中在材料到场时间与安装节点不匹配，需要提前锁定关键批次。
            - 李工：当前信息通过群聊分散传递，建议统一到项目时间线，减少重复确认。
            - 陈工：质量问题需要在现场当天形成照片和文字记录，避免返工后无法追溯。

            ## 三、关键决议

            - 关键材料提前三天确认到场时间，并同步给施工负责人。[00:18:42]
            - 现场问题统一记录到项目时间线，不再只保留在群聊中。[00:41:10]

            ## 四、待办任务

            | 任务 | 负责人 | 时间节点 |
            | --- | --- | --- |
            | 整理关键材料到场计划 | 李工 | 本周五前 |
            | 建立现场问题记录模板 | 王工 | 明天 |
            | 补齐历史问题照片与说明 | 陈工 | 本周内 |
            """
            context.insert(first)
            project.meetings.append(first)

            first.folderPath = try archive.createMeetingDirectory(
                for: first,
                in: project
            ).path

            let demoLines: [(String, Double, Double, String)] = [
                ("SPEAKER_00", 35, 52, "今天主要把现场问题过一遍，尤其是影响本周安装节奏的部分。"),
                ("SPEAKER_01", 55, 76, "目前最明显的是关键材料到场时间和安装计划对不上，现场经常要临时调整。"),
                ("SPEAKER_02", 79, 101, "我建议把照片、位置和问题描述当天就记录完整，不然后面很难追溯原因。"),
                ("SPEAKER_00", 1_122, 1_146, "关键材料至少提前三天确认到场时间，同时同步给施工负责人。"),
                ("SPEAKER_01", 2_470, 2_498, "后续问题统一进入项目时间线，群聊只作为提醒，不作为唯一记录。")
            ]

            for (speaker, start, end, text) in demoLines {
                let segment = TranscriptSegment(
                    speakerId: speaker,
                    startTime: start,
                    endTime: end,
                    text: text
                )
                context.insert(segment)
                first.segments.append(segment)
            }

            let second = MeetingRecord(
                title: "交付节奏周会",
                date: Calendar.current.date(byAdding: .day, value: -5, to: Date()) ?? Date()
            )
            second.durationSeconds = 2_164
            second.status = .awaitingSpeakerReview
            second.transcriptRevision = 1
            second.setSpeakerName("周经理", for: "SPEAKER_00")
            context.insert(second)
            project.meetings.append(second)
            second.folderPath = try archive.createMeetingDirectory(
                for: second,
                in: project
            ).path

            let secondLines: [(String, Double, Double, String)] = [
                ("SPEAKER_00", 12, 35, "今天先对齐三个项目的交付节点，有风险的项目直接列出来。"),
                ("SPEAKER_01", 40, 68, "二号项目的外立面材料需要再确认一次，供应商目前给的时间比较紧。"),
                ("SPEAKER_02", 74, 98, "现场已经调整了安装顺序，预计能吸收两天左右的延期。")
            ]
            for (speaker, start, end, text) in secondLines {
                let segment = TranscriptSegment(
                    speakerId: speaker,
                    startTime: start,
                    endTime: end,
                    text: text
                )
                context.insert(segment)
                second.segments.append(segment)
            }

            try archive.writeProjectManifest(
                project,
                to: projectDirectory
            )
            try archive.writeAll(project: project, meeting: first)
            try archive.writeAll(project: project, meeting: second)
            try context.save()
        } catch {
            // 演示数据失败时不让应用无法启动，界面仍可继续创建真实会议。
            project.projectDescription += "（演示档案创建失败：\(error.localizedDescription)）"
            try? context.save()
        }
    }
}
