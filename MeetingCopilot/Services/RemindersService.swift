import EventKit
import Foundation

struct RemindersSyncResult {
    let added: Int
    let skipped: Int
}

enum RemindersServiceError: LocalizedError {
    case permissionDenied
    case noCalendar

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "没有提醒事项权限。请在系统设置中允许 MeetingCopilot 访问提醒事项。"
        case .noCalendar:
            "没有可写入的提醒事项列表。"
        }
    }
}

@MainActor
enum RemindersService {
    static func sync(
        items: [MeetingActionItem],
        meeting: MeetingRecord
    ) async throws -> RemindersSyncResult {
        let store = EKEventStore()
        guard await requestAccess(store: store) else {
            throw RemindersServiceError.permissionDenied
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw RemindersServiceError.noCalendar
        }

        let predicate = store.predicateForReminders(in: [calendar])
        let existing = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        var existingTitles = Set(existing.map(\.title))
        var added = 0
        var skipped = 0

        for item in items {
            let title = "[\(meeting.title)] \(item.title)"
            guard existingTitles.insert(title).inserted else {
                skipped += 1
                continue
            }
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = title
            reminder.notes = [
                "负责人：\(item.owner)",
                "期限：\(item.deadline)",
                item.source.isEmpty
                    ? nil
                    : "依据：\(item.source)",
                "来源会议：\(meeting.title)"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            reminder.dueDateComponents = parse(date: item.deadline)
            try store.save(reminder, commit: false)
            added += 1
        }
        if added > 0 {
            try store.commit()
        }
        return RemindersSyncResult(added: added, skipped: skipped)
    }

    private static func requestAccess(store: EKEventStore) async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                store.requestFullAccessToReminders { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private static func parse(date value: String) -> DateComponents? {
        guard !value.isEmpty, value != "未明确" else { return nil }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = detector.firstMatch(
            in: value,
            options: [],
            range: range
        ), let date = match.date else {
            return nil
        }
        return Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
    }
}
