import Foundation

@MainActor func backgroundConversationPhoneTestCases() -> [(String,@MainActor () async throws -> Void)] {
    [("BG-007 background completion stays silent and cannot disturb another conversation's call", {
        let store=try phoneFixture(),model=ControlledConversationModel(),wire=TestWire(),audio=SilentCallAudio()
        var spoken:[String]=[]
        let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in model},callFactory:{store,_,voice,session in
            RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},voice:voice,session:session,inputCommitDelay:0)
        },replySpeaker:{spoken.append($0)})
        defer{app.newConversation(forgettingHistory:true);model.releaseAll();try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
        app.send("一起看看彩虹");let original=app.selectedConversationID
        try await backgroundWait{model.requests.count == 1}
        app.newConversation();let calling=app.selectedConversationID
        app.toggleCall();await settle();wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
        let stops=audio.stops
        try await model.emit(0,"彩虹有许多颜色。")
        model.finish(0,"雨后的天空出现一道彩虹。")
        try await backgroundWait{app.conversations.first{$0.id == original}?.isGenerating == false}
        try require(app.selectedConversationID == calling && app.inCall && audio.stops == stops && !wire.closed,"background result ended or replaced the active call")
        try require(spoken.isEmpty && !app.voice.preparing && !app.messages.contains{$0.text.contains("彩虹")},"hidden reply spoke or appeared inside the call")
        app.selectConversation(original)
        try require(app.selectedConversationID == calling,"active call navigation rule was bypassed")
        app.toggleCall();await settle();app.selectConversation(original)
        try require(app.messages.last?.text == "雨后的天空出现一道彩虹。" && spoken.isEmpty && !app.inCall,"returning lost or automatically replayed the hidden reply")
        app.send("再聊聊彩虹");try await backgroundWait{model.requests.count == 2}
        model.finish(1,"我们再看看彩虹的颜色。")
        try await backgroundWait{!app.busy}
        try require(spoken == ["我们再看看彩虹的颜色。"],"visible completion no longer respects automatic narration")
    })]
}
