import Foundation

/// 内置离线词典：术语级替换，不联网、不调大模型、不需要 Key。
///
/// 诚实说明：这是「术语+短语替换」，不是整句机器翻译。
/// 效果 = 关键名词/动词/连接词全部中文化，句子结构仍是英文语序。
/// 对财经新闻（术语密度高、句式重复）可读性已经够用；
/// 想要整句通顺，设置里可切到 LLM 模式。
enum Dict {

    /// 长短语优先匹配（含完整句式片段）
    static let phrases: [(String, String)] = [
        ("according to people familiar with the matter", "据知情人士"),
        ("people familiar with the matter", "知情人士"),
        ("according to a statement", "据一份声明"),
        ("in a statement", "在一份声明中"),
        ("declined to comment", "拒绝置评"),
        ("did not immediately respond to a request for comment", "未立即回应置评请求"),
        ("sources said", "消息人士称"),
        ("said on condition of anonymity", "要求匿名表示"),
        ("year on year", "同比"),
        ("year-over-year", "同比"),
        ("month on month", "环比"),
        ("quarter on quarter", "环比"),
        ("compared with", "相比"),
        ("up from", "高于此前的"),
        ("down from", "低于此前的"),
        ("rose to", "升至"),
        ("fell to", "跌至"),
        ("climbed to", "攀升至"),
        ("slumped to", "暴跌至"),
        ("surged to", "飙升至"),
        ("edged higher", "小幅走高"),
        ("edged lower", "小幅走低"),
        ("little changed", "基本持平"),
        ("basis points", "个基点"),
        ("percentage points", "个百分点"),
        ("all-time high", "历史新高"),
        ("record high", "历史新高"),
        ("record low", "历史低点"),
        ("first time since", "自……以来首次"),
        ("is expected to", "预计将"),
        ("are expected to", "预计将"),
        ("is likely to", "可能会"),
        ("in the coming months", "在未来几个月"),
        ("in the second half", "在下半年"),
        ("in the first half", "在上半年"),
        ("next year", "明年"),
        ("this year", "今年"),
        ("last year", "去年"),
        ("so far this year", "今年以来"),
        ("as of", "截至"),
        ("due to", "由于"),
        ("amid", "在……背景下"),
        ("despite", "尽管"),
        ("however", "然而"),
        ("meanwhile", "与此同时"),
        ("in addition", "此外"),
        ("moreover", "此外"),
        ("for example", "例如"),
        ("in contrast", "相比之下"),
        ("at the same time", "同时"),
        ("the company said", "该公司表示"),
        ("the report said", "报告称"),
        ("analysts said", "分析师表示"),
        ("investors said", "投资者表示"),
        ("the government said", "政府表示"),
    ]

