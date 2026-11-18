import Foundation

/// Public-domain texts, checked against the linked editions. Explanations and
/// examples are written for this app; generated conversations never modify them.
struct ClassicalEntry: Codable {
    var id:String
    var kind:String
    var title:String
    var aliases:[String]
    var author:String
    var era:String
    var pinyin:String
    var original:String
    var origin:String
    var explanation:String
    var storyOutline:String
    var example:String
    var cautions:[String]
    var tags:[String]
    var sources:[String]
    var editionNote:String
    var checkedOn:String = "2026-11-16"
}

enum ClassicalKnowledge {
    static let instructions = """
    成语和古诗词：本轮已有curated_classics资料时先按资料回答；没有资料时，讲解、背诵或引用前先用lookup_classics按名称、诗句或主题查找。原文、作者、出处、字词与版本说明以返回的条目为依据，不把白话解释当原文，不把不同诗篇拼接。诗句可逐句读，保留完整字句。常见异文照editionNote说明，不把别的通行版本武断判错。讲典故时保留关键因果；加入新角色、对白或情节时自然说明“我们把这个故事改编一下”，不能说是原典真实记载。诗人作诗的具体现场、年龄和对话没有资料依据就不编成事实。未收录时说明暂时没有核对过这篇的原文，可以请对方给出篇名/原文或选一篇已收录作品，不编造出处；通俗解释若不确定就说明。普通聊天和自由故事不强行加成语，不考试、不评分，不用成语贬低孩子。出典可简短说出书名，电话不朗读网址，想看来源时再给文字链接。古诗赏析、典故解释不作为用户与莉莉共同创作的故事保存；明确一起改编的虚构故事才存档。
    主题检索是关键词匹配，未匹配的查询不等于整个主题都没有资料。返回available_titles时，可从已收录目录选相关篇名重新查询；不能只看相似名称就编造原文。match为related_topic_or_author的是相关参考，不是用户指定的另一篇作品。
    uncollected_titles列出本轮明确点名、尚未收录的作品。若用户只要其中一篇的原文，告诉对方资料本还没收录，可以请对方提供诗句。等对方选定其他作品再背，不自行朗读相似篇名的诗。
    match为possible_misheard_quote只表示可能听错的诗句，不是用户已经确认的原话。先简短确认，例如“你说的是《静夜思》里的‘举头望明月’吗？”；不要把近似诗句当人物名字继续编故事，也不宣称已经更正了用户输入。用户明确说是自编角色或否认诗句时，以用户说明为准。
    """
    private static let poetryBase = "https://www.edb.gov.hk/attachment/tc/curriculum-development/kla/chi-edu/recommended-passages/"
    private static func poem(_ id:String,_ title:String,_ aliases:[String],_ author:String,_ era:String="唐",_ original:String,_ explanation:String,_ tags:[String],_ page:String,_ cautions:[String],note:String="依据香港教育局建议篇章所载文字转为简体，标点按本库统一；原诗全文。",extraSources:[String]=[]) -> ClassicalEntry {
        ClassicalEntry(id:id,kind:"poem",title:title,aliases:aliases,author:author,era:era,pinyin:"",original:original,origin:author+"《"+title+"》",explanation:explanation,storyOutline:"",example:"",cautions:cautions,tags:tags,sources:[poetryBase+page+".pdf"]+extraSources,editionNote:note)
    }
    private static func idiom(_ id:String,_ title:String,_ aliases:[String],_ pinyin:String,_ original:String,_ origin:String,_ explanation:String,_ outline:String,_ example:String,_ tags:[String],_ sourceID:Int,_ cautions:[String]) -> ClassicalEntry {
        ClassicalEntry(id:id,kind:"idiom",title:title,aliases:aliases,author:"",era:"",pinyin:pinyin,original:original,origin:origin,explanation:explanation,storyOutline:outline,example:example,cautions:cautions,tags:tags,sources:["https://dict.idioms.moe.edu.tw/idiomView.jsp?ID=\(sourceID)&webMd=2"],editionNote:"典源摘句，按教育部《成语典》所载原典转为简体；不是整篇原文。解释、梗概和生活例子为本库自编。")
    }
    static let all:[ClassicalEntry] = [
        idiom("idiom-shou-zhu-dai-tu","守株待兔",[],"shǒu zhū dài tù",
              "因释其耒而守株，冀复得兔。","《韩非子·五蠹》",
              "把一次碰巧发生的好事当成每天都会发生的事，只等好运，事情反而做不好。也用来比喻守着旧办法，不看情况变化。",
              "宋国一个耕田人偶然得到一只撞树而死的兔子，便放下农具守着树等。后来没有再等到兔子。",
              "昨天在路上捡到一支铅笔，今天就不带文具，只等着再捡一支，这可不稳妥。",
              ["等待","侥幸","劳动","兔子"],39,["宋国是古代诸侯国，不是宋朝。","典故是寓言，不宣称是有确切人物姓名的史实；不增加残酷描写。"]),
        idiom("idiom-ya-miao-zhu-zhang","揠苗助长",["拔苗助长"],"yà miáo zhù zhǎng",
              "其子趋而往视之，苗则槁矣。","《孟子·公孙丑上》",
              "太想快点得到结果，用错了办法，反而伤害了正在成长的事物。揠就是拔。",
              "宋国有人嫌禾苗长得慢，把苗一棵棵往上拔。他以为这样能帮苗长高，儿子去看时，苗已经枯了。",
              "种下豆子后，给它合适的水和阳光，耐心观察；拉它的茎不能帮它长高。",
              ["成长","耐心","种子","植物"],56,["不是说不要照料禾苗，而是照料要合乎生长规律。","别名拔苗助长的首字读 bá，不能照抄揠的读音 yà。"]),
        idiom("idiom-hua-she-tian-zu","画蛇添足",[],"huà shé tiān zú",
              "蛇固无足，子安能为之足。","《战国策·齐策二》",
              "事情已经做好，又加上不需要的东西，反而弄糟了。",
              "几个人约定画蛇，先画完的人得到一壶酒。一人先画好，却又给蛇添脚；另一个人画完后指出蛇本来没有脚，拿走了酒。",
              "路线图已经清楚了，又把箭头涂成一团，让人找不到路，这种多添的部分反而帮倒忙。",
              ["适度","多余","画画","蛇"],23,["原典奖品是酒，不改称糖果而声称仍是原文；可略称奖品。","自由想象中画有脚的神奇蛇并没有错，成语说的是多余之举弄坏原来的目的。"]),
        idiom("idiom-wang-yang-bu-lao","亡羊补牢",[],"wáng yáng bǔ láo",
              "亡羊而补牢，未为迟也。","《战国策·楚策四》",
              "出了问题，及时修补造成问题的地方，可以减少以后再犯同样的错。亡是丢失，牢是牲畜圈。",
              "庄辛劝楚襄王时引用俗语：丢了羊再修补羊圈，还不算迟。常见的牧羊人、破羊圈和邻居提醒的长故事是后来的扩写。",
              "积木总从破盒子里掉出来，发现后补好盒子，就能让剩下的积木好好待在里面。",
              ["改错","补救","羊","修理"],482,["牢不是监牢。","补牢不等于丢失的羊会自动回来；别把现代扩写的对白标成原典原话。"]),
        idiom("idiom-ke-zhou-qiu-jian","刻舟求剑",[],"kè zhōu qiú jiàn",
              "舟已行矣，而剑不行。","《吕氏春秋·慎大览·察今》",
              "情况变了，办法却没跟着变，仍按原来的记号做事，就可能找错方向。",
              "楚国有人坐船过江，剑掉进水里。他在船边刻记号，等船停了再从记号处找剑，却忘了船已移动。",
              "玩具车已经推到桌子另一边，还在原来车窗下面找刚掉落的积木，就得先想想车移动过没有。",
              ["变化","观察","办法","船"],43,["记号刻在会移动的船上，不在岸边。","解释位置变化即可，不引导儿童跳水寻找物品。"]),
        idiom("idiom-yan-er-dao-ling","掩耳盗铃",["掩耳盗钟"],"yǎn ěr dào líng",
              "恐人闻之而夺己也，遽揜其耳。","《吕氏春秋·不苟论·自知》",
              "自己不去听、不去看，不等于事情就不存在；以为这样能瞒住别人，常常只骗了自己。",
              "原典里有人想搬走一口大钟，搬不动就敲它。钟发出声音，他怕别人听见来夺，赶紧捂住自己的耳朵。",
              "水杯碰倒了，把眼睛闭起来，桌上的水仍在那里，需要拿布擦一擦。",
              ["诚实","面对问题","声音","铃铛"],2,["原典写鍾，即钟；后来的成语叫掩耳盗铃，不能说原典就是小铃铛。","摘句中的揜通掩，读 yǎn；别用故事羞辱孩子。"]),
        idiom("idiom-zi-xiang-mao-dun","自相矛盾",[],"zì xiāng máo dùn",
              "以子之矛，陷子之楯，何如？","《韩非子·难一》，相关故事亦见《难势》",
              "同一件事的两种说法互相冲突，不能同时成立。",
              "卖矛和盾的人先说自己的盾什么都刺不穿，又说自己的矛什么都能刺穿。旁人问用他的矛刺他的盾会怎样，他答不上来。",
              "先说盒子里一块积木也没有，接着又说里面还有三块；如果盒子没动过，这两句话就对不上。",
              ["逻辑","一致","说话","矛盾"],89,["矛用于刺，盾用于防护；楯在这里同盾。","重点是同一条件下的冲突，不把改变主意、时间变化或正常不同感受都说成矛盾。"]),
        idiom("idiom-jing-di-zhi-wa","井底之蛙",[],"jǐng dǐ zhī wā",
              "井鼃不可以语于海者，拘于虚也。","《庄子·秋水》",
              "只看过很小的地方，容易以为世界只有自己看到的那么大；多观察、多听别人介绍，能认识更多。",
              "《庄子》用井蛙不懂大海的比喻，说明认识会受所处环境限制；书中也有井蛙与东海鳖谈话的寓言。",
              "只见过家门口的小水洼，再看看河流和大海的图片，就会发现水的世界大得多。",
              ["见识","观察","世界","青蛙"],380,["鼃同蛙；原文的虚通墟，指居处。","别把课文坐井观天里青蛙与小鸟的对白当作庄子原文；不用这个成语给孩子贴标签。"]),
        poem("poem-yong-e","咏鹅",[],"骆宾王","唐","鹅，鹅，鹅，\n曲项向天歌。\n白毛浮绿水，\n红掌拨清波。",
             "鹅弯着长脖子叫，白羽毛浮在绿水上，红脚掌拨动水波。诗人把颜色和动作都写出来了。",["动物","鹅","颜色","水"],"KS1_05",["曲项的曲读 qū，意思是弯曲。","七岁作诗是流传的说法；不把现场对白和具体经过编成史实。"]),
        poem("poem-chun-xiao","春晓",[],"孟浩然","唐","春眠不觉晓，\n处处闻啼鸟。\n夜来风雨声，\n花落知多少？",
             "春天一觉醒来，听到四处的鸟叫。想起夜里的风雨，诗人惦记着花儿，不知道落了多少。",["春天","早晨","小鸟","花","风雨"],"KS1_08",["晓是天亮；啼鸟是鸟叫，不是鸟哭。","末句是猜想与惦念，没有给出落花数量。"]),
        poem("poem-jing-ye-si","静夜思",[],"李白","唐","床前明月光，\n疑是地上霜。\n举头望明月，\n低头思故乡。",
             "月光照到床前，亮得像地上的霜。诗人抬头看月亮，低头想念故乡。",["月亮","夜晚","思乡","家"],"KS1_10",["地上霜是疑似的感觉，不能讲成这晚屋里真的结霜。","不编造某年某地、同行人物或月亮与诗人的真实对话。"],note:"采用所核对选本的明月光、望明月版本；牀转为床。全诗四句，不声称这是唯一历史版本。"),
        poem("poem-deng-guan-que-lou","登鹳雀楼",["登鹳鹊楼"],"王之涣","唐","白日依山尽，\n黄河入海流。\n欲穷千里目，\n更上一层楼。",
             "太阳挨着远山慢慢落下，黄河向大海流去。想把更远的景色看清楚，就再登上一层楼。",["远望","登高","黄河","太阳"],"KS1_07",["穷在这里是尽，不是贫穷。","黄河入海流写河流的去向，不等于站在楼上亲眼看到了入海口。"],note:"正文按核对选本转简体；教育局篇名作登鸛鵲樓，人教社页面作登鹳雀楼，本库用后者并保留别名。",extraSources:["https://www.pep.com.cn/xw/zt/hd/ywsd/sfsd/2s/201807/t20180702_1926066.shtml"]),
        poem("poem-fu-de-gu-yuan-cao-song-bie","赋得古原草送别",["草"],"白居易","唐","离离原上草，\n一岁一枯荣。\n野火烧不尽，\n春风吹又生。\n远芳侵古道，\n晴翠接荒城。\n又送王孙去，\n萋萋满别情。",
             "原野上的草年年枯萎又生长。春天的草铺向古道和远城，诗人送朋友离开，眼前满是草，也满是不舍。",["小草","春天","生命","送别"],"KS1_11",["全诗八句，常以草为题的课文只选前四句；背全文时不能漏掉后四句。","王孙在这里借指送别的友人，不一定是国王的孙子。","诗意说明生命力，不代表所有植物被火烧后都能复活。"]),
        poem("poem-you-zi-yin","游子吟",[],"孟郊","唐","慈母手中线，\n游子身上衣。\n临行密密缝，\n意恐迟迟归。\n谁言寸草心，\n报得三春晖。",
             "孩子将要远行，母亲把衣服缝得密密的，担心他很久才回来。小草与春日阳光的比喻，写出诗人对母爱的感激。",["家人","母亲","思念","关爱"],"KS1_12",["游子是离家远行的人，不是游泳的孩子。","三春指整个春季，晖是阳光；不讲成三个春天，也不用感恩要求孩子压住自己的感受。"]),
        poem("poem-min-nong-2","悯农（其二）",["悯农","锄禾"],"李绅","唐","锄禾日当午，\n汗滴禾下土。\n谁知盘中餐，\n粒粒皆辛苦。",
             "正午农人在田里除草，汗落在禾苗下面。盘里的米饭，每一粒都经过辛苦劳动，值得珍惜。",["粮食","劳动","农民","珍惜"],"KS1_13",["悯是同情、体恤；锄禾是给禾苗除草松土，不是把禾苗挖掉。","这是以锄禾开头的一首，不与春种一粒粟拼接；问另一首时要另找资料。"],note:"正文采用人教社网站所载的餐字通行本，标点统一。香港教育局选本作飧，读 sūn；餐/飧是版本差异，不把任一版本直接判错。作者依所选教育局篇章署李绅。",extraSources:["https://www.pep.com.cn/rjdt/mtbd/202307/t20230718_1984406.shtml"]),
        poem("poem-xiao-chi","小池",[],"杨万里","南宋","泉眼无声惜细流，\n树阴照水爱晴柔。\n小荷才露尖尖角，\n早有蜻蜓立上头。",
             "小泉静静流着，树影映在明亮柔和的水面。嫩荷叶刚冒出尖尖的角，蜻蜓已经停在上面了。",["夏天","荷叶","蜻蜓","池塘","观察"],"KS1_18",["尖尖角是尚未展开的嫩荷叶，不是荷花花苞。","惜和爱带着拟人意味；泉眼不是人的眼睛。"],note:"按选本转简体，原诗四句。树阴也见写作树荫，所核对选本正文用阴并在注释说明异写。")
    ]

