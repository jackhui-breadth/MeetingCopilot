import Foundation

enum MinutesTemplate: String, CaseIterable, Identifiable {
    case general
    case weekly
    case requirementReview = "requirement-review"
    case oneOnOne = "one-on-one"
    case projectReview = "project-review"
    case customerVisit = "customer-visit"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用会议"
        case .weekly: "周会"
        case .requirementReview: "需求评审"
        case .oneOnOne: "1 对 1"
        case .projectReview: "项目复盘"
        case .customerVisit: "客户拜访"
        }
    }

    var focus: String {
        switch self {
        case .general:
            "提炼议题、各方观点、明确决议和行动计划。"
        case .weekly:
            "重点整理本周进展、风险阻塞、需要协调的事项和下周计划。"
        case .requirementReview:
            "重点整理业务背景、用户问题、范围边界、验收标准、争议点和待确认问题。"
        case .oneOnOne:
            "重点整理沟通主题、个人反馈、支持需求、成长方向和双方约定；保持克制，不推断隐私。"
        case .projectReview:
            "重点还原目标、结果、偏差、根因、经验教训和防止复发的行动项。"
        case .customerVisit:
            "重点整理客户需求、顾虑、竞争信息、我方承诺、商务下一步和明确负责人。"
        }
    }

    var sectionOutline: String {
        switch self {
        case .general:
            """
            ## 一、会议核心议题与背景
            ## 二、参会人核心观点
            ## 三、关键决议
            ## 四、待办任务与行动计划
            """
        case .weekly:
            """
            ## 一、本周进展
            ## 二、风险与阻塞
            ## 三、关键决议
            ## 四、下周计划与待办
            """
        case .requirementReview:
            """
            ## 一、需求背景与用户问题
            ## 二、方案范围与验收标准
            ## 三、争议点与待确认问题
            ## 四、关键决议与待办
            """
        case .oneOnOne:
            """
            ## 一、本次沟通主题
            ## 二、个人反馈与观察
            ## 三、支持需求与成长方向
            ## 四、双方约定与待办
            """
        case .projectReview:
            """
            ## 一、项目目标与最终结果
            ## 二、关键偏差与根因
            ## 三、经验教训
            ## 四、改进行动与待办
            """
        case .customerVisit:
            """
            ## 一、客户需求与业务背景
            ## 二、客户反馈与顾虑
            ## 三、我方立场与关键承诺
            ## 四、商务下一步与待办
            """
        }
    }
}
