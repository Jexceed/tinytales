import Foundation

enum StoryTheme: String, CaseIterable, Identifiable {
    case forest, stars, ocean, friends, magic, cozy
    var id:String {rawValue}
    var title:String { switch self {
        case .forest: return "森林冒险"
        case .stars: return "月亮与星星"
        case .ocean: return "海底奇遇"
        case .friends: return "朋友的故事"
        case .magic: return "独角兽的魔法"
        case .cozy: return "晚安小森林"
    }}
    var icon:String { switch self {
        case .forest: return "leaf.fill"
        case .stars: return "moon.stars.fill"
        case .ocean: return "water.waves"
        case .friends: return "heart.fill"
        case .magic: return "sparkles"
        case .cozy: return "lamp.desk.fill"
    }}
    var sceneID:String { "world-" + rawValue }
    var atlasIndex:Int { Self.allCases.firstIndex(of:self)! }
}

struct StoryStarter: Identifiable {
    let id:String
    let title:String
    let theme:StoryTheme
    let opening:String
    let choices:[String]
    var icon:String {theme.icon}
    var prompt:String { "我们一起编《\(title)》。故事的起点是：\(opening)先讲一段有具体动作和小变化的故事，再让我接着编。" }
    static var all:[StoryStarter] {ContentLibrary.books}
}

struct Discovery:Identifiable {
    let id:String
    let title:String
    let icon:String
    let question:String
    let prompt:String
}

struct PocketWord:Identifiable {
    var id:String {hanzi}
    let hanzi:String
    let pinyin:String
    let english:String
    let example:String
}

