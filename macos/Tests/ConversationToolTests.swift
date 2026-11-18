import Foundation

@MainActor func conversationToolTestCases() -> [(String, @MainActor () async throws -> Void)] {
    [
        ("TL-006 using the last tool slot still permits a final reply without another action", {
            let store = try fixture(); defer { remove(store) }
            let model = FakeModel([tools((0..<8).map { _ in call("recall_memories") }), finish("我们聊聊小兔吧。")])
            let reply = try await CompanionEngine(store:store,model:model).turn("你记得什么？")
            try expect(model.toolPermissions == [true,false] && reply.reply.reply == "我们聊聊小兔吧。", "the model could start more work after exhausting its allowance")
        }),
        ("TL-001 disabled memory tools are absent and stale calls have no activity", {
            let store = try fixture(); defer { remove(store) }
            var settings = try store.settings()
            settings.memoryEnabled = false
            try store.setSettings(settings)
            let fake = FakeModel([tools([call("recall_memories"), call("propose_memory")]), finish("我们聊聊小猫吧。")])
            let reply = try await CompanionEngine(store: store, model: fake).turn("今天想聊小猫")
            try expect(fake.toolNames.count == 2 && fake.toolNames.allSatisfy { !$0.contains("propose_memory") && !$0.contains("recall_memories") && $0.contains("find_stories") }, "memory switch did not control the tool catalog")
            try expect(reply.activities.isEmpty && (try store.memories()).isEmpty, "disabled tools reported a memory action")
        }),
        ("TL-001 full and duplicate candidates leave the story and conversation usable", {
            let store = try fixture(); defer { remove(store) }
            for n in 0..<60 { try store.remember(Memory(kind: "word", text: "词语" + String(n), evidence: "练习词语")) }
            let args = ["kind":"word", "text":"贝壳", "evidence":"贝壳"]
            let fake = FakeModel([tools([call("propose_memory", args)]), modern("小兔拾起蓝贝壳。", state:"小兔拾起蓝贝壳。", title:"蓝贝壳")])
            let result = try await CompanionEngine(store:store, model:fake).turn("我们给贝壳编个故事吧。")
            try expect(result.reply.reply.contains("贝壳") && (try store.stories()).count == 1 && (try store.memories()).count == 60, "full memory lost a reply or a story")
            let toolkit = try PartnerTools(store:store, text:"练习词语")
            let duplicate = try toolkit.execute(name:"propose_memory", args:["kind":"word", "text":"词语0", "evidence":"练习词语"])
            try expect((duplicate.output as? [String:String])?["status"] == "already_recorded" && toolkit.stagedMemories.isEmpty, "duplicate claimed to create another candidate")
            try expect(!result.activities.contains { $0.contains("记忆") } && toolkit.activities.isEmpty, "an unwritten candidate reported success")
        }),
        ("TL-001 competing turns can fill the last memory slot before a story commits", {
            let store = try fixture(); defer { remove(store) }
            for n in 0..<59 { try store.remember(Memory(kind:"word", text:"词语" + String(n), evidence:"练习词语")) }
            let toolkit = try PartnerTools(store:store, text:"我喜欢贝壳")
            _ = try toolkit.execute(name:"propose_memory", args:["kind":"interest","text":"喜欢贝壳","evidence":"我喜欢贝壳"])
            _ = try toolkit.execute(name:"save_story", args:["fictional":true, "title":"蓝贝壳", "summary":"海獭捡到蓝贝壳。"])
            try store.remember(Memory(kind:"word", text:"月亮", evidence:"月亮"))
            try toolkit.commit(expectedRevision:store.revision)
            try expect((try store.stories()).count == 1 && !(try store.memories()).contains { $0.text == "喜欢贝壳" } && !toolkit.activities.contains { $0.contains("记忆") }, "late capacity change lost the story or claimed a memory write")
        }),
        ("TL-002 rejected word cards stay off screen and a corrected card completes the turn", {
            let store = try fixture(); defer { remove(store) }
            let valid = ["hanzi":"雨伞","pinyin":"yǔ sǎn","english":"umbrella"]
            var bad = [call("show_word", ["hanzi":"雨伞","pinyin":"card@example.invalid","english":"umbrella"])]
            for field in valid.keys {
                var empty = valid; empty[field] = "  "
                bad.append(call("show_word", empty))
            }
            let fake = FakeModel([tools(bad), tools([call("show_word", valid)]), finish("雨伞可以帮我们挡雨。")])
            let reply = try await CompanionEngine(store:store, model:fake).turn("给我看看雨伞的词卡。")
            let outputs = fake.inputs[1].filter { $0["type"] as? String == "function_call_output" }
            try expect(outputs.count == bad.count && outputs.allSatisfy { ($0["output"] as? String)?.contains("invalid_word_card") == true }, "malformed card was reported as shown")
            try expect(reply.word == WordCard(hanzi:"雨伞",pinyin:"yǔ sǎn",english:"umbrella") && reply.activities.count == 1, "corrected card did not reach the final reply")
        }),
        ("TL-003 artwork publication cannot commit unreviewed parallel tool writes", {
            let store = try fixture(); defer { remove(store) }
            let fake = FakeIllustrator([tools([
                call("save_story", ["title":"另一篇故事","summary":"小猫在窗边散步。","fictional":true]),
                call("illustrate_story"),
                call("propose_memory", ["kind":"interest","text":"喜欢火车","evidence":"喜欢火车"])
            ])])
            let result = try await CompanionEngine(store:store, model:fake).turn("我喜欢火车，整一张火车的画给我瞧瞧")
            guard let art = result.artwork else { throw PartnerError.message("TEST: no actual picture") }
            defer { ArtworkArchive.remove(art) }
            try expect(FileManager.default.fileExists(atPath:art.url.path) && result.activities.count == 1, "picture missing or an unrelated action reported")
            try expect((try store.stories()).isEmpty && (try store.memories()).isEmpty, "artwork bypassed the review of unrelated writes")
        }),
        ("TL-005 story lookup sees the latest correction before commit and never duplicates a book", {
            let store = try fixture(); defer { remove(store) }
            let old = Story(title:"小兔的红伞",summary:"小兔拿着红伞。")
            try store.saveStory(old)
            let session = StorySession(); session.current = old
            let toolkit = try PartnerTools(store:store, text:"把红伞改成蓝伞", session:session)
            _ = try toolkit.execute(name:"save_story", args:["id":old.id,"title":"小兔的蓝伞","summary":"小兔拿着蓝伞。","fictional":true])
            let read = try toolkit.execute(name:"read_story",args:["id":old.id]).output as? [String:String]
            let found = try toolkit.execute(name:"find_stories",args:["query":"蓝伞"]).output as? [[String:String]]
            let stale = try toolkit.execute(name:"find_stories",args:["query":"红伞"]).output as? [[String:String]]
            try expect(read?["summary"] == "小兔拿着蓝伞。" && found?.map { $0["id"] } == [old.id] && stale?.isEmpty == true, "lookup resurrected the old story")
            try expect(try store.stories() == [old] && session.current == old, "looking up a staged change wrote it before review")
        }),
        ("TL-007 co-created plot choices keep updating the active story bookmark while science questions do not overwrite it", {
            let store = try fixture(); defer { remove(store) }
            let session = StorySession()
            let t1 = try PartnerTools(store: store, text: "我们编一个小恐龙的故事", session: session)
            t1.prepareCheckpoint(PartnerReply(reply: "小恐龙豆豆走到小溪边。", suggestions: []))
            try t1.commit(expectedRevision: store.revision)
            let storyID = session.current?.id
            try expect(storyID != nil && (try store.stories()).count == 1, "initial story was not bookmarked")
            try expect(StoryIntent.continuesActiveStory("我们让豆豆去找种子吧",previous:session.current) && !StoryIntent.continuesActiveStory("我们明天去看牙",previous:session.current),"confused a shared plot choice with a personal plan")
            // Natural child co-creation without saying 'story' continues the same bookmark.
            let t2 = try PartnerTools(store: store, text: "让小恐龙用树枝搭一座小桥吧！", activeStory: storyID, session: session)
            t2.prepareCheckpoint(PartnerReply(reply: "豆豆搬来树枝搭好了小桥，走到了对岸。", suggestions: []))
            try t2.commit(expectedRevision: store.revision)
            try expect(session.current?.id == storyID && (try store.stories()).count == 1 && session.current?.summary.contains("搭好了小桥") == true, "co-created plot choice failed to update the story bookmark")
            // A real-world science question mid-session does not append science explanations into the fictional story.
            let t3 = try PartnerTools(store: store, text: "月亮为什么会发光？", activeStory: storyID, session: session)
            t3.prepareCheckpoint(PartnerReply(reply: "月亮反射太阳的光。", suggestions: []))
            try t3.commit(expectedRevision: store.revision)
            try expect(session.current?.summary.contains("反射太阳") == false, "science question polluted the fictional story bookmark")
        }),
        ("TL-008 open-ended inspiration prompts use bundled ContentLibrary and completed replies expose clickable suggestions", {
            let store = try fixture(); defer { remove(store) }
            var settings = PartnerSettings(); settings.speaks = false; try store.setSettings(settings)
            let replyWithSuggestions = ModelOutput(items: [], text: try jsonString(["reply": "我们一起给小熊编个故事吧。", "suggestions": ["去树屋看看", "找小萤火虫"], "narrative": true, "storyTitle": "小熊树屋", "storyState": "小熊坐在树屋里。"]))
            let nextReply = ModelOutput(items: [], text: try jsonString(["reply": "小熊推开树屋的木门。", "suggestions": [], "narrative": true, "storyTitle": "小熊树屋", "storyState": "小熊推开树屋木门。"]))
            let fake = FakeModel([replyWithSuggestions, nextReply])
            let app = AppModel(store: store, keyProvider: { "fixture" }, modelFactory: { _ in fake })
            app.send("我不知道聊什么，你帮我挑一个好玩的故事吧")
            try await backgroundWait { !app.busy }
            try expect(fake.prompts.first?.contains("<curated_inspirations>") == true, "open-ended inspiration request did not surface ContentLibrary ideas")
            try expect(ContentLibrary.inspirationReference(for: "讲小兔送苹果").isEmpty, "specific request unnecessarily injected random inspirations")
            try expect(app.activeSuggestions == ["去树屋看看", "找小萤火虫"], "completed assistant reply did not expose suggestions")
            app.chooseSuggestion("去树屋看看")
            try await backgroundWait { !app.busy && fake.inputs.count == 2 }
            try expect(app.messages.filter(\.isUser).map(\.text).last == "去树屋看看" && app.activeSuggestions.isEmpty, "choosing a suggestion did not advance the conversation")
        }),
        ("TL-009 pending memory count updates and simple approval preserves active conversations while edits reset context", {
            let store = try fixture(); defer { remove(store) }
            let model = ControlledConversationModel()
            var settings = PartnerSettings(); settings.speaks = false; try store.setSettings(settings)
            let app = AppModel(store: store, keyProvider: { "fixture" }, modelFactory: { _ in model })
            defer { app.newConversation(forgettingHistory: true); model.releaseAll() }
            var candidate = Memory(kind: "interest", text: "喜欢蓝色小火车", evidence: "我喜欢蓝色小火车")
            try store.remember(candidate); app.refresh()
            try expect(app.pendingCount == 1, "pending memory badge count missing")
            app.send("我们继续聊小海獭"); let activeID = app.selectedConversationID
            try await backgroundWait { model.requests.count == 1 }
            app.draft = "下一句想说的话"
            let revBefore = store.revision
            candidate.status = "approved"
            app.updateMemory(candidate)
            try expect(app.pendingCount == 0 && store.revision == revBefore, "simple approval did not clear pending badge or unexpectedly bumped revision")
            try expect(app.selectedConversationID == activeID && app.draft == "下一句想说的话" && app.conversations.first { $0.id == activeID }?.isGenerating == true, "approving a memory wiped active conversation or draft")
            model.finish(0, "小海獭浮上水面。")
            try await backgroundWait { !app.busy }
            // Editing an already approved memory's text DOES bump revision and resets conversations to prevent stale recall.
            candidate.text = "喜欢绿色小火车"
            app.updateMemory(candidate)
            try expect(store.revision > revBefore && !app.isConversationStarted, "editing memory text failed to reset stale conversation context")
        })
    ]
}
