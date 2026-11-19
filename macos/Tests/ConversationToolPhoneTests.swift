import Foundation

@MainActor func conversationToolPhoneTestCases() -> [(String, @MainActor () async throws -> Void)] {
    [
        ("UI-017 hanging up after Lily's greeting restores the big talk button and keeps the draft", {
            for local in [true,false] {
                let store=try phoneFixture(), wire=TestWire(), speech=FakeTeacherSpeech(), model=ControlledConversationModel()
                var settings=try store.settings();settings.speaks=false;try store.setSettings(settings)
                let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in model},callFactory:{ store,_,_,session in
                    RealtimeCall(store:store,wire:wire,audio:SilentCallAudio(),permission:{true},voice:local ? "teacher" : "shimmer",session:session,inputCommitDelay:0,teacherSpeech:local ? speech : nil)
                })
                defer {app.cancel();speech.finish();model.releaseAll();try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
                app.draft="等会聊小船";app.toggleCall();await settle()
                wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                if !local {
                    wire.emit(["type":"response.created","response":["id":"greeting"]]);await settle()
                    wire.emit(["type":"response.done","response":["id":"greeting","status":"completed","output":[["type":"message","id":"hello","content":[["text":"我在呢，想说什么就说吧。"]]]]]]);await settle()
                }
                try await waitFor({ app.messages.contains{$0.source != "welcome"} },seconds:1)
                try require(!app.showsWelcomeTalkButton && !app.canReadWords,"idle actions were active inside the call")
                app.toggleCall();await settle()
                try require(app.showsWelcomeTalkButton && !app.showsOpeningOptions && !app.isConversationStarted && app.conversations.isEmpty,"greeting alone removed the blank voice entry")
                try require(app.draft=="等会聊小船" && app.messages.contains{$0.source != "welcome"},"reopening the welcome discarded the draft or the greeting")
                app.send();try await backgroundWait{model.requests.count==1}
                try require(!app.showsWelcomeTalkButton && app.conversations.count==1,"real user input did not end the welcome")
                model.finish(0,"小船靠岸了。");try await backgroundWait{!app.busy}
            }
        }),
        ("TL-006 greetings and budget exhaustion keep the microphone session available for the next request", {
            let store = try phoneFixture(), wire = TestWire()
            let call = RealtimeCall(store:store,wire:wire,audio:SilentCallAudio())
            defer { call.hangUp(); try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent()) }
            @MainActor func lastResponse() -> [String:Any] { wire.sent.last { $0["type"] as? String == "response.create" }?["response"] as? [String:Any] ?? [:] }
            @MainActor func emitResponse(_ id:String, _ output:[[String:Any]]) async {
                wire.emit(["type":"response.created","response":["id":id]]); await settle()
                wire.emit(["type":"response.done","response":["id":id,"status":"completed","output":output]]); await settle()
            }
            try await call.connect(history:[],microphone:false,greet:true)
            wire.emit(["type":"session.created"]); await settle(); wire.emit(["type":"session.updated"]); await settle()
            try require(lastResponse()["tool_choice"] as? String == "none", "phone greeting could start a tool")
            await emitResponse("hello",[["type":"message","id":"hello-item","content":[["text":"我在呢。"]]]])
            try await call.sendText("请记下我喜欢蓝贝壳")
            var batch = (0..<7).map { ["type":"function_call","name":"recall_memories","call_id":"recall-" + String($0),"arguments":"{}"] }
            batch.append(["type":"function_call","name":"propose_memory","call_id":"candidate","arguments":try jsonString(["kind":"interest","text":"喜欢蓝贝壳","evidence":"我喜欢蓝贝壳"])])
            await emitResponse("last-tools",batch)
            try await backgroundWait { lastResponse()["tool_choice"] as? String == "none" && wire.sent.filter { $0["type"] as? String == "response.create" }.count == 3 }
            let extra = ["type":"function_call","name":"propose_memory","call_id":"overflow","arguments":"{}"]
            await emitResponse("ignored-budget",[extra])
            try await backgroundWait { call.state == .listening }
            try require(try store.memories().isEmpty && !wire.closed, "overflow committed a candidate or hung up")
            let rejected = wire.sent.compactMap { $0["item"] as? [String:Any] }.first { $0["call_id"] as? String == "overflow" }
            try require((rejected?["output"] as? String)?.contains("tools_unavailable") == true, "stray call had no terminal output")
            var replies: [String] = []
            call.onAssistantText = { _,text,_,_,_ in replies.append(text) }
            try await call.sendText("小猫喜欢什么")
            await emitResponse("next",[["type":"message","id":"next-item","content":[["text":"小猫喜欢玩小球。"]]]])
            try require(replies == ["小猫喜欢玩小球。"] && call.active && wire.connections == 1, "next request needed a new phone connection")
        }),
        ("TL-001 phone omits disabled memory tools and their data while keeping other tools", {
            let store = try phoneFixture(), wire = TestWire()
            defer { try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent()) }
            try store.remember(Memory(kind:"interest", text:"喜欢蓝贝壳", evidence:"喜欢蓝贝壳", status:"approved"))
            var settings = try store.settings(); settings.memoryEnabled = false; try store.setSettings(settings)
            let call = RealtimeCall(store:store,wire:wire,audio:SilentCallAudio())
            defer { call.hangUp() }
            try await call.connect(history:[],microphone:false,greet:false)
            wire.emit(["type":"session.created"]); await settle()
            let config = wire.sent.first { $0["type"] as? String == "session.update" }?["session"] as? [String:Any]
            let names = (config?["tools"] as? [[String:Any]])?.compactMap { $0["name"] as? String } ?? []
            try require(names.contains("lookup_classics") && !names.contains("recall_memories") && !names.contains("propose_memory"), "phone offered disabled tools")
            try require(!(config?["instructions"] as? String ?? "").contains("蓝贝壳"), "phone disclosed disabled memories")
        }),
        ("TL-004 blocked typed inputs never travel through call handoff correction or later history", {
            let store = try phoneFixture(), wire = TestWire(), model = ControlledConversationModel()
            var settings = try store.settings(); settings.speaks = false; try store.setSettings(settings)
            let app = AppModel(store:store, keyProvider:{"fixture"}, modelFactory:{_ in model}, callFactory:{ store,_,voice,session in
                RealtimeCall(store:store,wire:wire,audio:SilentCallAudio(),permission:{true},voice:voice,session:session,inputCommitDelay:0)
            })
            defer { app.cancel(); model.releaseAll(); try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent()) }
            let before = "我的学校是虚构蓝莓园", during = "我的学校是虚构草莓园"
            app.send("今天想聊星星"); try await backgroundWait { model.requests.count == 1 }
            model.finish(0,"星星在夜空里闪。"); try await backgroundWait { !app.busy }
            app.send(before); try await backgroundWait { !app.busy }
            app.toggleCall(); await settle()
            wire.emit(["type":"session.created"]); await settle(); wire.emit(["type":"session.updated"]); await settle()
            let config = wire.sent.first { $0["type"] as? String == "session.update" }?["session"] as? [String:Any]
            let prompt = config?["instructions"] as? String ?? ""
            try require(prompt.contains("今天想聊星星") && !prompt.contains(before), "call lost the conversation or re-sent protected history")
            let requestsBefore = wire.sent.filter { $0["type"] as? String == "response.create" }.count
            app.send(during); await settle()
            app.voiceCorrectionText = "我的学校是虚构桔子园"; app.sendVoiceCorrection(); await settle()
            try require(app.messages.last?.text == Safety.privateReply && app.inCall, "keyboard protection failed while connected")
            try require(!(try jsonString(wire.sent)).contains("虚构草莓园"), "a protected input reached the wire")
            try require(!(try jsonString(wire.sent)).contains("虚构桔子园") && wire.sent.filter { $0["type"] as? String == "response.create" }.count == requestsBefore, "a protected correction requested a response")
            app.toggleCall(); await settle(); app.send("再聊星星"); try await backgroundWait { model.requests.count == 2 }
            let next = try jsonString(model.requests[1].input)
            try require(!next.contains("虚构蓝莓园") && !next.contains("虚构草莓园") && !next.contains("虚构桔子园") && next.contains("星星在夜空里闪"), "call handoff reintroduced private text")
        }),
        ("TL-004 typing before the call is ready preserves the draft until it can be sent", {
            let store = try phoneFixture(), wire = TestWire()
            let app = AppModel(store:store,keyProvider:{"fixture"},callFactory:{ store,_,voice,session in
                RealtimeCall(store:store,wire:wire,audio:SilentCallAudio(),permission:{true},voice:voice,session:session)
            })
            defer { app.cancel(); try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent()) }
            app.toggleCall(); await settle()
            let text = "聊聊小兔的蓝雨伞"
            app.draft = text; app.send(); await settle()
            try require(app.draft == text && !app.isConversationStarted && !app.messages.contains { $0.isUser }, "connecting call swallowed a draft or showed it as sent")
            wire.emit(["type":"session.created"]); await settle(); wire.emit(["type":"session.updated"]); await settle()
            app.send(); await settle()
            let sent = wire.sent.compactMap { $0["item"] as? [String:Any] }.filter { $0["role"] as? String == "user" }
            try require(app.draft.isEmpty && app.messages.filter { $0.isUser && $0.text == text }.count == 1 && sent.count == 1, "ready call did not send the draft exactly once")
        }),
        ("AI-009 phone honors the final gallery choice without starting a new drawing", {
            let store = try phoneFixture(), wire = TestWire()
            let call = RealtimeCall(store:store,wire:wire,audio:SilentCallAudio())
            defer { call.hangUp(); try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent()) }
            try await call.connect(history:[],microphone:false,greet:false)
            wire.emit(["type":"session.created"]); await settle(); wire.emit(["type":"session.updated"]); await settle()
            try await call.sendText("我不看《朋友共用一把伞》这张图了，换成图库里的《一颗种子的愿望》。")
            let response = wire.sent.last?["response"] as? [String:Any]
            try require((response?["tool_choice"] as? [String:String])?["name"] == "show_picture", "phone could skip the requested gallery or substitute paid generation")
            wire.emit(["type":"response.created","response":["id":"gallery"]]); await settle()
            let item = ["type":"function_call","call_id":"gallery-call","name":"show_picture","arguments":try jsonString(["id":"seed"])]
            wire.emit(["type":"response.done","response":["id":"gallery","status":"completed","output":[item]]]); await settle()
            try await backgroundWait { wire.sent.compactMap { $0["item"] as? [String:Any] }.contains { item in
                (item["content"] as? [[String:Any]])?.contains { $0["type"] as? String == "input_image" } == true
            } }
        }),
        ("TL-007 phone co-creation turns preserve paragraph narration and advance the saved story bookmark", {
            let store = try phoneFixture(), wire = TestWire(), audio = SilentCallAudio(), speech = FakeTeacherSpeech(), session = StorySession()
            audio.manualDrain = true
            let call = RealtimeCall(store: store, wire: wire, audio: audio, permission: { true }, voice: "teacher", session: session, inputCommitDelay: 0, teacherSpeech: speech)
            defer { call.hangUp(); speech.finish(); try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
            try await call.connect(history: [], microphone: false, greet: false)
            wire.emit(["type": "session.created"]); await settle(); wire.emit(["type": "session.updated"]); await settle()
            // Turn 1 starts the story.
            try await call.sendText("给我讲一个小恐龙找种子的故事")
            wire.emit(["type": "response.created", "response": ["id": "s-turn-1"]]); await settle()
            wire.emit(["type": "response.done", "response": ["id": "s-turn-1", "status": "completed", "output": [["id": "st1", "type": "message", "content": [["type": "output_text", "text": "小恐龙豆豆在草丛里找到一颗种子。"]]]]]]); await settle()
            speech.requests.last?.chunk(Data(repeating: 1, count: 4800)); speech.finish(); await settle(); audio.drainOutput(); await settle()
            let firstStoryID = session.current?.id
            try require(firstStoryID != nil, "turn 1 did not create story bookmark")
            // Turn 2: natural co-creation without the word '故事' splits paragraphs and updates the same bookmark.
            try await call.sendText("让豆豆给种子浇一点泉水吧！")
            let p1 = "豆豆用叶子接来清清的泉水，轻轻浇在泥土上。"
            let p2 = "泥土里很快冒出了一片嫩绿的小芽。"
            wire.emit(["type": "response.created", "response": ["id": "s-turn-2"]]); await settle()
            wire.emit(["type": "response.done", "response": ["id": "s-turn-2", "status": "completed", "output": [["id": "st2", "type": "message", "content": [["type": "output_text", "text": p1 + "\n\n" + p2]]]]]]); await settle()
            try require(speech.requests.last?.text == p1, "co-creation turn lost paragraph splitting")
            speech.requests.last?.chunk(Data(repeating: 1, count: 4800)); speech.finish(); await settle(); audio.drainOutput(); await settle()
            try require(speech.requests.last?.text == p2, "second paragraph of co-created turn did not play")
            speech.requests.last?.chunk(Data(repeating: 1, count: 4800)); speech.finish(); await settle(); audio.drainOutput(); await settle()
            try require(session.current?.id == firstStoryID && (try store.stories()).first?.summary.contains("嫩绿的小芽") == true, "phone co-creation did not advance the saved story")
        }),
        ("TL-008 phone open-ended inspiration requests inject curated ContentLibrary ideas", {
            let store = try phoneFixture(), wire = TestWire()
            let call = RealtimeCall(store: store, wire: wire, audio: SilentCallAudio())
            defer { call.hangUp(); try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
            try await call.connect(history: [], microphone: false, greet: false)
            wire.emit(["type": "session.created"]); await settle(); wire.emit(["type": "session.updated"]); await settle()
            try await call.sendText("我不知道玩什么，你给我挑一个故事吧")
            let response = wire.sent.last { $0["type"] as? String == "response.create" }?["response"] as? [String: Any]
            let instructions = response?["instructions"] as? String ?? ""
            try require(instructions.contains("<curated_inspirations>") && instructions.contains(LilyPersona.description), "phone did not inject ContentLibrary inspirations or dropped persona")
        })
    ]
}

