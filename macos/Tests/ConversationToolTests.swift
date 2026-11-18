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
        })
    ]
}
