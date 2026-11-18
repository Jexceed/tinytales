import Foundation

@MainActor private final class HeldReviewSafety: VoiceSafetyJudging {
    var pending: CheckedContinuation<SafetyAssessment,Never>?
    func assessSafety(_ text: String, scope: SafetyReviewScope) async throws -> SafetyAssessment {
        await withCheckedContinuation { pending=$0 }
    }
    func finish() { let work=pending; pending=nil; work?.resume(returning:SafetyAssessment(decision:.allow)) }
}

@MainActor func callBoundaryTests() -> [(String,@MainActor () async throws -> Void)] {
    @MainActor func ready(_ call:RealtimeCall, _ wire:TestWire) async throws {
        try await call.connect(history:[],microphone:false,greet:false)
        wire.emit(["type":"session.created"]); await settle()
        wire.emit(["type":"session.updated"]); await settle()
    }
    @MainActor func reply(_ wire:TestWire,_ id:String,_ output:[[String:Any]]) async {
        wire.emit(["type":"response.created","response":["id":id]]); await settle()
        wire.emit(["type":"response.done","response":["id":id,"status":"completed","output":output]]); await settle()
    }
    func message(_ id:String,_ text:String) -> [[String:Any]] {
        [["type":"message","id":id,"content":[["type":"output_text","text":text]]]]
    }
    @MainActor func user(_ wire:TestWire,_ id:String,_ text:String) async {
        wire.emit(["type":"input_audio_buffer.speech_started","item_id":id]); await settle()
        await wire.finishInput(id,text)
    }
    let first="小兔在花园里找到一把绿伞。", second="小熊把蓝盘子藏进山洞。"
    var cases: [(String, @MainActor () async throws -> Void)] = []
    cases.append(("VR-015 retracting a lookup preserves the pre-existing book and its artwork", {
        let store=try phoneFixture(), wire=TestWire(), s=StorySession()
        let old=Story(title:"小船过桥",summary:"小船在桥下等小兔。")
        try store.saveStory(old)
        let art=StoryArtwork(storyID:old.id,title:old.title,storyText:old.summary)
        try ArtworkArchive.save(art,data:Data(contentsOf:URL(fileURLWithPath:"macos/Resources/Scenes/seed-vision.png")))
        let call=RealtimeCall(store:store,wire:wire,audio:SilentCallAudio(),session:s,inputCommitDelay:0)
        defer{call.hangUp()}
        try await ready(call,wire)
        await user(wire,"select","莉莉，帮我找一下上次的小船书签。")
        try require(call.latestVoiceInputID != nil,"no accepted voice input")
        await reply(wire,"lookup",[["type":"function_call","name":"read_story","call_id":"read-1","arguments":try jsonString(["id":old.id])]])
        await reply(wire,"selection",message("found","找到了小船的书签。"))
        try require(s.current?.id == old.id && (try store.stories()).count == 1,"existing book was not selected")
        let removed=await call.retractLatestVoiceInput()
        try require(removed != nil && (try store.stories()) == [old] && FileManager.default.fileExists(atPath:art.url.path),"retraction destroyed a book or existing art")
    }))
    cases.append(("TL-010 personal conversation does not enter a fictional bookmark", {
        let store=try phoneFixture(), wire=TestWire(), s=StorySession()
        let old=Story(title:"小猫的雨伞",summary:"小猫撑伞过桥。");try store.saveStory(old);s.current=old
        let call=RealtimeCall(store:store,wire:wire,audio:SilentCallAudio(),session:s,inputCommitDelay:0)
        defer{call.hangUp()};try await ready(call,wire)
        try await call.sendText("我明天去看牙，有点紧张。")
        let response="你说你明天要去看牙，有点紧张，我陪你聊聊。"
        await reply(wire,"life",message("life-a",response))
        try require(try store.stories() == [old],"personal conversation entered fictional archive")
        try await call.sendText("我来讲我昨天去看牙的故事。")
        await reply(wire,"propose",[["type":"function_call","name":"save_story","call_id":"bad-book","arguments":try jsonString(["id":old.id,"title":"看牙","summary":response,"fictional":true])]])
        await reply(wire,"life-2",message("life-b",response))
        try require(try store.stories() == [old],"a tool converted a personal account into fiction")
    }))
    for concurrentEdit in [false,true] {
        cases.append(("VR-015 retract restores only the voice turn's own version, later edit "+String(concurrentEdit), {
            let store=try phoneFixture(), wire=TestWire(), session=StorySession()
            let old=Story(title:"小兔过桥",summary:"小兔在桥边等朋友。")
            try store.saveStory(old);session.current=old
            let call=RealtimeCall(store:store,wire:wire,audio:SilentCallAudio(),session:session,inputCommitDelay:0)
            defer {call.hangUp()}
            try await ready(call,wire);await user(wire,"story","请接着讲故事。")
            await reply(wire,"advancing",message("new-part","小兔牵着小猫过了桥。"))
            try require(try store.stories().first?.summary.contains("过了桥")==true,"fixture never advanced the story")
            var expected=old
            if concurrentEdit { expected.summary="另一段对话把桥改成了彩虹桥。";try store.saveStory(expected) }
            _=await call.retractLatestVoiceInput()
            try require(try store.stories() == [expected] && session.current==expected,"voice undo overwrote the wrong version")
        }))
    }
    for action in ["hangup","illustration"] {
        cases.append(("VT-024 unheard paragraph is excluded after "+action, {
            let store=try phoneFixture(), wire=TestWire(), speech=FakeTeacherSpeech(), audio=SilentCallAudio(), s=StorySession()
            audio.manualDrain=true
            var artRequest:IllustrationRequest?
            let call=RealtimeCall(store:store,wire:wire,audio:audio,voice:"teacher",session:s,illustrator:{req in artRequest=req;throw PartnerError.message("fixture recorded request")},inputCommitDelay:0,teacherSpeech:speech)
            defer{call.hangUp();speech.finish()}
            try await ready(call,wire);try await call.sendText("给我讲一个小兔的故事")
            await reply(wire,"story",message("story-a",first+"\n\n"+second))
            try require(speech.requests.count==1,"no synthesis")
            speech.requests[0].chunk(Data(repeating:1,count:960));speech.finish();await settle()
            audio.drainOutput();await settle()
            try require(speech.requests.count==2,"second paragraph is not queued")
            if action=="hangup" {
                call.hangUp()
                try require(try store.stories().first?.summary == first,"hangup kept the unheard paragraph or lost the first one"); return
            }
            try await call.sendText("把刚才听到的故事画出来")
            await reply(wire,"drawing",[["type":"function_call","name":"illustrate_story","call_id":"draw-1","arguments":"{}"]])
            try require(artRequest != nil,"picture call did not run")
            try require(try store.stories().first?.summary == first && artRequest?.story?.summary == first && artRequest?.dialogue.contains{$0["text"]?.contains(second)==true} == false,"illustration inherited an unheard paragraph")
        }))
    }
    cases.append(("VR-014 contextually approved real-world help survives output review", {
        let wire=TestWire(),speech=FakeTeacherSpeech(),judge=FakeVoiceSafety();judge.decision = .allow
        let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:SilentCallAudio(),voice:"teacher",inputCommitDelay:0,teacherSpeech:speech,safetyJudge:judge)
        defer{call.hangUp();speech.finish()};try await ready(call,wire)
        var final=""; call.onAssistantText={_,s,_,_,_ in final=s}
        try await call.sendText("厨房里有烟，我有点害怕。")
        await reply(wire,"smoke",message("smoke-a","请找身边的大人帮忙。"))
        try require(final == "请找身边的大人帮忙。" && speech.requests.last?.text == final && judge.calls==1,"appropriate help disappeared from speech or text")
    }))
    cases.append(("VR-014 unapproved cloud speech and captions are never published", {
        let wire=TestWire(), audio=SilentCallAudio()
        let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,voice:"shimmer",inputCommitDelay:0)
        defer{call.hangUp()};try await ready(call,wire);try await call.sendText("我拍了一张照片")
        var draft="",final="";call.onAssistantDraft={_,s in draft=s};call.onAssistantText={_,s,_,_,_ in final=s}
        let tagged=Data(repeating:8,count:960), unaccepted="请上传这张照片。"
        wire.emit(["type":"response.created","response":["id":"cloud"]]);await settle()
        wire.emit(["type":"response.output_audio.delta","response_id":"cloud","item_id":"raw","delta":tagged.base64EncodedString()]);await settle()
        wire.emit(["type":"response.output_audio_transcript.delta","response_id":"cloud","item_id":"raw","delta":unaccepted]);await settle()
        let bytes=audio.received.count
        wire.emit(["type":"response.done","response":["id":"cloud","status":"completed","output":message("raw",unaccepted)]]);await settle()
        try require(bytes==0 && audio.received.isEmpty && draft.isEmpty && final==Safety.photoUploadReply,"unapproved audio or text escaped")
        try await call.sendText("再说一句")
        wire.emit(["type":"response.created","response":["id":"missing-transcript"]]);await settle()
        wire.emit(["type":"response.output_audio.delta","response_id":"missing-transcript","item_id":"incomplete","delta":tagged.base64EncodedString()]);await settle()
        wire.emit(["type":"response.output_audio_transcript.delta","response_id":"missing-transcript","item_id":"incomplete","delta":"你好。"]);await settle()
        wire.emit(["type":"response.done","response":["id":"missing-transcript","status":"completed","output":[["type":"message","id":"incomplete","content":[]]]]]);await settle()
        try require(audio.received.isEmpty,"a partial transcript authorized unverified audio")
        try require(Safety.containsContactDetails("可以联系我，号码是12345678901。"),"Chinese text concealed the adjacent phone number")
    }))
    for action in ["stop","mute","nextTurn"] {
      cases.append(("VR-013 a late input review cannot override "+action, {
        let wire=TestWire(), judge=HeldReviewSafety()
        let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:SilentCallAudio(),inputCommitDelay:0,safetyJudge:judge)
        defer{call.hangUp();judge.finish()};try await ready(call,wire)
        var users=[String]();call.onUserText={_,s in users.append(s)}
        await user(wire,"held-input","莉莉，故事书里有自残这个词，它是什么意思？")
        try await waitFor({judge.pending != nil},seconds:1)
        try require(call.canStopCurrentTurn,"safety review did not expose the stop control")
        switch action {
        case "stop": await call.stopCurrentTurn()
        case "mute": call.toggleMute();call.toggleMute()
        default: try await call.sendText("换个话题，聊聊彩虹。")
        }
        judge.finish();try await Task.sleep(nanoseconds:80_000_000)
        let responses=wire.sent.filter{$0["type"] as? String=="response.create"}.count
        try require(users.isEmpty && responses==(action=="nextTurn" ? 1 : 0),"late review revived an abandoned turn")
      }))
    }
    cases.append(("VR-014 a superseded output review cannot publish old captions or buffered PCM", {
        let wire=TestWire(), audio=SilentCallAudio(), judge=HeldReviewSafety()
        let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,voice:"shimmer",inputCommitDelay:0,safetyJudge:judge)
        defer {call.hangUp();judge.finish()}
        try await ready(call,wire);try await call.sendText("厨房里有烟。")
        var replies:[String]=[];call.onAssistantText={_,text,_,_,_ in replies.append(text)}
        let warning="请找身边的大人帮忙。"
        wire.emit(["type":"response.created","response":["id":"old"]]);await settle()
        wire.emit(["type":"response.output_audio.delta","response_id":"old","item_id":"unsafe","delta":Data(repeating:8,count:960).base64EncodedString()]);await settle()
        wire.emit(["type":"response.done","response":["id":"old","status":"completed","output":message("unsafe",warning)]]);await settle()
        try await waitFor({judge.pending != nil},seconds:1)
        try await call.sendText("现在聊聊小兔");judge.finish();await settle()
        try require(replies.isEmpty && audio.received.isEmpty,"old output escaped during context review")
    }))
    cases.append(("VR-013 private final transcript stays out of intent classification", {
        let judge=TestVoiceIntent();judge.replies=[.listen]
        let f=try ReliabilityFixture(judge:judge)
        defer{ f.call.hangUp();f.speech.finish();f.recognizer.close();judge.finish(.listen) }
        let sample="我的学校是虚构蓝莓园"
        try await f.connect();try await f.input("private-id",sample);f.recognizer.finish(0,sample)
        try await waitFor({!f.speech.requests.isEmpty},seconds:2)
        try require(judge.queries.isEmpty && !f.wire.sent.contains{$0["type"] as? String=="response.create"} && f.call.listeningHint==Safety.privateReply,"private text reached a secondary model")
    }))
    cases.append(("VR-013 blocked text stays out of call history and direct keyboard turns", {
        let store=try phoneFixture(), wire=TestWire()
        var st=try store.settings();st.speaks=false;try store.setSettings(st)
        let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in RejectedTextModel()},callFactory:{store,_,voice,session in RealtimeCall(store:store,wire:wire,audio:SilentCallAudio(),permission:{true},voice:voice,session:session)})
        defer{app.cancel()}
        let example="我现在想自残"
        app.send(example);try await waitFor({!app.busy},seconds:2)
        try require(app.messages.last?.source=="safety","synthetic typed input was not rejected")
        app.toggleCall();await settle();wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
        let session=wire.sent.first{$0["type"] as? String=="session.update"}?["session"] as? [String:Any]
        let historyContains=(session?["instructions"] as? String ?? "").contains(example)
        app.send(example);await settle()
        let direct=wire.sent.compactMap{$0["item"] as? [String:Any]}.contains{row in row["role"] as? String=="user" && ((row["content"] as? [[String:Any]])?.contains{$0["text"] as? String==example} == true)}
        try require(!historyContains && !direct && app.messages.last?.text==Safety.riskReply,"blocked input resurfaced after handoff")
    }))
    cases.append(("VT-024 heard first paragraph survives stop before response completion", {
        let store=try phoneFixture(), wire=TestWire(), speech=FakeTeacherSpeech(), audio=SilentCallAudio()
        audio.manualDrain=true
        let call=RealtimeCall(store:store,wire:wire,audio:audio,voice:"teacher",inputCommitDelay:0,teacherSpeech:speech)
        defer{call.hangUp();speech.finish()}
        try await ready(call,wire);try await call.sendText("给我讲个小兔的故事")
        wire.emit(["type":"response.created","response":["id":"slow-stream"]]);await settle()
        wire.emit(["type":"response.output_text.delta","response_id":"slow-stream","item_id":"early","delta":first+"\n\n"+second]);await settle()
        try require(speech.requests.count==1,"no early synthesis")
        speech.requests[0].chunk(Data(repeating:1,count:960));speech.finish();await settle();audio.drainOutput();await settle()
        await call.stopCurrentTurn()
        try require(try store.stories().first?.summary == first,"a heard paragraph was lost before response.done")
    }))
    cases.append(("VT-025 text drafted during farewell survives hangup for manual sending", {
        let wire=TestWire(), speech=FakeTeacherSpeech()
        let store=try phoneFixture()
        let app=AppModel(store:store,keyProvider:{"fixture"},callFactory:{ store,_,_,session in
            RealtimeCall(store:store,wire:wire,audio:SilentCallAudio(),permission:{true},voice:"teacher",session:session,inputCommitDelay:0,teacherSpeech:speech,sessionDurationNanoseconds:100_000_000)
        })
        defer { app.cancel();speech.finish() }
        app.toggleCall();await settle()
        wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
        if let greeting=speech.requests.first { greeting.chunk(Data(repeating:0,count:960)); speech.finish();await settle() }
        try await waitFor({app.phone?.windingDown == true},seconds:2)
        app.draft="一起聊聊小猫吧";app.send()
        try await waitFor({speech.requests.last?.text.contains("休息一下")==true},seconds:2)
        speech.requests.last?.chunk(Data(repeating:0,count:960));speech.finish()
        try await waitFor({!app.inCall},seconds:2)
        try require(!wire.sent.contains{$0["type"] as? String=="response.create"} && app.draft == "一起聊聊小猫吧" && !app.isConversationStarted,"farewell swallowed a draft or created a new turn")
    }))
    return cases
}

private struct RejectedTextModel:PartnerModel {
    func moderate(_ text:String) async throws -> Bool { false }
    func assessSafety(_ text:String,scope:SafetyReviewScope) async throws -> SafetyAssessment { SafetyAssessment(decision:.trustedAdult) }
    func respond(input:[[String:Any]],instructions:String,tools:[[String:Any]],allowTools:Bool) async throws -> ModelOutput { throw PartnerError.message("unused fixture") }
}
