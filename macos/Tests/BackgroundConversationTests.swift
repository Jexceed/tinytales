import Foundation
import SQLite3

@MainActor func backgroundConversationTestCases() -> [(String,@MainActor () async throws -> Void)] {
    func setup() throws -> (LocalStore,ControlledConversationModel,AppModel) {
        let store=try fixture();var settings=PartnerSettings();settings.speaks=false;try store.setSettings(settings)
        let model=ControlledConversationModel(),app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in model})
        return (store,model,app)
    }
    func cleanup(_ store:LocalStore,_ model:ControlledConversationModel,_ app:AppModel) {
        app.newConversation(forgettingHistory:true);model.releaseAll();remove(store)
    }
    return [
        ("BG-001 switching and new conversation retain a single live stream and its final reply", {
            let (store,model,app)=try setup();defer{cleanup(store,model,app)}
            let archive=Story(title:"海湾贝壳",summary:"海獭在海湾里找到贝壳。")
            try store.saveStory(archive);app.refresh()
            app.send("陪小猫看彩虹");let original=app.selectedConversationID
            try await backgroundWait{model.requests.count == 1}
            try await model.emit(0,"小猫看到了彩虹。")
            let streamingID=app.messages.last!.id
            app.selectConversation("archive:"+archive.id);let other=app.selectedConversationID
            try await model.emit(0,"小猫看到了彩虹。它轻轻摇着尾巴。")
            try expect(app.selectedConversationID == other && app.messages.first?.text == archive.summary && !app.busy,"background stream changed the visible archive")
            try expect(app.conversations.first{$0.id == original}?.isGenerating == true,"pending row lost its progress")
            app.selectConversation(original)
            try expect(app.busy && app.messages.last?.id == streamingID && app.messages.last?.text.contains("尾巴") == true && app.messages.last?.isStreaming == true,"returning lost or restarted the partial reply")
            app.newConversation();let blank=app.selectedConversationID
            model.finish(0,"小猫看着彩虹，开心地摇着尾巴。")
            try await backgroundWait{app.conversations.first{$0.id == original}?.isGenerating == false}
            try expect(app.selectedConversationID == blank && !app.isConversationStarted && app.showsOpeningOptions,"background completion selected or started the empty workspace")
            try expect(app.conversations.first{$0.id == original}?.hasUnreadReply == true,"background reply has no unread state")
            app.selectConversation(original)
            try expect(app.messages.filter{!$0.isUser && $0.source != "welcome"}.count == 1 && app.messages.last?.id == streamingID && app.messages.last?.isStreaming == false,"final reply duplicated its stream bubble")
            try expect(app.conversations.first{$0.id == original}?.hasUnreadReply == false && model.requests.count == 1,"opening replayed the request or kept its unread badge")
        }),
        ("BG-002 concurrent conversations finish out of order without mixing context drafts or timestamps", {
            let (store,model,app)=try setup();defer{cleanup(store,model,app)}
            app.send("小兔想采蘑菇");let a=app.selectedConversationID,at=app.conversationUpdatedAt
            try await backgroundWait{model.requests.count == 1};app.draft="留给小兔的下一句话"
            app.newConversation();app.send("小熊想找贝壳");let b=app.selectedConversationID,bt=app.conversationUpdatedAt
            try await backgroundWait{model.requests.count == 2};app.draft="留给小熊的下一句话"
            let order=app.conversations.map(\.navigationID)
            for _ in 0..<3 {app.selectConversation(a);app.selectConversation(b)}
            model.finish(1,"小熊找到了白色贝壳。")
            try await backgroundWait{!app.busy}
            model.finish(0,"小兔采到了一朵蘑菇。")
            try await backgroundWait{app.conversations.first{$0.id == a}?.isGenerating == false}
            try expect(app.selectedConversationID == b && !app.messages.contains{$0.text.contains("蘑菇")} && app.draft == "留给小熊的下一句话" && app.conversationUpdatedAt == bt,"A overwrote B")
            app.selectConversation(a)
            try expect(app.messages.last?.text == "小兔采到了一朵蘑菇。" && app.draft == "留给小兔的下一句话" && app.conversationUpdatedAt == at,"A lost its own data")
            try expect(app.conversations.map(\.navigationID) == order && model.requests.count == 2,"completion moved rows or resubmitted requests")
            app.send("接着聊小兔");try await backgroundWait{model.requests.count == 3}
            let context=try jsonString(model.requests[2].input)
            try expect(context.contains("小兔采到了一朵蘑菇") && !context.contains("小熊") && !context.contains("贝壳"),"continuation used another engine's history")
            model.finish(2,"小兔把蘑菇放进篮子。")
            try await backgroundWait{!app.busy}
        }),
        ("BG-003 background story and artwork keep their original row story and image context", {
            let (store,model,app)=try setup();defer{cleanup(store,model,app)}
            app.send("讲一个小松鼠的故事");let a=app.selectedConversationID
            try await backgroundWait{model.requests.count == 1}
            app.newConversation();app.send("聊聊海边的贝壳");let b=app.selectedConversationID
            try await backgroundWait{model.requests.count == 2}
            let order=app.conversations.map(\.navigationID)
            model.finish(0,"小松鼠找到一片彩虹叶子。",title:"彩虹叶子",state:"小松鼠在森林里找到一片彩虹叶子。")
            try await backgroundWait{app.conversations.first{$0.id == a}?.isGenerating == false}
            try expect(app.conversations.count == 2 && app.conversations.map(\.navigationID) == order,"saved story became another sidebar row")
            app.selectConversation(a);let story=app.storySession.current!
            try expect(story.title == "彩虹叶子" && app.conversationTitle == story.title,"background story missed its source conversation")
            app.send("把这个故事画出来")
            try await backgroundWait{model.artworkRequests.count == 1}
            let request=model.artworkRequests[0].request
            try expect(request.story?.id == story.id && request.dialogue.contains{$0["text"]?.contains("彩虹叶子") == true} && !request.dialogue.contains{$0["text"]?.contains("贝壳") == true},"artwork used the visible conversation instead of its own history")
            app.selectConversation(b)
            model.finishArtwork(0,GeneratedArtwork(data:try artworkFixtureData(),caption:"小松鼠举着一片彩虹叶子。",source:story))
            try await backgroundWait{app.conversations.first{$0.id == a}?.isGenerating == false}
            try expect(app.busy && app.messages.allSatisfy{$0.artwork == nil},"background artwork interrupted or appeared in B")
            app.selectConversation(a)
            let art=app.messages.last?.artwork
            try expect(art?.storyID == story.id && art.map{FileManager.default.fileExists(atPath:$0.url.path)} == true,"image was lost while its conversation was hidden")
            try expect(app.conversations.map(\.navigationID) == order,"drawing changed the sidebar order")
            if let art {ArtworkArchive.remove(art)}
            model.finish(1,"贝壳有许多不同的形状。")
            try await backgroundWait{app.conversations.first{$0.id == b}?.isGenerating == false}
        }),
        ("BG-004 background failure remains local and retry preserves a later draft", {
            let (store,model,app)=try setup();defer{cleanup(store,model,app)}
            app.send("一起看看小花");let a=app.selectedConversationID
            try await backgroundWait{model.requests.count == 1};app.draft="下次想聊蜗牛"
            app.newConversation();app.send("一起看看星星");let b=app.selectedConversationID
            try await backgroundWait{model.requests.count == 2}
            model.fail(0)
            try await backgroundWait{app.conversations.first{$0.id == a}?.hasError == true}
            try expect(app.selectedConversationID == b && app.busy && app.error.isEmpty,"background error replaced B's active state")
            app.selectConversation(a)
            try expect(!app.busy && !app.error.isEmpty && app.draft == "下次想聊蜗牛","failure swallowed the error or overwrote a newer draft")
            app.send("再看看小花");try await backgroundWait{model.requests.count == 3}
            model.finish(2,"小花的花瓣轻轻展开。")
            try await backgroundWait{!app.busy}
            try expect(app.error.isEmpty && app.messages.last?.text == "小花的花瓣轻轻展开。","retry did not recover the failed conversation")
            model.finish(1,"星星在夜空中闪亮。")
            try await backgroundWait{app.conversations.first{$0.id == b}?.isGenerating == false}
        }),
        ("BG-005 explicit stop allows a new request while old uncooperative callbacks are ignored", {
            let (store,model,app)=try setup();defer{cleanup(store,model,app)}
            app.send("讲一个小猫的故事");let a=app.selectedConversationID
            try await backgroundWait{model.requests.count == 1}
            app.newConversation();app.send("聊聊小兔");let b=app.selectedConversationID
            try await backgroundWait{model.requests.count == 2}
            app.selectConversation(a);app.cancel();app.send("小猫改为看月亮")
            try await backgroundWait{model.requests.count == 3}
            do {try await model.emit(0,"过期的故事草稿。");throw PartnerError.message("TEST: cancelled callback accepted")}
            catch {try expect(!error.localizedDescription.contains("TEST:"),"late streaming callback was not invalidated")}
            model.finish(0,"不应保存的旧故事。",title:"旧故事",state:"小猫在旧故事里散步。")
            for _ in 0..<20 {await Task.yield()}
            try expect(app.busy && !app.messages.contains{$0.text.contains("旧故事")} && (try store.stories()).isEmpty,"old completion reset the new request or saved cancelled content")
            app.send("不能重叠发送");try expect(model.requests.count == 3,"same conversation accepted overlapping work")
            model.finish(2,"小猫望着圆圆的月亮。")
            try await backgroundWait{!app.busy}
            try expect(app.conversations.first{$0.id == b}?.isGenerating == true,"stopping A cancelled B")
            model.finish(1,"小兔正在花园里散步。")
            try await backgroundWait{app.conversations.first{$0.id == b}?.isGenerating == false}
        }),
        ("BG-005 stopping a request preserves its conversation time limit", {
            let store=try fixture();defer{remove(store)}
            var settings=PartnerSettings();settings.sessionMinutes=1;try store.setSettings(settings)
            var clock=Date();let model=ControlledConversationModel()
            let engine=CompanionEngine(store:store,model:model,now:{clock})
            let pending=Task{try await engine.turn("聊聊小猫")}
            try await backgroundWait{model.requests.count == 1}
            engine.interrupt();pending.cancel();model.finish(0,"过期的回复。")
            do {_=try await pending.value;throw PartnerError.message("TEST: stopped request completed")}
            catch {try expect(error is CancellationError,"stop did not cancel the in-flight turn")}
            clock=clock.addingTimeInterval(61)
            do {_=try await engine.turn("再聊聊小猫");throw PartnerError.message("TEST: stop reset the time limit")}
            catch {try expect(!error.localizedDescription.contains("TEST:"),"expired session resumed after stop")}
            try expect(model.requests.count == 1,"expired session made a new model request")
        }),
        ("BG-005 deleting a hidden active conversation prevents late saves without stopping others", {
            let (store,model,app)=try setup();defer{cleanup(store,model,app)}
            app.send("讲一个小猫的故事");let a=app.selectedConversationID
            try await backgroundWait{model.requests.count == 1}
            app.newConversation();app.send("聊聊小兔");let b=app.selectedConversationID
            try await backgroundWait{model.requests.count == 2}
            app.deleteConversation(a)
            model.finish(0,"已删除的小猫故事。",title:"小猫故事",state:"小猫捡到一颗红色石头。")
            model.finish(1,"小兔还在花园里。")
            try await backgroundWait{!app.busy}
            try expect(app.selectedConversationID == b && app.messages.last?.text == "小兔还在花园里。" && app.conversations.count == 1,"deleting A interrupted B or resurrected A")
            try expect(try store.stories().isEmpty,"deleted background task saved a late story")
        }),
        ("BG-005 a failed deletion leaves the background request running", {
            let (store,model,app)=try setup();defer{cleanup(store,model,app)}
            let story=Story(id:"blocked-delete",title:"花园里的小猫",summary:"小猫在花园里散步。")
            try store.saveStory(story);app.refresh();app.selectConversation("archive:"+story.id)
            app.send("继续这个故事");let a=app.selectedConversationID
            try await backgroundWait{model.requests.count == 1};app.newConversation()
            var db:OpaquePointer?;try expect(sqlite3_open(store.url.path,&db) == SQLITE_OK,"fixture db unavailable")
            defer{sqlite3_close(db)}
            try expect(sqlite3_exec(db,"CREATE TRIGGER reject_bg_delete BEFORE DELETE ON stories BEGIN SELECT RAISE(ABORT,'fixture'); END;",nil,nil,nil) == SQLITE_OK,"fixture trigger unavailable")
            app.deleteConversation(a)
            try expect(app.conversations.first{$0.id == a}?.isGenerating == true,"failed deletion cancelled its task")
            model.finish(0,"小猫找到一朵紫色小花。",title:story.title,state:"小猫在花园里找到一朵紫色小花。")
            try await backgroundWait{app.conversations.first{$0.id == a}?.isGenerating == false}
            app.selectConversation(a)
            try expect(app.messages.last?.text == "小猫找到一朵紫色小花。","failed deletion lost the result")
        }),
        ("BG-006 clearing data invalidates every task and ordinary chats never persist raw messages", {
            for external in [false,true] {
                let (store,model,app)=try setup();defer{cleanup(store,model,app)}
                app.send("今天想聊七色的纸风车");try await backgroundWait{model.requests.count == 1}
                app.newConversation();app.send("今天想聊会旋转的陀螺");try await backgroundWait{model.requests.count == 2}
                try expect(!String(decoding:try store.export(),as:UTF8.self).contains("七色的纸风车"),"background caching persisted raw dialogue")
                if external {try store.clear()} else {app.clearData()}
                model.finish(0,"旧风车故事。",title:"风车",state:"小兔转动一架风车。")
                model.finish(1,"旧陀螺故事。",title:"陀螺",state:"小猫转动一只陀螺。")
                try await backgroundWait{app.conversations.isEmpty && !app.busy}
                try expect(try store.stories().isEmpty,"invalidated task repopulated the database")
            }
        })
    ]
}