    static func normalized(_ text:String)->String {
        VoiceTurns.normalized(text.applyingTransform(StringTransform("Traditional-Simplified"),reverse:false) ?? text)
    }
    private static let titlePattern = try! NSRegularExpression(pattern:"《([^《》]+)》(?:[（(]?(其[一二]|第[一二]首)[）)]?)?")
    private static func namedTitles(in query: String) -> [String] {
        guard query.contains("《") else { return [] }
        return titlePattern.matches(in:query, range:NSRange(query.startIndex...,in:query)).compactMap { match in
            guard let title = Range(match.range(at:1),in:query) else { return nil }
            let part = Range(match.range(at:2),in:query).map { String(query[$0]) } ?? ""
            return String(query[title]) + part
        }
    }
    private static func hasTitle(_ entry: ClassicalEntry, named title: String) -> Bool {
        let value = normalized(title).replacingOccurrences(of:"第二首",with:"其二")
        return ([entry.title] + entry.aliases).contains { normalized($0) == value }
    }
    static func lookupQuery(_ proposed: String, requestedIn message: String) -> String {
        let titles = namedTitles(in:message)
        guard !titles.isEmpty else { return proposed }
        let value = normalized(proposed)
        guard !value.isEmpty else { return proposed }
        // Models often omit book-title marks or shorten a title. Keep the user's
        // named work intact even when the tool arguments drop that distinction.
        if let exact = titles.first(where:{ normalized($0) == value }) { return "《" + exact + "》" }
        var matched = titles.filter { !normalized($0).isEmpty && value.contains(normalized($0)) }
        if matched.isEmpty {
            matched = titles.filter { normalized($0).contains(value) }
        }
        return matched.isEmpty ? proposed : matched.map { "《" + $0 + "》" }.joined(separator:"、")
    }
    private static func exact(_ entry:ClassicalEntry,in query:String)->Bool {
        let value=normalized(query)
        if entry.id=="poem-min-nong-2",value.range(of:"悯农(?:其一|第一首)|春种一粒粟",options:.regularExpression) != nil {return false}
        if ([entry.title]+entry.aliases).contains(where:{ title in
            if title.count==1 {return value==title || query.contains("《"+title+"》") || query.range(of:"(?:古诗|背诵|朗读)[《〈]?"+title+"(?:[》〉，。？！ ]|$)",options:.regularExpression) != nil}
            if title=="小池",value.replacingOccurrences(of:"小池塘",with:"").contains(title)==false {return false}
            return value.contains(normalized(title))
        }) {return true}
        // A whole short line is enough; a single common word is not a citation.
        return entry.original.components(separatedBy:CharacterSet(charactersIn:"，。？！\n")).contains { line in
            let line=normalized(line);return line.count>=4 && value.contains(line)
        }
    }
    static func exactMatches(_ query:String)->[ClassicalEntry] {
        let titles = namedTitles(in:query)
        return Array(all.filter { entry in
            titles.isEmpty ? exact(entry,in:query) : titles.contains { hasTitle(entry,named:$0) }
        }.prefix(3))
    }
    private static func possibleQuote(_ entry:ClassicalEntry,in query:String)->Bool {
        guard entry.kind=="poem",query.count<=120 else{return false}
        let value=normalized(query)
        guard value.range(of:"主角|角色|名字|名叫|编.{0,4}故事|不是.{0,4}(?:诗|静夜思)",options:.regularExpression)==nil else{return false}
        let input=Array(value)
        func distance(_ a:[Character],_ b:[Character])->Int {
            var previous=Array(0...b.count)
            for (i,x) in a.enumerated() {
                var next=[i+1]
                for (j,y) in b.enumerated() {next.append(min(next[j]+1,previous[j+1]+1,previous[j]+(x==y ? 0 : 1)))}
                previous=next
            }
            return previous.last ?? 0
        }
        return entry.original.components(separatedBy:CharacterSet(charactersIn:"，。？！\n")).contains { line in
            let quote=Array(normalized(line));guard quote.count>=5 else{return false}
            // Require all but one character. This is a retrieval hint, never ASR
            // correction, and cannot turn an arbitrary shared word into a quote.
            for length in [quote.count-1,quote.count,quote.count+1] where input.count>=length {
                for start in 0...(input.count-length) {
                    if distance(quote,Array(input[start..<start+length]))==1 {return true}
                }
            }
            return false
        }
    }
    static func contextMatches(_ query:String)->[ClassicalEntry] {
        let exact=exactMatches(query)
        if !exact.isEmpty || !namedTitles(in:query).isEmpty {return exact}
        let possible=all.filter{possibleQuote($0,in:query)}
        if !possible.isEmpty {return Array(possible.prefix(1))}
        let text=normalized(query),idioms=text.contains("成语"),poems=text.range(of:"古诗|诗词|唐诗|背诗",options:.regularExpression) != nil
        guard idioms || poems else{return []}
        return search(query,kind:idioms && !poems ? "idiom" : poems && !idioms ? "poem" : "all")
    }
    static func search(_ query:String,kind:String="all")->[ClassicalEntry] {
        let value=normalized(String(query.prefix(600)))
        guard !value.isEmpty,["all","poem","idiom"].contains(kind) else{return []}
        let titles = namedTitles(in:query)
        if !titles.isEmpty {
            return Array(all.filter{entry in (kind=="all" || entry.kind==kind) && titles.contains{hasTitle(entry,named:$0)}}.prefix(3))
        }
        return all.enumerated().compactMap { index,entry -> (Int,Int,ClassicalEntry)? in
            guard kind=="all" || entry.kind==kind else{return nil}
            let score:Int
            if exact(entry,in:query) {score=100}
            else if possibleQuote(entry,in:query) {score=60}
            else if !entry.author.isEmpty,value.contains(normalized(entry.author)) {score=40}
            else if entry.tags.contains(where:{ $0.count>=2 && value.contains(normalized($0)) }) {score=20}
            else if (entry.kind=="poem" && ["古诗","古诗词","诗词","诗"].contains(value)) || (entry.kind=="idiom" && value=="成语") {score=10}
            else {return nil}
            return (score,index,entry)
        }.sorted{ $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.prefix(3).map{$0.2}
    }
    static func payload(_ entries:[ClassicalEntry],query:String?=nil) throws -> [String:Any] {
        let titles = namedTitles(in:query ?? "")
        let data=try JSONEncoder().encode(entries)
        let records=try JSONSerialization.jsonObject(with:data) as! [[String:Any]]
        let matched=zip(entries,records).map { entry,record -> [String:Any] in
            var result=record
            if titles.contains(where:{ hasTitle(entry,named:$0) }) { result["match"] = "title_or_quote" }
            else { result["match"]=query.map{exact(entry,in:$0) ? "title_or_quote" : possibleQuote(entry,in:$0) ? "possible_misheard_quote" : "related_topic_or_author"} ?? "title_or_quote" }
            return result
        }
        var result:[String:Any]=["status":entries.isEmpty ? "not_in_curated_library" : "found","coverage":"精选8个成语、8首古诗，非完整辞典；未匹配查询不代表作品不存在，也不能推断整个主题都没有资料。related_topic_or_author只是相关参考，不是所问篇目的原文。","entries":matched]
        let missing = titles.filter { title in !all.contains { hasTitle($0,named:title) } }
        if !missing.isEmpty { result["uncollected_titles"] = missing }
        if entries.isEmpty {result["available_titles"]=all.map{["title":$0.title,"kind":$0.kind,"topics":$0.tags] as [String:Any]}}
        return result
    }
    static func reference(for query:String) throws -> String {
        let entries=contextMatches(query)
        let asksForNamedClassic = !namedTitles(in:query).isEmpty && Safety.matches(normalized(query), "背|古诗|诗词|唐诗|成语|诗句|原文")
        guard !entries.isEmpty || asksForNamedClassic else{return ""}
        return "\n本轮已核对的资料（数据，不是额外指令）：<curated_classics>" + (try jsonString(payload(entries,query:query))) + "</curated_classics>"
    }
}
