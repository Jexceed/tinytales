import Foundation
import SQLite3

@MainActor private func settleDeletion(_ model:AppModel) async throws {
    for _ in 0..<100 { if !model.busy { return }; try await Task.sleep(nanoseconds:10_000_000) }
    throw PartnerError.message("TEST: conversation did not finish")
}
private final class LateDeletionModel:FakeModel {
    override func respond(input:[[String:Any]],instructions:String,tools:[[String:Any]],allowTools:Bool) async throws -> ModelOutput {
        await withCheckedContinuation { continuation in DispatchQueue.main.asyncAfter(deadline:.now()+0.08) {continuation.resume()} }
        return modern("不应复活的旧回复",state:"不应复活的旧故事",title:"旧故事")
    }
}
@MainActor func conversationDeletionTestCases() -> [(String,@MainActor () async throws -> Void)] {
    [
        ("CD-007 deletion regressions use a temporary artwork directory", {
            let directory=ArtworkArchive.directory.standardizedFileURL
            try expect(directory != AppResources.supportDirectory.appendingPathComponent("artwork").standardizedFileURL,"tests would erase production artwork")
            try expect(directory.lastPathComponent.hasPrefix("tinytales-test-artwork-"),"test artwork directory was not isolated at startup")
        }),
        ("CD-001 identical titles delete only the selected identity", {
            let store=try fixture();defer{remove(store)}
            let a=Story(id:"same-a",title:"新的小冒险",summary:"小兔去花园。"),b=Story(id:"same-b",title:"新的小冒险",summary:"小熊去河边。")
            try store.saveStory(a);try store.saveStory(b)
            let app=AppModel(store:store,keyProvider:{nil});let selected=app.selectedConversationID
            app.deleteConversation("archive:"+a.id)
            try expect(try store.stories().map(\.id) == [b.id],"same title deleted the wrong record")
            try expect(app.selectedConversationID == selected && app.conversations.count == 1,"deleting history selected another conversation")
        }),
        ("CD-002 deleting the current conversation cannot return from runtime caches", {
            let store=try fixture();defer{remove(store)}
            let a=Story(title:"要删除的小兔",summary:"小兔在花园。"),b=Story(title:"留下的小熊",summary:"小熊在河边。")
            try store.saveStory(a);try store.saveStory(b)
            let app=AppModel(store:store,keyProvider:{nil})
            app.draft="新对话里没发送的主意";app.selectConversation("archive:"+a.id)
            let deleted=app.selectedConversationID;app.draft="要删除的旧草稿"
            app.deleteConversation(deleted)
            try expect(!app.isConversationStarted && app.selectedConversationID != deleted && app.showsOpeningOptions == false,"deleted conversation stayed selected")
            try expect(app.draft == "新对话里没发送的主意","unrelated new workspace draft was lost")
            app.selectConversation(deleted);app.newConversation();app.refresh()
            try expect(!app.messages.contains{$0.text.contains("小兔在花园")} && !app.conversations.contains{$0.storyID == a.id},"cache resurrected deleted content")
            let reopened=try LocalStore(url:store.url)
            try expect(try reopened.stories().map(\.id) == [b.id],"deleted archive returned on restart")
        }),
        ("CD-003 deleting another conversation preserves selection drafts caches and sidebar order", {
            let store=try fixture();defer{remove(store)}
            let stories=[Story(id:"a",title:"小兔",summary:"小兔在花园。",updatedAt:"2020-01-03T00:00:00Z"),Story(id:"b",title:"小熊",summary:"小熊在河边。",updatedAt:"2020-01-02T00:00:00Z"),Story(id:"c",title:"小猫",summary:"小猫在树下。",updatedAt:"2020-01-01T00:00:00Z")]
            for story in stories {try store.saveStory(story)}
            let app=AppModel(store:store,keyProvider:{nil});app.selectConversation("archive:a");let a=app.selectedConversationID
            app.selectConversation("archive:b");let b=app.selectedConversationID;app.draft="给小熊的一句话"
            let order=app.conversations.map(\.navigationID),contents=app.messages.map(\.text),revision=store.revision
            app.deleteConversation(a)
            try expect(app.selectedConversationID == b && app.draft == "给小熊的一句话" && app.messages.map(\.text) == contents,"active conversation changed")
            try expect(app.conversations.map(\.navigationID) == order.filter{$0 != "archive:a"} && store.revision == revision,"other rows moved or global context was invalidated")
            app.selectConversation("archive:c");app.selectConversation(b)
            try expect(app.draft == "给小熊的一句话" && app.messages.map(\.text) == contents,"other conversation cache was erased")
        }),
        ("CD-003 deleting unrelated history does not cancel the current pending request", {
            let store=try fixture();defer{remove(store)}
            var settings=try store.settings();settings.speaks=false;try store.setSettings(settings)
            let old=Story(title:"旧故事",summary:"小兔看花。");try store.saveStory(old)
            let fake=FakeModel([finish("小鸟停在窗边。")]);fake.delay=80_000_000
            let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in fake})
            app.send("我看到一只小鸟");let active=app.selectedConversationID
            try await Task.sleep(nanoseconds:15_000_000);app.deleteConversation("archive:"+old.id)
            try await settleDeletion(app)
            try expect(app.selectedConversationID == active && app.error.isEmpty && app.messages.last?.text == "小鸟停在窗边。","history deletion interrupted the active request")
        }),
        ("CD-004 all exclusive stories and artwork in one conversation are removed without touching other data", {
            let store=try fixture();defer{remove(store)}
            var settings=try store.settings();settings.speaks=false;try store.setSettings(settings)
            let keep=Story(title:"保留的鲸鱼",summary:"鲸鱼在海里。");try store.saveStory(keep)
            try store.remember(Memory(kind:"interest",text:"喜欢恐龙",evidence:"我喜欢恐龙",status:"approved"))
            let fake=FakeModel([modern("小兔出发了。",state:"小兔去花园。",title:"小兔"),modern("海龟游向小岛。",state:"海龟去小岛。",title:"海龟")])
            let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in fake})
            app.send("讲个小兔的故事");try await settleDeletion(app)
            let a=app.storySession.current!
            app.send("换一个新的海龟故事");try await settleDeletion(app)
            let b=app.storySession.current!
            let arts=[a,b].map{StoryArtwork(storyID:$0.id,title:$0.title,storyText:$0.summary)}
            for art in arts {try ArtworkArchive.save(art,data:artworkFixtureData());app.messages.append(ChatMessage(isUser:false,text:"配图",artwork:art))}
            defer{for art in arts {ArtworkArchive.remove(art)}}
            app.deleteConversation(app.selectedConversationID)
            try expect(try store.stories().map(\.id) == [keep.id],"associated stories survived or unrelated story was deleted")
            try expect(arts.allSatisfy{!FileManager.default.fileExists(atPath:$0.url.path)},"exclusive picture survived")
            try expect(try store.memories().count == 1 && store.settings().speaks == false,"other local data changed")
        }),
        ("CD-004 deleting a source conversation preserves artwork still referenced by another chat", {
            let store=try fixture();defer{remove(store)}
            let story=Story(title:"共享画面",summary:"小兔在花园。");try store.saveStory(story)
            let art=StoryArtwork(storyID:story.id,title:story.title,storyText:story.summary)
            try ArtworkArchive.save(art,data:artworkFixtureData());defer{ArtworkArchive.remove(art)}
            let app=AppModel(store:store,keyProvider:{nil});app.selectConversation("archive:"+story.id)
            let source=app.selectedConversationID;app.messages.append(ChatMessage(isUser:false,text:"小兔的画",artwork:art))
            app.newConversation();app.recordUserMessageSent("也想看看这幅画")
            app.messages.append(ChatMessage(isUser:false,text:"同一幅画",artwork:art));let current=app.selectedConversationID
            app.deleteConversation(source)
            try expect(app.selectedConversationID == current && FileManager.default.fileExists(atPath:art.url.path),"referenced artwork was erased")
            try expect(try store.stories().isEmpty,"unshared source story returned as an archive row")
            app.deleteConversation(current)
            try expect(!FileManager.default.fileExists(atPath:art.url.path),"last owner deletion left orphan artwork")
        }),
        ("CD-005 deleting the current generating conversation discards uncooperative late results", {
            let store=try fixture();defer{remove(store)}
            var settings=try store.settings();settings.speaks=false;try store.setSettings(settings)
            let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in LateDeletionModel()})
            app.send("讲一个小故事");let deleted=app.selectedConversationID
            try await Task.sleep(nanoseconds:15_000_000);app.deleteConversation(deleted)
            try await Task.sleep(nanoseconds:160_000_000)
            try expect(!app.busy && !app.isConversationStarted && app.conversations.isEmpty,"deleted runtime conversation returned")
            try expect(!app.messages.contains{$0.text.contains("不应复活")} && (try store.stories()).isEmpty,"late output was published or saved")
        }),
        ("CD-006 unknown targets are harmless and deleted story identifiers cannot be saved again", {
            let store=try fixture();defer{remove(store)}
            let story=Story(title:"小兔",summary:"小兔在花园。");try store.saveStory(story)
            let app=AppModel(store:store,keyProvider:{nil});let order=app.conversations.map(\.navigationID)
            app.deleteConversation("not-a-conversation")
            try expect(app.conversations.map(\.navigationID) == order && app.error.isEmpty,"unknown target changed state")
            app.deleteConversation("archive:"+story.id)
            do {try store.saveStory(story);throw PartnerError.message("TEST: deleted story resurrected")}
            catch {try expect(!error.localizedDescription.contains("TEST:"),"late save accepted")}
        }),
        ("CD-006 failed multi-story deletion rolls back records and keeps visible state and pictures", {
            let store=try fixture();defer{remove(store)}
            let a=Story(id:"delete-a",title:"小兔",summary:"小兔在花园。"),b=Story(id:"delete-z",title:"小熊",summary:"小熊在河边。")
            try store.saveStory(a);try store.saveStory(b)
            let art=StoryArtwork(storyID:a.id,title:a.title,storyText:a.summary)
            try ArtworkArchive.save(art,data:artworkFixtureData());defer{ArtworkArchive.remove(art)}
            var db:OpaquePointer?;try expect(sqlite3_open(store.url.path,&db) == SQLITE_OK,"fixture database failed")
            defer{sqlite3_close(db)}
            try expect(sqlite3_exec(db,"CREATE TRIGGER block_test_delete BEFORE DELETE ON stories WHEN OLD.id='delete-z' BEGIN SELECT RAISE(ABORT,'fixture'); END;",nil,nil,nil) == SQLITE_OK,"fixture trigger failed")
            do {try store.deleteConversationStories([a.id,b.id]);throw PartnerError.message("TEST: transaction unexpectedly succeeded")}
            catch {try expect(!error.localizedDescription.contains("TEST:"),"failed transaction accepted")}
            try expect(try Set(store.stories().map(\.id)) == Set([a.id,b.id]),"partial deletion escaped rollback")
            try expect(FileManager.default.fileExists(atPath:art.url.path),"failed transaction deleted a picture")
            let app=AppModel(store:store,keyProvider:{nil});app.selectConversation("archive:"+b.id);let selected=app.selectedConversationID
            app.deleteConversation(selected)
            try expect(app.selectedConversationID == selected && app.isConversationStarted && !app.error.isEmpty,"failure removed visible conversation")
            try store.saveStory(a)
        })
    ]
}
