import Foundation

struct Skill: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let scenarios: [String]
    let doList: [String]
    let dontList: [String]
}

enum SkillsProvider {
    // “skills”思路（数据驱动、Owner 意识、先跑通再优雅、复盘机制等）整理为工程实践清单
    static let skills: [Skill] = [
        Skill(
            id: "owner-first",
            title: "Owner First",
            description: "对结果负责，端到端推进问题闭环，不甩锅、不等靠要。",
            scenarios: ["线上问题处置", "跨团队依赖推进", "里程碑延期风险"],
            doList: [
                "明确负责人与时间节点，形成可追踪的推进计划",
                "对外沟通给结论+行动项，避免信息噪音",
                "风险前置，主动同步进展与阻塞"
            ],
            dontList: [
                "只抛问题不给方案",
                "模糊职责边界导致无人负责",
                "拖延同步或隐瞒进度"
            ]
        ),
        Skill(
            id: "data-driven",
            title: "数据说话",
            description: "用数据定义问题、验证假设与度量改进，避免主观拍脑袋。",
            scenarios: ["性能优化", "A/B 实验", "质量治理"],
            doList: [
                "在变更前建立基线指标，变更后对比验证",
                "关键指标仪表盘可视化与告警接入",
                "复盘用数据支持结论"
            ],
            dontList: [
                "凭感觉优化不量化收益",
                "只看单点数据不看长期趋势",
                "忽略样本量与实验设计"
            ]
        ),
        Skill(
            id: "first-run",
            title: "先跑通再优雅",
            description: "先确保可用闭环，再逐步打磨设计与工程化，控制迭代节奏。",
            scenarios: ["新能力探索", "救火场景", "外部强依赖不确定"],
            doList: [
                "明确 MVP 范围与验收标准",
                "技术债登记入账，约定偿还窗口",
                "预留演进点，避免过度设计"
            ],
            dontList: [
                "一次性追求完美导致进度失控",
                "临时方案长期化而无治理计划",
                "无回滚/灰度策略"
            ]
        ),
        Skill(
            id: "security-compliance",
            title: "安全与合规",
            description: "默认安全设计，保护数据与隐私，遵循公司与行业规范。",
            scenarios: ["数据出入库", "第三方接入", "日志与埋点"],
            doList: [
                "敏感信息脱敏与最小权限",
                "依赖合规扫描与许可证检查",
                "日志分级与留存周期管理"
            ],
            dontList: [
                "明文存储凭证或在仓库提交密钥",
                "采集超出目的的个人信息",
                "越权访问与未审计的接口"
            ]
        ),
        Skill(
            id: "review-standards",
            title: "评审规范",
            description: "代码、设计与变更评审遵循明确 checklist，确保质量与一致性。",
            scenarios: ["代码合入", "架构变更", "上线变更"],
            doList: [
                "单变更小步提交并配套必要说明",
                "静态检查（格式/复杂度/依赖）与单测通过",
                "风险点、回滚方案、影响面评估"
            ],
            dontList: [
                "混合无关改动导致 review 困难",
                "无测试或未跑通构建",
                "隐式修改行为无说明"
            ]
        ),
        Skill(
            id: "icon-design",
            title: "产品图标设计（macOS/SF 风格）",
            description: "以轮廓优先的图形语言构建识别度，状态栏与 App 图标遵循平台规范与像素对齐。",
            scenarios: ["状态栏图标", "App 图标", "品牌识别"],
            doList: [
                "状态栏图标使用单色剪影+template 着色，保证深浅色模式可读性",
                "18pt/22pt 实测对齐，关键要素（钳子、纸张）用面积对比强化",
                "App 图标使用网格与圆角体系，简化细节，优先负形与闭环",
                "在 1×/2× 下做像素 hint，确保锯齿不显著",
                "A/B 视觉走查：缩略、远看、反转背景三种状态"
            ],
            dontList: [
                "状态栏使用多色/细线条导致对比不足",
                "写实插画风直接当图标，缩放后信息糊成一团",
                "未做小尺寸验证就直接投产",
                "形状过度对称且与文档图标重叠，识别点缺失"
            ]
        )
    ]
}