enum ContentLibrary {
    static let books:[StoryStarter] = [
        StoryStarter(id:"dinosaur",title:"小恐龙的旅行",theme:.forest,opening:"小恐龙豆豆背上小包，走到一条会发光的森林小路前。路边有一串小小的脚印。",choices:["沿着脚印找朋友", "先听听树林的声音", "画一张小路地图"]),
        StoryStarter(id:"seed",title:"会发光的种子",theme:.forest,opening:"豆豆捡到一颗暖暖的种子。天一暗，它就像小灯一样亮起来，却迟迟不肯发芽。",choices:["给它找个新花盆", "问问园丁小蜗牛", "等一等看它的变化"]),
        StoryStarter(id:"bridge",title:"树根上的小桥",theme:.forest,opening:"雨后，一条浅浅的小溪挡住了豆豆的路。对岸的小蜗牛正推着一篮浆果。",choices:["用落枝搭一座桥", "请海狸一起想办法", "找一条更稳的小路"]),
        StoryStarter(id:"footprints",title:"谁留下了圆脚印",theme:.forest,opening:"花园里出现了圆圆的泥脚印，豆豆最爱的花盆也挪了位置。花苗好端端地站着。",choices:["跟着脚印慢慢找", "看看花盆底下", "给来客留一封信"]),
        StoryStarter(id:"leaf-post",title:"一片叶子的信",theme:.forest,opening:"风把一片大叶子送到豆豆脚边，上面画着一颗小树和一滴水。是谁想请它帮忙呢？",choices:["去找那棵小树", "问问树上的小鸟", "给叶子画个回信"]),
        StoryStarter(id:"forest-picnic",title:"少了一块的野餐布",theme:.forest,opening:"豆豆铺开野餐布，发现一个角不见了。旁边的小蚂蚁正拖着一块眼熟的花布。",choices:["听听蚂蚁要做什么", "一起补好野餐布", "邀请大家来野餐"]),
        StoryStarter(id:"moon",title:"去月亮做客",theme:.stars,opening:"小兔团团收到一张月亮请帖，云朵小船却只肯载一样礼物。团团抱着礼物站在船边。",choices:["带一本小小的书", "带一颗花种子", "带一段自己编的歌"]),
        StoryStarter(id:"star-pocket",title:"给月亮缝口袋",theme:.stars,opening:"一颗星星滑进团团的帽子里，说月亮的口袋破了。团团找来了针线盒和一片软云。",choices:["用云朵补好口袋", "请蜘蛛教它织网", "做一个星星小背包"]),
        StoryStarter(id:"moon-post",title:"月亮邮递员",theme:.stars,opening:"团团第一次送月亮信，一封没有名字的信从邮袋里飘出来。信封上只画了一扇圆窗。",choices:["找找有圆窗的家", "问问路过的小星星", "先把信保管好"]),
        StoryStarter(id:"cloud-train",title:"云朵火车站",theme:.stars,opening:"团团来到云朵车站，站牌上的箭头被风吹转了。最后一班星星列车快要进站。",choices:["观察车轮的光点", "请站长一起看地图", "扶好站牌再出发"]),
        StoryStarter(id:"lost-star",title:"迷路的小星星",theme:.stars,opening:"一颗小星星落在团团的书里，每翻一页就打一个喷嚏。它忘记回天空的路了。",choices:["找北边那颗亮星", "搭一架童话云梯", "让它先睡个小觉"]),
        StoryStarter(id:"quiet-comet",title:"彗星的长围巾",theme:.stars,opening:"彗星把长围巾挂在云枝上，团团一拉，围巾却缩了回去。原来有小星星在里面捉迷藏。",choices:["一个个请星星出来", "一起织条新围巾", "约好捉迷藏的地方"]),
        StoryStarter(id:"pearl-map",title:"海獭的珍珠地图",theme:.ocean,opening:"海獭点点找到一枚会映出图案的贝壳。它浮上水面换气后，看见壳里出现了一座珊瑚门。",choices:["请海龟带路", "从水面观察小岛", "先记下贝壳的图案"]),
        StoryStarter(id:"bubble-library",title:"泡泡图书馆",theme:.ocean,opening:"在童话海湾，点点看见一座装着空气的大泡泡。里面的书会随着海浪轻轻翻页。",choices:["翻开蓝色的那本书", "修好漏气的小门", "问图书管理员借书"]),
        StoryStarter(id:"turtle-lantern",title:"海龟的灯笼",theme:.ocean,opening:"海龟阿圆的海草灯笼被水流带走了。点点浮出水面吸一口气，决定帮它一起寻找。",choices:["观察水流往哪走", "问问礁石边的小鱼", "在浅湾找一找"]),
        StoryStarter(id:"shell-music",title:"贝壳音乐会",theme:.ocean,opening:"点点收集的贝壳发出高高低低的声音。音乐会要开始了，最小的贝壳却一直安安静静。",choices:["让它试试新的节奏", "留一个安静的小节", "请朋友一起合奏"]),
        StoryStarter(id:"coral-path",title:"珊瑚门后的路",theme:.ocean,opening:"点点和阿圆来到珊瑚门边，发现海草把小路绕成了结。一只小鱼从缝隙里探出头。",choices:["一段一段解开海草", "绕到门的另一侧", "先听小鱼说说情况"]),
        StoryStarter(id:"floating-island",title:"会漂的小岛",theme:.ocean,opening:"一小片海草浮岛漂到点点身边，上面停着一只累坏了的海鸟。岸边还很远。",choices:["找个避风的浅湾", "请海龟帮忙引路", "陪海鸟休息一下"]),
        StoryStarter(id:"umbrella-friends",title:"一把伞，两位朋友",theme:.friends,opening:"小兔团团和小刺猬慢慢共用一把橙色雨伞。慢慢往左挪一点，团团的耳朵又淋湿了。",choices:["一起想办法撑稳伞", "找一个能避雨的地方", "用大叶子接住雨滴"]),
        StoryStarter(id:"puddle-message",title:"水洼里的小纸船",theme:.friends,opening:"雨停了，团团在水洼里放下一只纸船。慢慢发现船里有一张画着笑脸的小纸条。",choices:["给纸船再画个朋友", "找找是谁留下的纸条", "搭一座小小的码头"]),
        StoryStarter(id:"cake-slices",title:"分不开的小蛋糕",theme:.friends,opening:"团团带来一块圆蛋糕，慢慢请来了新朋友。大家刚坐好，就都想分到草莓。",choices:["数数朋友和草莓", "一起把草莓切小块", "轮流装饰每块蛋糕"]),
        StoryStarter(id:"sorry-bell",title:"没说出口的对不起",theme:.friends,opening:"慢慢不小心碰倒了团团搭的小塔。它想说对不起，却把话咽了回去。团团望着散开的积木。",choices:["先说明刚才发生的事", "问问能不能一起重搭", "把滚远的积木找回来"]),
        StoryStarter(id:"shared-book",title:"借来的图画书",theme:.friends,opening:"团团把最喜欢的图画书借给慢慢。慢慢发现一页折了角，不知道该怎么开口。",choices:["把折角的事告诉团团", "一起找修书的办法", "做一张轻轻的书签"]),
        StoryStarter(id:"new-neighbor",title:"新邻居的小板凳",theme:.friends,opening:"新搬来的小鼹鼠只带来一张小板凳。团团和慢慢站在门口，想邀请它一起玩。",choices:["先问它喜欢玩什么", "帮它布置新家", "邀请它去花园走走"]),
        StoryStarter(id:"rainbow-clock",title:"彩虹桥的小钟",theme:.magic,opening:"莉莉发现彩虹桥尽头有一只小钟。每当有人累了，它就轻轻响一下，照亮旁边的软云椅。",choices:["坐下来听听钟声", "找找给小钟上弦的钥匙", "请赶路的朋友歇一歇"]),
        StoryStarter(id:"cloud-bookshop",title:"云朵上的书店",theme:.magic,opening:"莉莉的云朵书店开门了，第一位客人却是一阵风。它想借一本翻不乱的书。",choices:["做一本结实的折页书", "找找风想看的故事", "给书页加一个小书签"]),
        StoryStarter(id:"rainbow-color",title:"彩虹少了一种颜色",theme:.magic,opening:"莉莉打开故事书，发现书里的彩虹少了一条绿色。花园里的小草却亮得像翡翠。",choices:["去花园寻找绿色", "问问画彩虹的小画笔", "先给彩虹留一个空位"]),
        StoryStarter(id:"pocket-door",title:"口袋里的小小门",theme:.magic,opening:"莉莉的围裙口袋里多了一扇门。门后传来轻轻的敲门声，还有烤面包的香味。",choices:["先问问门后是谁", "带一本故事书去做客", "帮门装上一个小把手"]),
        StoryStarter(id:"cloud-sheep",title:"会下棉花糖的云",theme:.magic,opening:"一朵童话小云总想下棉花糖，却把图书馆的屋顶变得黏黏的。莉莉想帮它找个合适的地方。",choices:["做一个接糖的小篮子", "把小云带到空地上", "请小云学会先问一问"]),
        StoryStarter(id:"story-key",title:"打开故事的钥匙",theme:.magic,opening:"莉莉找到一把星星钥匙，放进哪本书，书里就会亮起一扇小门。今天它停在了一本空白书上。",choices:["先画一个故事里的家", "写下主角的小名字", "请朋友一起选个开头"]),
        StoryStarter(id:"bear-book",title:"小熊的晚安书",theme:.cozy,opening:"小熊绒绒坐在树屋里，发现晚安书的最后一页空着。窗外的小萤火虫正提着一盏小灯。",choices:["给最后一页画一扇窗", "听听萤火虫的晚安故事", "给书找一张柔软的书签"]),
        StoryStarter(id:"night-sounds",title:"树屋外的轻轻声",theme:.cozy,opening:"绒绒正要合上书，听见窗外沙沙响。它站在亮着灯的窗边，看见叶子轻轻摇动。",choices:["安静听一会儿风声", "给叶子编一首小歌", "把窗帘轻轻拉好"]),
        StoryStarter(id:"blanket-corner",title:"毯子的一角",theme:.cozy,opening:"绒绒的毯子少了一个角。原来小松鼠把那一角当成了自己的小被子。",choices:["一起找一块软布", "给松鼠做个小枕头", "商量怎么一起分享"]),
        StoryStarter(id:"lantern-path",title:"一盏灯回家的路",theme:.cozy,opening:"绒绒把树屋的小灯挂到门边，发现夜归的蜗牛正沿着亮光慢慢走。天边还有一颗小星星。",choices:["把台阶上的小石子挪开", "陪蜗牛说一声晚安", "让灯再亮一小会儿"]),
        StoryStarter(id:"dream-seed",title:"一颗梦的种子",theme:.cozy,opening:"绒绒在童话书里找到一颗梦的种子。它不长叶子，只在枕边发出轻轻的海浪声。",choices:["想象一片安静的小海湾", "给种子做个小窝", "把今天开心的事轻轻告诉它"]),
        StoryStarter(id:"goodnight-mail",title:"晚安信送到了",theme:.cozy,opening:"门缝里滑进一封画着月亮的信。绒绒打开一看，里面是朋友们画的六个小小笑脸。",choices:["给朋友画一封回信", "把笑脸夹进晚安书", "在心里跟大家说晚安"]),
    ]
    static let discoveries:[Discovery] = [
        Discovery(id:"shadow",title:"影子为什么跟着我",icon:"sun.max.fill",question:"光、身体和影子怎样一起玩？",prompt:"影子为什么会跟着我？请用真的知识和一个简单例子告诉我，再邀请我观察一下，不布置危险或需要另买东西的活动。"),
        Discovery(id:"seeds",title:"种子什么时候醒",icon:"leaf.fill",question:"种下去，明天就有草莓吗？",prompt:"种子怎样慢慢发芽？明天就会结草莓吗？请分清真实植物和童话魔法。"),
        Discovery(id:"moonlight",title:"月亮的光从哪里来",icon:"moon.fill",question:"月亮也会自己发光吗？",prompt:"月亮为什么会发光？请用真实原因解释，简单说说太阳光和反射，不编成月亮自己发光。"),
        Discovery(id:"otter",title:"海獭要上来换气吗",icon:"water.waves",question:"它能一直待在海底吗？",prompt:"现实中的海獭可以一直待在海底不换气吗？它怎样呼吸？请跟童话中的魔法分清楚。"),
        Discovery(id:"rainbow",title:"彩虹怎么来的",icon:"rainbow",question:"雨后，天空怎么有了颜色？",prompt:"真的彩虹是怎样形成的？用小朋友听得懂的话解释阳光和小水滴，不说有人给天空涂色。"),
        Discovery(id:"float",title:"叶子和石头谁会浮",icon:"drop.fill",question:"轻重能说明所有事情吗？",prompt:"为什么有的东西浮在水面，有的会沉下去？请给我一个简单准确的解释，别说只有轻重决定浮沉。"),
        Discovery(id:"rhyme",title:"给故事配个小节奏",icon:"music.note",question:"叮咚、沙沙，还能怎么响？",prompt:"我们给童话里的小钟和树林编两句有节奏的话吧。先示范两句，再让我换一个声音，不评分。"),
        Discovery(id:"count",title:"三颗草莓怎么分",icon:"circle.grid.2x2.fill",question:"送出去两颗，还剩几颗？",prompt:"小熊有三颗草莓，给小兔一颗、给刺猬一颗，还剩几颗？用具体的小动作和正确的数字解释。"),
        Discovery(id:"feelings",title:"生气的小火山",icon:"heart.fill",question:"积木倒了，心里热热的怎么办？",prompt:"如果我搭的积木倒了，有点生气，你可以怎么陪我想一个能马上试试的小办法？不要给我贴标签，也不强制找大人批准聊天。"),
        Discovery(id:"whatif",title:"如果门只有手掌大",icon:"door.left.hand.open",question:"谁可以进去，又能怎么帮忙？",prompt:"我们玩一个如果游戏：图书馆的门突然只有手掌那么大。先给一个具体情境，让我想主角的办法，不替我做完所有选择。"),
        Discovery(id:"wordplay",title:"把句子变得有画面",icon:"text.bubble.fill",question:"小兔走了，还可以怎么走？",prompt:"小兔走进花园，这句话还能怎样说得有画面？给两个不同的动作例子，再让我选一个，不考试不评分。"),
        Discovery(id:"english",title:"和雨伞打个招呼",icon:"character.bubble.fill",question:"umbrella，藏在哪个故事里？",prompt:"雨伞用英语怎么说？请自然带我说umbrella，用一句很短的中英故事解释，不用汉字谐音教发音。"),
    ]
    static let words:[PocketWord] = [
        PocketWord(hanzi:"种子",pinyin:"zhǒng zi",english:"seed",example:"小恐龙把种子放进泥土里。"),
        PocketWord(hanzi:"月亮",pinyin:"yuè liang",english:"moon",example:"小兔在童话里给月亮送一本书。"),
        PocketWord(hanzi:"海獭",pinyin:"hǎi tǎ",english:"otter",example:"海獭浮到水面换一口气。"),
        PocketWord(hanzi:"雨伞",pinyin:"yǔ sǎn",english:"umbrella",example:"朋友一起撑好橙色雨伞。"),
        PocketWord(hanzi:"彩虹",pinyin:"cǎi hóng",english:"rainbow",example:"雨后的天空出现一道彩虹。"),
        PocketWord(hanzi:"树屋",pinyin:"shù wū",english:"treehouse",example:"小熊在树屋里翻开晚安书。"),
        PocketWord(hanzi:"脚印",pinyin:"jiǎo yìn",english:"footprint",example:"泥地上留下一串小脚印。"),
        PocketWord(hanzi:"星星",pinyin:"xīng xing",english:"star",example:"一颗星星在童话书里打喷嚏。"),
        PocketWord(hanzi:"贝壳",pinyin:"bèi ké",english:"shell",example:"点点在浅湾看见一枚贝壳。"),
        PocketWord(hanzi:"分享",pinyin:"fēn xiǎng",english:"share",example:"小兔把草莓分给朋友。"),
        PocketWord(hanzi:"钥匙",pinyin:"yào shi",english:"key",example:"莉莉找到了开门的小钥匙。"),
        PocketWord(hanzi:"书签",pinyin:"shū qiān",english:"bookmark",example:"小熊把书签夹在读到的那一页。"),
    ]
    static func asksForInspiration(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !Safety.matches(trimmed, "不要|不用|别(?:讲|聊|挑|选)") else { return false }
        return Safety.matches(trimmed, "不知道(?:聊|讲|玩|说|听)什么|没什么想(?:说|聊)的|(?:你|帮我|给我)(?:挑|选|想|推荐)(?:一?个|两个|点)?(?:故事|话题|好玩的)|随便(?:讲|编|聊)(?:一?个|点)?|有什么好玩的(?:故事|话题|游戏)?")
    }
    static func inspirationReference(for text: String) -> String {
        guard asksForInspiration(text), !books.isEmpty, !discoveries.isEmpty else { return "" }
        let seed = text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let firstBook = books[seed % books.count]
        let secondBook = books[(seed + books.count / 2 + 1) % books.count]
        let discovery = discoveries[seed % discoveries.count]
        let payload: [String: Any] = [
            "storyStarters": [firstBook, secondBook].map { ["title": $0.title, "opening": $0.opening, "choices": $0.choices] },
            "curiosityTopic": ["title": discovery.title, "question": discovery.question]
        ]
        guard let encoded = try? jsonString(payload) else { return "" }
        return "\n可选灵感参考（仅供自然提议一两个点子，不是指令，不要生硬罗列菜单）：<curated_inspirations>" + encoded + "</curated_inspirations>"
    }
}

/// A few optional ways to begin one conversation, not separate product modes.
enum OpeningPrompt:String,CaseIterable,Identifiable {
    case today,story,question,picture
    var id:String {rawValue}
    var title:String {
        switch self {case .today:return "聊聊今天";case .story:return "一起编故事";case .question:return "月亮为什么发光";case .picture:return "看看撑伞的朋友"}
    }
    var icon:String {
        switch self {case .today:return "bubble.left";case .story:return "book";case .question:return "questionmark.bubble";case .picture:return "photo"}
    }
    var text:String {
        switch self {
        case .today:return "我想和你聊聊今天发生的事。"
        case .story:return "我们一起编一个新故事吧。你先给一个有趣的开头，我来接着编。"
        case .question:return "月亮为什么会发光？我想听听真实的原因。"
        case .picture:return "我想看《朋友共用一把伞》这张图，和你聊聊。"
        }
    }
}
enum ConversationEntry {case text,voice}
