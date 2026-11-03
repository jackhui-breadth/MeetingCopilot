import SwiftData
import SwiftUI

@main
struct MeetingCopilotApp: App {
    @StateObject private var processingCoordinator = ProcessingCoordinator()
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            Project.self,
            MeetingRecord.self,
            TranscriptSegment.self
        ])
        let configuration = ModelConfiguration(schema: schema)

        do {
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            fatalError("无法创建本地数据库：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWorkspaceView()
                .environmentObject(processingCoordinator)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1_360, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会议") {
                    NotificationCenter.default.post(
                        name: .newMeetingRequested,
                        object: nil
                    )
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .modelContainer(modelContainer)
                .frame(width: 620, height: 620)
        }
    }
}

extension Notification.Name {
    static let newMeetingRequested = Notification.Name("MeetingCopilot.newMeetingRequested")
}
