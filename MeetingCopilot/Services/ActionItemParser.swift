import Foundation

struct MeetingActionItem: Identifiable, Hashable {
    let id: String
    let title: String
    let owner: String
    let deadline: String
    let source: String
}

enum ActionItemParser {
    static func parse(markdown: String) -> [MeetingActionItem] {
        let lines = markdown.components(separatedBy: .newlines)
        var items: [MeetingActionItem] = []
        var header: [String]?
        var taskIndex: Int?
        var ownerIndex: Int?
        var deadlineIndex: Int?
        var sourceIndex: Int?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|"), line.hasSuffix("|") else {
                header = nil
                continue
            }
            let cells = line
                .dropFirst()
                .dropLast()
                .split(separator: "|", omittingEmptySubsequences: false)
                .map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            guard !cells.isEmpty else { continue }

            if cells.allSatisfy({
                $0.replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .isEmpty
            }) {
                continue
            }

            if header == nil {
                let task = firstIndex(
                    in: cells,
                    containing: ["任务", "事项", "行动", "action", "task"]
                )
                let owner = firstIndex(
                    in: cells,
                    containing: ["负责人", "owner", "assignee"]
                )
                if let task {
                    header = cells
                    taskIndex = task
                    ownerIndex = owner
                    deadlineIndex = firstIndex(
                        in: cells,
                        containing: ["期限", "时间节点", "deadline", "due"]
                    )
                    sourceIndex = firstIndex(
                        in: cells,
                        containing: ["依据", "时间", "source"]
                    )
                }
                continue
            }

            guard let taskIndex,
                  taskIndex < cells.count
            else {
                continue
            }
            let title = clean(cells[taskIndex])
            guard !title.isEmpty,
                  !["未明确", "无", "暂无"].contains(title)
            else {
                continue
            }
            let owner = value(cells, at: ownerIndex)
            let deadline = value(cells, at: deadlineIndex)
            let source = value(cells, at: sourceIndex)
            let identity = "\(title)|\(owner)|\(deadline)|\(source)"
            items.append(
                MeetingActionItem(
                    id: identity,
                    title: title,
                    owner: owner.isEmpty ? "未明确" : owner,
                    deadline: deadline.isEmpty ? "未明确" : deadline,
                    source: source
                )
            )
        }

        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func firstIndex(
        in cells: [String],
        containing keywords: [String]
    ) -> Int? {
        cells.firstIndex { cell in
            let lowercased = cell.lowercased()
            return keywords.contains {
                lowercased.contains($0.lowercased())
            }
        }
    }

    private static func value(_ cells: [String], at index: Int?) -> String {
        guard let index, index < cells.count else { return "" }
        return clean(cells[index])
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
