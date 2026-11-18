import Foundation

@MainActor func classicalKnowledgeTestCases()->[(String,@MainActor () async throws -> Void)] {
    [
        ("CK-005 a short unique near verse is confirmed verbatim while a named character stays in the story", {
            let store=try fixture();defer{remove(store)}
            let model=FakeModel([]), result=try await CompanionEngine(store:store,model:model).turn("我说的是许头望明月。")
            try expect(result.source=="library" && result.reply.reply.contains("举头望明月") && result.reply.reply.hasSuffix("吗？") && model.inputs.isEmpty,"a unique verse candidate became an invented character")
            try expect(ClassicalKnowledge.shortQuoteConfirmation(for:"许头望明月",history:[["role":"user","content":"我的角色名字叫许头望明月"]])==nil,"an explicit character name was overridden")
        }),
        ("CK-008 each new work points to its checked edition and keeps its text and attribution together", {
            let idioms = ["狐假虎威":32, "对牛弹琴":47, "叶公好龙":486, "杯弓蛇影":49,
                          "水滴石穿":179, "百发百中":248, "熟能生巧":282, "愚公移山":267]
            let editions = ["悯农（其一）":2311980, "咏柳":12232790, "风":12232877, "江南":2648145,
                            "古朗月行（节选）":12232664, "敕勒歌":12232684, "江雪":2315191]
            var expected = idioms.mapValues { "https://dict.idioms.moe.edu.tw/idiomView.jsp?ID=\($0)&la=0&webMd=2" }
            for (title,revision) in editions { expected[title]="https://zh.wikisource.org/wiki/Special:PermanentLink/\(revision)" }
            expected["山村咏怀"]="https://www.thepaper.cn/newsDetail_forward_4984875"
            for (title,url) in expected {
                let entry=ClassicalKnowledge.all.first { $0.title==title }
                try expect(entry?.sources.first==url && entry?.checkedOn=="2026-11-18","wrong checked source for "+title)
            }
            let cup=ClassicalKnowledge.exactMatches("杯弓蛇影").first!
            try expect(cup.origin.contains("风俗通义") && cup.original.contains("北壁上有悬赤弩") && cup.storyOutline.contains("应郴") && cup.storyOutline.contains("杜宣") && !cup.storyOutline.contains("乐广"),"mixed the two accounts of the cup")
            try expect(ClassicalKnowledge.exactMatches("《山村咏怀》").first?.author.contains("未定")==true,"uncertain authorship was presented as settled")
        }),
        ("CK-006 a quoted title matches a complete work even alongside a known author or verse", {
            let unknown = "请背李白的《靜夜思續篇》，里面有床前明月光吗？"
            try expect(ClassicalKnowledge.search(unknown).isEmpty && ClassicalKnowledge.exactMatches(unknown).isEmpty, "an uncollected title inherited another poem")
            let reference = try ClassicalKnowledge.reference(for:unknown)
            try expect(reference.contains("not_in_curated_library") && !reference.contains("poem-jing-ye-si"), "automatic prompt attributed original text to another work")
            let mixed = "《靜夜思》和《小池边的风》都是古诗吗？"
            try expect(ClassicalKnowledge.contextMatches(mixed).map(\.id) == ["poem-jing-ye-si"] && (try ClassicalKnowledge.reference(for:mixed)).contains("小池边的风"), "mixed titles were silently conflated")
            try expect(ClassicalKnowledge.search("请背《草》").first?.author == "白居易" && (try ClassicalKnowledge.reference(for:"我们编个《小池边的风》的故事")).isEmpty, "a short alias or ordinary fictional title was misread")
        }),
        ("CK-006 a model lookup cannot shorten the user's uncollected title into a different poem", {
            let store = try fixture(); defer { remove(store) }
            let model = FakeModel([tools([call("lookup_classics",["query":"静夜思续篇","kind":"poem"]),call("lookup_classics",["query":"静夜思","kind":"poem"])]),modern("资料本还没收录《静夜思续篇》。",narrative:false)])
            _ = try await CompanionEngine(store:store,model:model).turn("请背《静夜思续篇》，我问的是这个完整篇名。")
            let outputs = model.inputs[1].compactMap { $0["output"] as? String }
            try expect(outputs.count == 2 && outputs.allSatisfy { $0.contains("not_in_curated_library") && $0.contains("静夜思续篇") && !$0.contains("床前明月光") }, "model-rewritten query returned the wrong poem")
            try expect(ClassicalKnowledge.lookupQuery("春天",requestedIn:"《静夜思》之外有哪些春天的诗？") == "春天", "an independent topic was forced into the previous title")
            try expect(ClassicalKnowledge.lookupQuery("静夜思续篇",requestedIn:"《静夜思》和《静夜思续篇》") == "《静夜思续篇》", "an exact follow-up returned both overlapping titles")
        }),
        ("CK-005 similar spoken poem is an uncertain candidate and never a replacement character",{
            let reference=try ClassicalKnowledge.reference(for:"我说的是许头望明月")
            try expect(reference.contains("possible_misheard_quote") && reference.contains("举头望明月"),"a likely misheard poem had no confirmation reference")
            try expect(!reference.contains("\"match\":\"title_or_quote\""),"a fuzzy candidate claimed an exact match")
            try expect(try ClassicalKnowledge.reference(for:"一是地上霜").contains("possible_misheard_quote"),"a homophone error became an invented character")
            for query in ["给我编个故事，主角叫许头望明月","不是诗句，是我编的名字许头望明月","今天给小兔画一幅图"] {
                try expect(try ClassicalKnowledge.reference(for:query).isEmpty,"ordinary fiction was forced into a poem")
            }
        }),
        ("CK-001 curated records preserve attribution editions and important distinctions",{
            let entries=ClassicalKnowledge.all
            try expect(entries.count==32 && Set(entries.map(\.id)).count==32,"missing or duplicate curated records")
            try expect(entries.filter{$0.kind=="idiom"}.count==16 && entries.filter{$0.kind=="poem"}.count==16,"curated catalogue is unbalanced")
            for entry in entries {
                try expect(!entry.original.isEmpty && !entry.origin.isEmpty && !entry.explanation.isEmpty && !entry.cautions.isEmpty && !entry.editionNote.isEmpty,"incomplete provenance or explanation for \(entry.id)")
                try expect(["2026-11-16","2026-11-18"].contains(entry.checkedOn) && !entry.sources.isEmpty && entry.sources.allSatisfy{URL(string:$0)?.scheme=="https"},"missing source or review date")
                if entry.kind=="poem" {try expect(!entry.author.isEmpty && !entry.era.isEmpty,"poem has no author or era")}
                else {try expect(!entry.pinyin.isEmpty && !entry.storyOutline.isEmpty && !entry.example.isEmpty,"idiom has no reading, origin story or child example")}
            }
            let grass=ClassicalKnowledge.exactMatches("《草》").first!
            try expect(grass.author=="白居易" && grass.original.components(separatedBy:"\n").count==8 && grass.original.hasSuffix("萋萋满别情。"),"the four-line excerpt was presented as the full poem")
            let bell=ClassicalKnowledge.exactMatches("掩耳盗铃").first!
            try expect(bell.origin.contains("吕氏春秋") && bell.storyOutline.contains("大钟") && bell.cautions.joined().contains("小铃铛"),"modern bell retelling replaced the documented original")
            let sheep=ClassicalKnowledge.exactMatches("亡羊补牢").first!
            try expect(sheep.origin=="《战国策·楚策四》" && sheep.storyOutline.contains("扩写"),"later dialogue was attributed to the original")
            let farmer=ClassicalKnowledge.exactMatches("锄禾").first!
            try expect(farmer.original.contains("盘中餐") && farmer.editionNote.contains("飧"),"a known variant was silently overwritten")
        }),
        ("CK-002 search distinguishes titles aliases quotations topics and absent works",{
            try expect(ClassicalKnowledge.search("請講揠苗助長",kind:"idiom").first?.id=="idiom-ya-miao-zhu-zhang","traditional title failed")
            try expect(ClassicalKnowledge.search("拔苗助长").first?.title=="揠苗助长","alias failed")
            try expect(ClassicalKnowledge.search("床前明月光是什么意思").first?.author=="李白","quotation failed")
            try expect(ClassicalKnowledge.search("关于春天的诗",kind:"poem").allSatisfy{$0.kind=="poem"},"type filtering failed")
            try expect(ClassicalKnowledge.search("关于春天的诗",kind:"poem").contains{$0.title=="春晓"},"topic lookup failed")
            try expect(ClassicalKnowledge.search("登鸛鵲樓").first?.title=="登鹳雀楼","title variant failed")
            for query in ["水调歌头","将进酒","请背《星星擦月亮》","","磁悬浮列车"] {
                try expect(ClassicalKnowledge.search(query).isEmpty,"uncollected work was replaced by another: \(query)")
            }
            try expect(ClassicalKnowledge.exactMatches("小草长在小池塘旁").isEmpty,"ordinary grass or pond mentions matched a poem title")
            try expect(try ClassicalKnowledge.reference(for:"今天有点开心").isEmpty,"ordinary conversation was flooded with source data")
        }),
        ("CK-007 expanded preschool poems and idioms distinguish Min-Nong parts single-char titles and excerpt boundaries",{
            for (query,expectedID) in [
                ("狐假虎威","idiom-hu-jia-hu-wei"),("对牛弹琴","idiom-dui-niu-tan-qin"),("叶公好龙","idiom-ye-gong-hao-long"),
                ("杯弓蛇影","idiom-bei-gong-she-ying"),("滴水穿石","idiom-shui-di-shi-chuan"),("百发百中","idiom-bai-fa-bai-zhong"),
                ("熟能生巧","idiom-shu-neng-sheng-qiao"),("愚公移山","idiom-yu-gong-yi-shan"),
                ("《悯农（其一）》","poem-min-nong-1"),("春种一粒粟","poem-min-nong-1"),
                ("《悯农（其二）》","poem-min-nong-2"),("锄禾日当午","poem-min-nong-2"),
                ("《咏柳》","poem-yong-liu"),("背诵古诗《风》","poem-feng"),("《江南》","poem-jiang-nan"),
                ("《古朗月行》","poem-gu-lang-yue-xing"),("一去二三里","poem-shan-cun-yong-huai"),
                ("敕勒歌","poem-chi-le-ge"),("独钓寒江雪","poem-jiang-xue")
            ] {
                let matches=ClassicalKnowledge.exactMatches(query)
                try expect(matches.contains{$0.id==expectedID},"expanded entry failed exact retrieval for \(query)")
            }
            let min1=ClassicalKnowledge.exactMatches("请背《悯农（第一首）》")
            let min2=ClassicalKnowledge.exactMatches("请背《悯农（第二首）》")
            try expect(min1.map(\.id)==["poem-min-nong-1"] && !min1[0].original.contains("锄禾"),"Min-Nong I leaked part II")
            try expect(min2.map(\.id)==["poem-min-nong-2"] && !min2[0].original.contains("春种"),"Min-Nong II leaked part I")
            try expect(ClassicalKnowledge.exactMatches("今天刮大风，风吹走了江南的云").isEmpty,"ordinary wind or place words falsely matched poems")
            let moon=ClassicalKnowledge.exactMatches("小时不识月").first!
            try expect(moon.cautions.joined().contains("十六句") && moon.editionNote.contains("节选"),"Gu Lang Yue Xing omitted its excerpt note")
        }),
        ("CK-003 typed requests receive exact references and shared lookup returns sourced data",{
            let store=try fixture();defer{remove(store)}
            let model=FakeModel([modern("《静夜思》是唐代李白写的。",narrative:false),modern("今天有什么开心的事？",narrative:false)])
            let engine=CompanionEngine(store:store,model:model)
            _ = try await engine.turn("静夜思是谁写的")
            try expect(model.prompts[0].contains("poem-jing-ye-si") && model.prompts[0].contains("床前明月光") && model.prompts[0].contains(ClassicalKnowledge.instructions),"the actual typed request lacked reference material or shared rules")
            _ = try await engine.turn("今天有点开心")
            try expect(!model.prompts[1].contains("<curated_classics>"),"last turn's reference was reused on an unrelated turn")
            let tools=try PartnerTools(store:store,text:"请给我讲一个成语")
            let found=try tools.execute(name:"lookup_classics",args:["query":"植物","kind":"idiom"]).output as! [String:Any]
            let records=found["entries"] as! [[String:Any]]
            try expect(found["status"] as? String=="found" && records.first?["title"] as? String=="揠苗助长" && records.first?["sources"] != nil,"shared tool omitted evidence")
            try expect(records.first?["match"] as? String=="related_topic_or_author","topic result was presented as an exact title match")
            let absent=try tools.execute(name:"lookup_classics",args:["query":"水调歌头","kind":"poem"]).output as! [String:Any]
            try expect(absent["status"] as? String=="not_in_curated_library" && (absent["entries"] as? [Any])?.isEmpty==true,"tool invented evidence for a missing work")
            try expect((absent["available_titles"] as? [[String:Any]])?.contains{$0["title"] as? String=="揠苗助长"}==true,"a failed keyword search hides the actual catalogue")
            try expect(tools.stagedStories.isEmpty && tools.stagedMemories.isEmpty,"knowledge lookup wrote stories or personal memory")
        }),
        ("CK-003 explicit classical topics are grounded without relying on model query wording",{
            let store=try fixture();defer{remove(store)}
            let model=FakeModel([modern("揠苗助长说的是用错办法催禾苗长高。",narrative:false)])
            _ = try await CompanionEngine(store:store,model:model).turn("讲一个关于植物的成语，先查你准备好的资料，不改编")
            try expect(model.prompts[0].contains("idiom-ya-miao-zhu-zhang") && model.prompts[0].contains("related_topic_or_author"),"a known theme depended on the model inventing the right search phrase")
            try expect(try ClassicalKnowledge.reference(for:"今天看到一种植物").isEmpty,"ordinary plant chat became a forced idiom lesson")
        }),
        ("CK-003 typed tool loop receives the same curated records before its final explanation",{
            let store=try fixture();defer{remove(store)}
            let model=FakeModel([tools([call("lookup_classics",["query":"春天","kind":"poem"])]),modern("《春晓》写了春天早晨的鸟声。",narrative:false)])
            _ = try await CompanionEngine(store:store,model:model).turn("讲一首春天的古诗")
            let output=model.inputs.last?.first{$0["type"] as? String=="function_call_output"}?["output"] as? String ?? ""
            try expect(output.contains("孟浩然") && output.contains("KS1_08.pdf") && output.contains("editionNote"),"the model never received the lookup result")
        })
    ]
}