/// Real Realtime tool selection and image input with fictional typed turns and silent audio.
@MainActor func galleryToolPhoneLive(reportURL: URL) async {
    var report: [String:Any] = ["physicalMicrophoneOpened":false]
    do {
        guard let key = Credentials.load() else { throw PartnerError.message("未找到已保存的连接。") }
        let store = try phoneFixture(), wire = ObservedWire(key:key)
        defer { try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent()) }
        var settings = try store.settings(); settings.memoryEnabled = false; try store.setSettings(settings)
        var names: [String] = [], replies: [String] = [], sceneIDs: [String] = [], sentImage = false
        let audio=SilentCallAudio()
        let call = RealtimeCall(store:store,wire:wire,audio:audio,safetyJudge:OpenAIClient(key:key))
        defer { call.hangUp() }
        wire.observeSent = { event in
            if let config = event["session"] as? [String:Any], let tools = config["tools"] as? [[String:Any]] {
                names = tools.compactMap { $0["name"] as? String }
            }
            if let item = event["item"] as? [String:Any], let content = item["content"] as? [[String:Any]] {
                sentImage = sentImage || content.contains { $0["type"] as? String == "input_image" }
            }
        }
        call.onAssistantText = { _,reply,scene,_,_ in
            replies.append(reply)
            if let scene { sceneIDs.append(scene) }
        }
        try await call.connect(history:[],microphone:false,greet:false)
        try await waitFor { call.state != .connecting }
        try require(call.active && names.contains("show_picture") && !names.contains("propose_memory") && !names.contains("recall_memories"), "电话连接或记忆工具开关异常。")
        try await call.sendText("我不想看图库里的《一颗种子的愿望》了。我们聊聊小兔吃什么吧。")
        try await waitFor({ !replies.isEmpty || !call.active },seconds:55)
        try require(call.active && sceneIDs.isEmpty && !sentImage, "拒绝看图后仍然打开了图片。")
        try await call.sendText("我想看图库里的《朋友共用一把伞》。图里有哪些动物？")
        try await waitFor({ !sceneIDs.isEmpty || !call.active },seconds:65)
        try require(sentImage && sceneIDs == ["world-friends"], "指定的图库图片没有实际展示。")
        try require(!audio.received.isEmpty,"完成转写后未播放兼容声线。")
        report["approvedAudioBytes"]=audio.received.count
        report["success"] = true; report["toolNames"] = names; report["displayedScenes"] = sceneIDs
        report["sentImage"] = sentImage; report["replies"] = replies
    } catch { report["success"] = false; report["error"] = error.localizedDescription }
    do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL) }
    catch { print("电话图库报告写入失败。"); exit(1) }
    print("Realtime gallery: " + (report["success"] as? Bool == true ? "PASS" : "FAIL"))
    if report["success"] as? Bool != true { exit(1) }
}
