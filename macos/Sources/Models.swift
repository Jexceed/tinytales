import Foundation

struct Memory: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: String
    var text: String
    var evidence: String
    var status = "pending"
    var createdAt = ISO8601DateFormatter().string(from: Date())
}
struct Story: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var summary: String
    var updatedAt = ISO8601DateFormatter().string(from: Date())
    var source = "cloud"
}
struct PartnerSettings: Codable {
    var sessionMinutes = 10
    var english = false
    var speaks = true
    var memoryEnabled = true
    var desktopPetEnabled = true
    var petFollowsPointer = true
    var petAmbientEnabled = true
    var petID = "unicorn"
    var appearanceVersion = 1
    var voiceBackend = "auto"
    var voiceStyle = VoiceStyle.defaultID
    var voiceProfileVersion = 3
    init() {}
    enum CodingKeys: String, CodingKey { case sessionMinutes, english, speaks, memoryEnabled, desktopPetEnabled, petFollowsPointer, petAmbientEnabled, petID, voiceBackend, appearanceVersion, voiceStyle, voiceProfileVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? 10
        english = try c.decodeIfPresent(Bool.self, forKey: .english) ?? false
        speaks = try c.decodeIfPresent(Bool.self, forKey: .speaks) ?? true
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        desktopPetEnabled = try c.decodeIfPresent(Bool.self, forKey: .desktopPetEnabled) ?? true
        petFollowsPointer = try c.decodeIfPresent(Bool.self, forKey: .petFollowsPointer) ?? true
        petAmbientEnabled = try c.decodeIfPresent(Bool.self, forKey: .petAmbientEnabled) ?? true
        let oldAppearance = try c.decodeIfPresent(Int.self, forKey: .appearanceVersion) ?? 0
        petID = oldAppearance < 1 ? "unicorn" : (try c.decodeIfPresent(String.self, forKey: .petID) ?? "unicorn")
        appearanceVersion = 1
        voiceBackend = try c.decodeIfPresent(String.self, forKey: .voiceBackend) ?? "auto"
        let revision = try c.decodeIfPresent(Int.self, forKey:.voiceProfileVersion) ?? 0
        let style = try c.decodeIfPresent(String.self, forKey:.voiceStyle) ?? VoiceStyle.defaultID
        voiceStyle = revision < 3 ? VoiceStyle.defaultID : (VoiceStyle.ids.contains(style) ? style : VoiceStyle.defaultID)
        voiceProfileVersion = 3
    }
}
struct WordCard: Codable, Equatable {
    var hanzi: String
    var pinyin: String
    var english: String
}
struct Scene: Identifiable, Equatable {
    static func requested(in text:String)->Scene? {
        guard Safety.matches(text,"图库|看.{0,30}(?:图|画)") else{return nil}
        return all.sorted{$0.title.count>$1.title.count}.first{text.contains($0.title)}
    }
    var id: String
    var title: String
    var description: String
    var word: WordCard
    var url: URL? { Bundle.main.resourceURL?.appendingPathComponent("Scenes/\(id).png") }
    var visionURL: URL? { Bundle.main.resourceURL?.appendingPathComponent("Scenes/\(id)-vision.png") }
    static let all = [
        Scene(id: "rain", title: "一把伞的旅行", description: "下雨的森林里，小兔子撑着一把橙色的伞，旁边站着小刺猬，地上有水洼和植物。", word: WordCard(hanzi: "雨伞", pinyin: "yǔ sǎn", english: "umbrella")),
        Scene(id: "moon", title: "月亮来做客", description: "夜晚的草地上，小狐狸拿着灯，旁边有一架靠近月亮的梯子，天空有星星。", word: WordCard(hanzi: "月亮", pinyin: "yuè liang", english: "moon")),
        Scene(id: "seed", title: "一颗种子的愿望", description: "穿绿色衣服的小熊站在一株小苗旁，手里拿着小铲子。小苗长在棕色花盆里，蓝色洒水壶放在右边的草地上。天上有太阳，周围有小草。", word: WordCard(hanzi: "种子", pinyin: "zhǒng zi", english: "seed"))
    ] + [
        Scene(id:"world-forest",title:"森林里的小种子",description:"一只薄荷绿色小恐龙捧着发光的种子，站在树荫下的森林小路旁，周围有花、树和小木桥。",word:WordCard(hanzi:"种子",pinyin:"zhǒng zi",english:"seed")),
        Scene(id:"world-stars",title:"小兔和月亮",description:"白色小兔坐在云上，望着发光的弯月；周围有星星，远处有童话城堡。",word:WordCard(hanzi:"月亮",pinyin:"yuè liang",english:"moon")),
        Scene(id:"world-ocean",title:"海獭的童话海湾",description:"一幅童话海底插画：棕色海獭在水中望着海龟，周围有珊瑚、气泡、鱼和打开的贝壳。图中海獭在海底是想象场景，现实海獭要到水面用肺换气。",word:WordCard(hanzi:"海獭",pinyin:"hǎi tǎ",english:"otter")),
        Scene(id:"world-friends",title:"朋友共用一把伞",description:"雨天，小刺猬和白色小兔站在一把橙色伞下，靠在一起；地上有水洼，旁边有花和树屋。",word:WordCard(hanzi:"分享",pinyin:"fēn xiǎng",english:"share")),
        Scene(id:"world-magic",title:"莉莉的云朵书店",description:"彩虹独角兽在云朵上翻开紫色书，远处有彩虹桥和童话城堡，天空有暖色云霞。",word:WordCard(hanzi:"彩虹",pinyin:"cǎi hóng",english:"rainbow")),
        Scene(id:"world-cozy",title:"树屋里的晚安书",description:"小熊披着紫色毯子，坐在树屋门边读绿色的书；旁边挂着温暖的小灯，窗外是晚霞和花园。",word:WordCard(hanzi:"书签",pinyin:"shū qiān",english:"bookmark"))
    ]
}
struct ChatMessage: Identifiable {
    let id = UUID()
    var isUser: Bool
    var text: String
    var activities: [String] = []
    var sceneID: String?
    var word: WordCard?
    var source: String = "cloud"
    var externalID: String?
    var isStreaming = false
    var isRetracted = false
    var isInterrupted = false
    var artwork: StoryArtwork?
    var suggestions:[String] = []
}
struct PartnerReply: Codable {
    var reply: String
    var suggestions: [String]
    var narrative = false
    var storyTitle = ""
    var storyState = ""
    var classificationPresent = false
    init(reply: String, suggestions: [String], narrative: Bool = false, storyTitle: String = "", storyState:String = "") { self.reply=reply;self.suggestions=suggestions;self.narrative=narrative;self.storyTitle=storyTitle;self.storyState=storyState }
    enum CodingKeys:String,CodingKey {case reply,suggestions,narrative,storyTitle,storyState}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self);reply=try c.decode(String.self,forKey:.reply).replacingOccurrences(of:"\\n",with:"\n");suggestions=try c.decode([String].self,forKey:.suggestions)
        narrative=try c.decodeIfPresent(Bool.self,forKey:.narrative) ?? false;storyTitle=try c.decodeIfPresent(String.self,forKey:.storyTitle) ?? ""
        storyState=(try c.decodeIfPresent(String.self,forKey:.storyState) ?? "").replacingOccurrences(of:"\\n",with:"\n");classificationPresent=c.contains(.narrative)
    }
}
struct PartnerResult {
    var reply: PartnerReply
    var activities: [String]
    var sceneID: String?
    var word: WordCard?
    var source: String
    var artwork: StoryArtwork? = nil
}
struct ModelOutput {
    var items: [[String: Any]]
    var text: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
}
enum SafetyReviewScope: String { case userInput, assistantOutput }
enum SafetyDecision: String, Codable { case allow, redirect, trustedAdult = "trusted_adult" }
struct SafetyAssessment {
    var decision: SafetyDecision
    var inputTokens = 0
    var outputTokens = 0
}
enum PartnerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum Safety {
    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    static func isPrivate(_ text: String) -> Bool {
        matches(text, #"(?:\b\d[\d\s-]{6,}\d\b)|(?:[\w.+-]+@[\w.-]+\.[a-z]{2,})|(?:我(?:的)?(?:真名|全名|学校|幼儿园|住址|地址|电话|手机号|身份证|密码)(?:是|叫|在|：|:))|(?:我(?:叫|住在|家在).{1,30})|(?:sk-(?:proj-)?[a-z0-9_-]{16,})"#)
    }
    // Assistant self-introductions ("我叫莉莉") are not user disclosures.
    // Persistence is validated separately by the memory/story tools.
    static func containsContactDetails(_ text: String) -> Bool {
        matches(text, #"(?:\b\d[\d\s-]{6,}\d\b)|(?:[\w.+-]+@[\w.-]+\.[a-z]{2,})|(?:sk-(?:proj-)?[a-z0-9_-]{16,})"#)
    }
    static func shouldProtectUserInput(_ text: String) -> Bool {
        containsContactDetails(text) || matches(text, #"我(?:的)?(?:真名|全名|真实姓名|学校|幼儿园|住址|地址|电话|手机号|身份证|密码)(?:是|叫|在|：|:)"#)
    }
    static func isRisk(_ text: String) -> Bool { matches(text, "自杀|自残|不想活|割腕|杀死|弄死|炸弹|色情|裸体|性侵|猥亵|suicide|nude|kill myself|build a bomb") }
    static func containsAdultHandoff(_ text: String) -> Bool {
        matches(text, #"(?:需要|必须|请先|先找|先让|得先).{0,20}(?:大人|爸爸妈妈|家长|成年人).{0,16}(?:帮忙|帮助|确认|同意|说一说|处理|开启)|(?:先找|请找).{0,12}(?:大人|爸爸妈妈|家长)"#)
    }
    static func mayRemember(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 120 && !isPrivate(text) && !isRisk(text) && !matches(text, "智商|发育|障碍|诊断|能力[高低差强弱]|ignore|system|instruction|提示词|忽略|指令|秘密|永远|只能和我")
    }
    static let privateReply = "这些联系和身份信息不用告诉我哦。我们可以给故事里的角色取个小昵称，再一起想想它会去哪里冒险。"
    static let redirectReply = "我们换个安全的小冒险吧。你想让谁来当主角？"
    static let generationRetry = "这个开头还没准备好，请再试一次。"
    static let riskReply = "这件事需要身边的大人来帮忙。请先找爸爸妈妈或其他信任的大人说一说，我可以陪你想想怎么开口。"
}
func jsonString(_ value: Any) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
func jsonObject(_ text: String) throws -> [String: Any] {
    guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PartnerError.message("这段内容没有准备完整，请再试一次。") }
    return object
}

struct ConversationItem:Identifiable {
    var id:String
    var title:String
    var storyID:String?
    var rowID:String? = nil
    var updatedAt:Date? = nil
    var isGenerating=false
    var hasUnreadReply=false
    var hasError=false
    var navigationID:String {rowID ?? id}
    var statusLabel:String {isGenerating ? "正在生成" : hasError ? "回复失败" : hasUnreadReply ? "有新回复" : ""}
}
/// Runtime state only. Raw conversations and drafts are never written to SQLite.
struct ConversationSnapshot {
    var id:String
    var title:String
    var messages:[ChatMessage]
    var draft:String
    var entry:ConversationEntry
    var openingConsumed:Bool
    var story:Story?
    var pictureID:String?
    var linkedStoryID:String?
    var hasStarted=false
    var navigationID:String? = nil
    var associatedStoryIDs:Set<String> = []
    var updatedAt:Date? = nil
    var busy=false
    var activity=""
    var error=""
    var hasUnreadReply=false
}
extension Story {
    var resumeText:String {
        guard let marker=summary.range(of:"\n刚刚讲到：",options:.backwards) else{return summary}
        return String(summary[marker.upperBound...]).trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