/// Exercises the actual typed entry point with fictional/public-domain prompts.
/// No microphone, personal history, or credential contents are recorded.
final class ClassicalLiveModel:StreamingPartnerModel,ContentQualityReviewingModel {
    let client:OpenAIClient
    var calls:[[String:Any]]=[]
    var prompts:[String]=[]
    init(_ client:OpenAIClient) {self.client=client}
    private func observed(_ result:ModelOutput)->ModelOutput {
        calls += result.items.filter{$0["type"] as? String=="function_call"}
        return result
    }
    func moderate(_ text:String) async throws -> Bool {try await client.moderate(text)}
    func assessSafety(_ text:String,scope:SafetyReviewScope) async throws -> SafetyAssessment {try await client.assessSafety(text,scope:scope)}
    func reviewContent(user:String,previous:Story?,reply:PartnerReply) async throws -> ContentVerdict {try await client.reviewContent(user:user,previous:previous,reply:reply)}
    func respond(input:[[String:Any]],instructions:String,tools:[[String:Any]],allowTools:Bool) async throws -> ModelOutput {
        prompts.append(instructions)
        return observed(try await client.respond(input:input,instructions:instructions,tools:tools,allowTools:allowTools))
    }
    func respondStreaming(input:[[String:Any]],instructions:String,tools:[[String:Any]],allowTools:Bool,onReply:@escaping @MainActor (String) async throws -> Void) async throws -> ModelOutput {
        prompts.append(instructions)
        return observed(try await client.respondStreaming(input:input,instructions:instructions,tools:tools,allowTools:allowTools,onReply:onReply))
    }
}
@MainActor func classicalKnowledgeLive() async {
    do {
        guard let key=Credentials.load() else{throw PartnerError.message("Saved connection unavailable")}
        let client=OpenAIClient(key:key)
        let observed=ClassicalLiveModel(client)
        let cases:[(String,(String,[String])->Bool)] = [
            ("请完整背诵《静夜思》，先说作者，不用解释。",{text,_ in text.contains("李白") && ClassicalKnowledge.normalized(text).contains(ClassicalKnowledge.normalized(ClassicalKnowledge.exactMatches("静夜思")[0].original))}),
            ("《草》是只有四句吗？请把白居易《赋得古原草送别》的全文说给我听。",{text,_ in ClassicalKnowledge.normalized(text).contains(ClassicalKnowledge.normalized(ClassicalKnowledge.exactMatches("《草》")[0].original)) && text.range(of:"八句|8句|前四句|前4句",options:.regularExpression) != nil}),
            ("亡羊补牢中的牢是什么意思，出处是哪本书？不要编故事。",{text,_ in text.contains("战国策") && text.range(of:"羊圈|牲畜.{0,3}圈",options:.regularExpression) != nil}),
            ("原典掩耳盗铃里偷的是小铃铛吗？请说出处。",{text,_ in text.contains("钟") && text.contains("吕氏春秋")}),
            ("讲一个关于植物的成语，先查你准备好的资料，不改编。",{text,activities in text.contains("苗助长") && (activities.contains{$0.contains("资料本")} || observed.prompts.contains{$0.contains("idiom-ya-miao-zhu-zhang")})}),
            ("你收录了《星星擦月亮》这首古诗吗？能给我背原文吗？",{text,_ in text.range(of:"没有|没收录|未收录|没找到|没查到|没有核对|还没",options:.regularExpression) != nil}),
            ("我说的是许头望明月。",{text,_ in text.contains("举头望明月") && text.contains("静夜思") && text.range(of:"吗|是不是|是否|是指",options:.regularExpression) != nil}),
            ("一是地上霜。",{text,_ in text.contains("疑是地上霜") && text.contains("静夜思") && text.range(of:"吗|是不是|是否|是指",options:.regularExpression) != nil}),
            ("请背《静夜思续篇》，我问的是这个完整篇名。",{text,_ in !text.contains("床前明月光") && text.range(of:"没.{0,8}(?:收录|收进|找到|核对|查到)|未收录|还没",options:.regularExpression) != nil}),
            ("请背李绅的《悯农（其一）》，不要背锄禾日当午那一首。",{text,_ in
                let verse=ClassicalKnowledge.exactMatches("《悯农其一》")[0].original
                let answer=text.replacingOccurrences(of:#"(?:不是|不背)[“「『‘ ]*锄禾日当午[”」』’ ]*(?:那一首|那首)"#,with:"",options:.regularExpression)
                return ClassicalKnowledge.normalized(answer).contains(ClassicalKnowledge.normalized(verse)) && !Safety.matches(answer,"锄禾日当午|汗滴禾下土|谁知盘中|粒粒皆辛苦")
            }),
            ("资料本里《杯弓蛇影》的应劭版本，是谁请谁喝酒？只讲这个版本。",{text,_ in text.contains("应郴") && text.contains("杜宣")}),
            ("《山村咏怀》可以肯定是邵雍写的吗？请按资料本说明。",{text,_ in text.contains("邵雍") && text.range(of:"不能|不确定|待考|未定|没有.{0,8}证据|无法确定|有争议",options:.regularExpression) != nil})
        ]
        var records:[[String:Any]]=[]
        let selected=CommandLine.arguments.firstIndex(of:"--classics-case").flatMap { index in CommandLine.arguments.count>index+1 ? Int(CommandLine.arguments[index+1]) : nil }
        for (index,entry) in cases.enumerated() where selected==nil || selected==index {
            let (query,accept)=entry
            let store=try fixture();defer{remove(store)}
            observed.calls=[];observed.prompts=[]
            let started=Date(),engine=CompanionEngine(store:store,model:observed)
            do {
                let answer=try await engine.turn(query)
                let passed=accept(answer.reply.reply,answer.activities)
                records.append(["query":query,"reply":answer.reply.reply,"replySource":answer.source,"activities":answer.activities,"toolCalls":observed.calls,"automaticReferences":observed.prompts.first?.contains("<curated_classics>")==true,"passed":passed,"seconds":Date().timeIntervalSince(started)])
                print("Classics \(passed ? "PASS" : "FAIL"): \(query)")
            } catch {
                records.append(["query":query,"passed":false,"error":error.localizedDescription])
                print("Classics FAIL: \(error.localizedDescription)")
            }
        }
        let success=records.allSatisfy{$0["passed"] as? Bool==true}
        try JSONSerialization.data(withJSONObject:["success":success,"model":client.model,"physicalMicrophoneOpened":false,"cases":records],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/tmp/tinytales-classics-live.json"))
        if !success {exit(1)}
    } catch {print("Classics check failed: \(error.localizedDescription)");exit(1)}
}
