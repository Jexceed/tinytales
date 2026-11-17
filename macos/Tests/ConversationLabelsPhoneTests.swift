import Foundation

@MainActor func conversationLabelsPhoneTestCases() -> [(String,@MainActor () async throws -> Void)] {
    [("CL-005 phone recognition and completed stories share content labels and retained timestamps", {
        let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio()
        let firstTime=ConversationLabels.date("2026-01-01T00:00:00Z")!
        let app=AppModel(store:store,keyProvider:{"fixture"},callFactory:{store,_,voice,session in
            RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},voice:voice,session:session,inputCommitDelay:0)
        },now:{firstTime})
        defer{app.cancel();try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
        app.toggleCall();await settle();wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
        wire.emit(["type":"response.created","response":["id":"label-greeting"]]);await settle()
        wire.emit(["type":"response.done","response":["id":"label-greeting","status":"completed","output":[["type":"message","id":"label-hello","content":[["text":"我在呢。"]]]]]]);await settle()
        try require(app.conversations.isEmpty && app.conversationUpdatedAt == nil,"connection or greeting created a dated row")
        wire.emit(["type":"input_audio_buffer.committed","item_id":"label-user"]);await settle()
        try require(app.conversations.isEmpty,"unrecognized audio created a dated row")
        let repliesBefore=wire.sent.filter{$0["type"] as? String == "response.create"}.count
        wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"label-user","transcript":"讲一个月亮船的故事"]);await settle()
        try await waitFor({wire.sent.filter{$0["type"] as? String == "response.create"}.count > repliesBefore},seconds:2)
        try require(app.conversationTitle.contains("月亮船") && app.conversationUpdatedAt == firstTime,"final recognized text did not label the conversation")
        wire.emit(["type":"response.created","response":["id":"label-story"]]);await settle()
        wire.emit(["type":"response.done","response":["id":"label-story","status":"completed","output":[["type":"message","id":"label-story-text","content":[["text":"好呀！小兔坐着月亮船去找星星。"]]]]]]);await settle()
        try await waitFor({!app.busy && app.storySession.current != nil},seconds:2)
        let title=app.conversationTitle,time=app.conversationUpdatedAt,id=app.selectedConversationID
        try require(title.contains("月亮船") && !ConversationLabels.isPlaceholder(title),"automatic phone checkpoint restored the generic title")
        try require(try store.stories().first?.title == title,"phone display and saved title disagree")
        app.toggleCall();await settle();app.newConversation();app.selectConversation(id)
        try require(app.conversationTitle == title && app.conversationUpdatedAt == time && app.conversations.count == 1,"phone title or time was lost after switching")
    })]
}