    /// 术语表（名词/动词/形容词/机构）
    static let terms: [(String, String)] = [
        // 央行与政策
        ("Federal Reserve", "美联储"), ("the Fed", "美联储"), ("FOMC", "美联储公开市场委员会"),
        ("European Central Bank", "欧洲央行"), ("ECB", "欧洲央行"),
        ("Bank of Japan", "日本央行"), ("BOJ", "日本央行"),
        ("Bank of England", "英国央行"), ("BOE", "英国央行"),
        ("People's Bank of China", "中国人民银行"), ("PBOC", "中国人民银行"),
        ("rate cut", "降息"), ("rate hike", "加息"), ("rate decision", "利率决议"),
        ("interest rate", "利率"), ("policy rate", "政策利率"), ("benchmark rate", "基准利率"),
        ("monetary policy", "货币政策"), ("fiscal policy", "财政政策"),
        ("quantitative easing", "量化宽松"), ("quantitative tightening", "量化紧缩"),
        ("balance sheet", "资产负债表"), ("tapering", "缩减购债"),
        ("stimulus", "刺激措施"), ("austerity", "紧缩政策"),
        ("inflation", "通胀"), ("deflation", "通缩"), ("disinflation", "通胀放缓"),
        ("core inflation", "核心通胀"), ("consumer prices", "消费者价格"),
        ("producer prices", "生产者价格"), ("wage growth", "工资增长"),
        ("unemployment", "失业率"), ("jobless claims", "初请失业金人数"),
        ("payrolls", "非农就业"), ("labor market", "劳动力市场"),
        ("recession", "衰退"), ("soft landing", "软着陆"), ("hard landing", "硬着陆"),
        ("gross domestic product", "国内生产总值"), ("GDP", "GDP"),
        ("trade deficit", "贸易逆差"), ("trade surplus", "贸易顺差"),
        ("current account", "经常账户"), ("budget deficit", "预算赤字"),
        ("debt ceiling", "债务上限"), ("sovereign debt", "主权债务"),
        ("credit rating", "信用评级"), ("downgrade", "下调评级"), ("upgrade", "上调评级"),
        ("default", "违约"), ("bailout", "救助"), ("contagion", "蔓延风险"),
        ("tariff", "关税"), ("sanctions", "制裁"), ("export controls", "出口管制"),
        ("supply chain", "供应链"), ("reshoring", "回流"), ("nearshoring", "近岸外包"),

        // 市场
        ("stock market", "股市"), ("equities", "股票"), ("equity", "股票"),
        ("bond market", "债市"), ("bonds", "债券"), ("Treasuries", "美国国债"),
        ("yield", "收益率"), ("spread", "利差"), ("curve", "收益率曲线"),
        ("inversion", "倒挂"), ("auction", "拍卖"), ("issuance", "发行"),
        ("commodities", "大宗商品"), ("crude oil", "原油"), ("Brent", "布伦特原油"),
        ("WTI", "美国原油"), ("natural gas", "天然气"), ("gold", "黄金"),
        ("copper", "铜"), ("wheat", "小麦"),
        ("currency", "货币"), ("dollar", "美元"), ("euro", "欧元"), ("yen", "日元"),
        ("yuan", "人民币"), ("sterling", "英镑"),
        ("volatility", "波动率"), ("selloff", "抛售"), ("rally", "上涨行情"),
        ("rebound", "反弹"), ("correction", "回调"), ("bear market", "熊市"),
        ("bull market", "牛市"), ("liquidity", "流动性"), ("hedge", "对冲"),
        ("derivatives", "衍生品"), ("futures", "期货"), ("options", "期权"),
        ("short seller", "做空者"), ("buyback", "回购"), ("dividend", "股息"),
        ("valuation", "估值"), ("market capitalization", "市值"),

        // 公司与交易
        ("earnings", "财报"), ("revenue", "营收"), ("profit", "利润"),
        ("net income", "净利润"), ("operating income", "营业利润"),
        ("margin", "利润率"), ("guidance", "业绩指引"), ("outlook", "前景"),
        ("forecast", "预测"), ("estimate", "预估"), ("consensus", "市场一致预期"),
        ("quarterly", "季度"), ("annual", "年度"), ("fiscal year", "财年"),
        ("merger", "合并"), ("acquisition", "收购"), ("takeover", "收购"),
        ("deal", "交易"), ("stake", "股份"), ("shareholder", "股东"),
        ("board", "董事会"), ("CEO", "首席执行官"), ("CFO", "首席财务官"),
        ("chairman", "董事长"), ("management", "管理层"), ("employee", "员工"),
        ("layoffs", "裁员"), ("restructuring", "重组"), ("spinoff", "分拆"),
        ("initial public offering", "首次公开募股"), ("IPO", "IPO"),
        ("valuation", "估值"), ("private equity", "私募股权"), ("venture capital", "风险投资"),
        ("startup", "初创公司"), ("subsidiary", "子公司"), ("joint venture", "合资企业"),
        ("antitrust", "反垄断"), ("regulator", "监管机构"), ("investigation", "调查"),
        ("lawsuit", "诉讼"), ("settlement", "和解"), ("fine", "罚款"),
        ("bankruptcy", "破产"), ("creditors", "债权人"), ("debt restructuring", "债务重组"),

        // 科技
        ("artificial intelligence", "人工智能"), ("AI", "人工智能"),
        ("chip", "芯片"), ("semiconductor", "半导体"), ("data center", "数据中心"),
        ("cloud computing", "云计算"), ("software", "软件"), ("hardware", "硬件"),
        ("smartphone", "智能手机"), ("electric vehicle", "电动汽车"),
        ("battery", "电池"), ("autonomous driving", "自动驾驶"),
        ("crypto", "加密货币"), ("bitcoin", "比特币"), ("stablecoin", "稳定币"),
        ("blockchain", "区块链"), ("token", "代币"),

        // 通用高频
        ("company", "公司"), ("companies", "公司"), ("firm", "公司"), ("group", "集团"),
        ("bank", "银行"), ("banks", "银行"), ("fund", "基金"), ("investor", "投资者"),
        ("investors", "投资者"), ("market", "市场"), ("markets", "市场"),
        ("government", "政府"), ("ministry", "部"), ("official", "官员"),
        ("officials", "官员"), ("president", "总统"), ("prime minister", "总理"),
        ("parliament", "议会"), ("election", "选举"), ("policy", "政策"),
        ("report", "报告"), ("data", "数据"), ("survey", "调查"),
        ("growth", "增长"), ("decline", "下降"), ("increase", "上升"),
        ("decrease", "下降"), ("demand", "需求"), ("supply", "供应"),
        ("price", "价格"), ("prices", "价格"), ("cost", "成本"), ("costs", "成本"),
        ("sales", "销售额"), ("output", "产量"), ("capacity", "产能"),
        ("investment", "投资"), ("spending", "支出"), ("consumption", "消费"),
        ("exports", "出口"), ("imports", "进口"), ("trade", "贸易"),
        ("growth rate", "增速"), ("percentage", "百分比"), ("billion", "十亿"),
        ("million", "百万"), ("trillion", "万亿"), ("quarter", "季度"),
        ("week", "周"), ("month", "月"), ("year", "年"), ("day", "日"),
        ("Monday", "周一"), ("Tuesday", "周二"), ("Wednesday", "周三"),
        ("Thursday", "周四"), ("Friday", "周五"),
        ("said", "表示"), ("says", "表示"), ("added", "补充道"),
        ("expects", "预计"), ("expected", "预计"), ("plans", "计划"),
        ("announced", "宣布"), ("reported", "报告"), ("warned", "警告"),
        ("signaled", "暗示"), ("hinted", "暗示"), ("confirmed", "确认"),
        ("rejected", "否决"), ("approved", "批准"), ("agreed", "同意"),
        ("rose", "上涨"), ("fell", "下跌"), ("gained", "上涨"), ("lost", "下跌"),
        ("jumped", "跳涨"), ("dropped", "下跌"), ("slid", "下滑"), ("surged", "飙升"),
        ("plunged", "暴跌"), ("climbed", "攀升"), ("declined", "下降"),
        ("higher", "更高"), ("lower", "更低"), ("flat", "持平"),
        ("strong", "强劲"), ("weak", "疲软"), ("stronger", "更强"), ("weaker", "更弱"),
        ("record", "创纪录"), ("unprecedented", "前所未有"), ("unexpected", "意外"),
        ("major", "主要"), ("key", "关键"), ("top", "最高"), ("global", "全球"),
        ("domestic", "国内"), ("overseas", "海外"), ("emerging markets", "新兴市场"),
        ("developed markets", "发达市场"), ("Asia", "亚洲"), ("Europe", "欧洲"),
        ("United States", "美国"), ("China", "中国"), ("Japan", "日本"),
        ("Germany", "德国"), ("Britain", "英国"), ("India", "印度"),
        ("Washington", "华盛顿"), ("Beijing", "北京"), ("Brussels", "布鲁塞尔"),
        ("Wall Street", "华尔街"), ("Silicon Valley", "硅谷"),
        ("White House", "白宫"), ("Congress", "国会"), ("Treasury", "财政部"),
        ("IMF", "国际货币基金组织"), ("World Bank", "世界银行"),
        ("WTO", "世界贸易组织"), ("OPEC", "欧佩克"), ("NATO", "北约"),
        ("European Union", "欧盟"), ("G7", "七国集团"), ("G20", "二十国集团"),
    ]

    private static let allEntries: [(String, String)] = (phrases + terms)
        .sorted { $0.0.count > $1.0.count }

    private static let regexes: [(NSRegularExpression, String)] = {
        var out: [(NSRegularExpression, String)] = []
        for (en, zh) in allEntries {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: en) + "\\b"
            if let re = try? NSRegularExpression(pattern: pattern,
                                                 options: [.caseInsensitive]) {
                out.append((re, zh))
            }
        }
        return out
    }()

    /// 术语级替换：先长后短，避免 "AI" 把 "AI chip" 拆坏
    static func translate(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var text = input
        for (re, zh) in regexes {
            // 每一轮都要按当前字符串重算 range（替换后长度会变）
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = re.stringByReplacingMatches(
                in: text, options: [], range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: zh))
        }
        return text
    }

    static var entryCount: Int { allEntries.count }
}
