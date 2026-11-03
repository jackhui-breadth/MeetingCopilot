import XCTest
@testable import MeetingCopilot

final class ActionItemParserTests: XCTestCase {
    func testMarkdownActionTableIsParsed() {
        let markdown = """
        ## 待办

        | 任务 | 负责人 | 期限 | 依据时间 |
        | --- | --- | --- | --- |
        | 整理材料计划 | 李工 | 周五 | [00:35] |
        | 确认安装节点 | 未明确 | 未明确 | [01:10] |
        """

        let items = ActionItemParser.parse(markdown: markdown)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "整理材料计划")
        XCTAssertEqual(items[0].owner, "李工")
        XCTAssertEqual(items[0].deadline, "周五")
        XCTAssertEqual(items[1].owner, "未明确")
    }
}
