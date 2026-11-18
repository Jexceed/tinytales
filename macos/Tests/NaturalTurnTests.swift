import Foundation

@MainActor final class TestVoiceIntent:VoiceIntentJudging {
    var queries:[VoiceIntentContext]=[]
    var replies:[VoiceIntent]=[]
    var pending:[CheckedContinuation<VoiceIntent,Error>]=[]
    func voiceIntent(_ context:VoiceIntentContext) async throws -> VoiceIntent {
        queries.append(context)
        if !replies.isEmpty{return replies.removeFirst()}
        return try await withCheckedThrowingContinuation{pending.append($0)}
    }
    func finish(_ value:VoiceIntent) {let waits=pending;pending=[];for wait in waits{wait.resume(returning:value)}}
}

@MainActor func naturalTurnTestCases()->[(String,@MainActor () async throws -> Void)] {
    typealias Fixture=(wire:TestWire,audio:SilentCallAudio,speech:FakeTeacherSpeech,call:RealtimeCall)
    let first="小兔抱着红苹果，沿着花园的小路走。它轻轻敲门，奶奶笑着打开了门。"
    let second="奶奶拿出蓝盘子，小兔把苹果放进去。它们坐到窗边，一起看院子里的花。"
    func fixture(timeout:UInt64=12_000_000_000,judge:VoiceIntentJudging?=nil,intentTimeout:UInt64=1_200_000_000,commitDelay:UInt64=0) async throws -> Fixture {
        let wire=TestWire(),audio=SilentCallAudio(),speech=FakeTeacherSpeech();audio.manualDrain=true
        let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{true},voice:"teacher",transcriptionTimeout:timeout,inputCommitDelay:commitDelay,teacherSpeech:speech,intentJudge:judge,intentTimeout:intentTimeout)
        try await call.connect(history:[],microphone:true,greet:false)
        wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
        return (wire,audio,speech,call)
    }
    func count(_ wire:TestWire,_ type:String)->Int {wire.sent.filter{$0["type"] as? String==type}.count}
    func start(_ f:Fixture,_ text:String,prompt:String="给我讲个故事") async throws {
        try await f.call.sendText(prompt)
        f.wire.emit(["type":"response.created","response":["id":"story-response"]]);await settle()
        f.wire.emit(["type":"response.output_text.delta","response_id":"story-response","item_id":"story-text","delta":text]);await settle()
        f.wire.emit(["type":"response.done","response":["id":"story-response","status":"completed","output":[["id":"story-text","type":"message","content":[["type":"output_text","text":text]]]]]]);await settle()
        try require(!f.speech.requests.isEmpty,"no local narration request")
        f.speech.requests.last!.chunk(Data(repeating:1,count:9600));await settle()
    }
    func segment(_ f:Fixture,_ id:String,text:String?=nil) async {
        f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":id]);await settle()
        f.wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":id]);await settle()
        f.wire.emit(["type":"input_audio_buffer.committed","item_id":id]);await settle()
        if let text {f.wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":id,"transcript":text]);await settle()}
    }
    func close(_ f:Fixture) {f.call.hangUp();f.speech.finish()}
    return [
        ("VT-014 direct partner requests have a fast path without accepting named bystander requests",{
            for text in ["给我画一张图片","帮我讲一个故事","请给我读一首诗"] {
                try require(VoiceTurnPolicy.quickIntent(text,context:.init(),final:true,semanticAddress:true) == .listen,"a clear partner request waits for another classifier")
            }
            for text in ["小明，给我画一张图片","妈妈，帮我讲一个故事","电视里说给我画一张图片","“给我画一张图片”是什么意思"] {
                try require(VoiceTurnPolicy.quickIntent(text,context:.init(),final:true,semanticAddress:true)==nil,"a bystander or quote used the direct-request fast path")
            }
        }),
        ("VT-019 local resumed speech blocks submission before the delayed server VAD arrives",{
            let f=try await fixture(commitDelay:160_000_000);defer{close(f)}
            var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            await segment(f,"first",text:"我们来讲")
            try await Task.sleep(nanoseconds:100_000_000)
            f.audio.onMicrophone?(Data(repeating:3,count:4800));await settle()
            try await Task.sleep(nanoseconds:100_000_000)
            try require(users.isEmpty && count(f.wire,"response.create")==0,"local speech was ignored until the server start event")
            await segment(f,"second",text:"一个小猫的故事。")
            try await waitFor({users.count==1},seconds:1)
            try require(users==["我们来讲一个小猫的故事。"],"the delayed VAD split a resumed turn")
        }),
        ("VT-019 brief noise does not renew the quiet window or create a request",{
            var gate=LocalSpeechContinuation()
            gate.observe(Data(repeating:3,count:960),now:1)
            gate.observe(Data(repeating:0,count:960),now:1.02)
            try require(gate.remainingQuietTime(VoiceTurns.continuationDelay,now:1.1)==0,"one short noise burst postponed the turn")
            gate.observe(Data(repeating:3,count:4800),now:2)
            try require(gate.remainingQuietTime(VoiceTurns.continuationDelay,now:3.2)>0.39,"local speech did not preserve the 1.6 second quiet window")
            gate.reset();try require(gate.remainingQuietTime(VoiceTurns.continuationDelay,now:3.2)==0,"cancel retained old activity")
        }),
        ("VT-020 incomplete spoken lead-in waits beyond the normal deadline and keeps the next clause",{
            let f=try await fixture(commitDelay:80_000_000);defer{close(f)}
            var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            await segment(f,"lead",text:"哦，我说……")
            try await Task.sleep(nanoseconds:200_000_000)
            try require(users.isEmpty && count(f.wire,"response.create")==0,"an unfinished lead-in triggered a reply")
            await segment(f,"quote",text:"举头望明月。")
            try await waitFor({users.count==1},seconds:1)
            try require(users==["哦，我说……举头望明月。"],"the complete turn lost its lead-in")
        }),
        ("VT-020 final semantic wait is retained until a later completed clause",{
            let judge=TestVoiceIntent();judge.replies=[.undecided,.listen]
            let f=try await fixture(judge:judge,commitDelay:70_000_000);defer{close(f);judge.finish(.listen)}
            await segment(f,"lead",text:"小兔把那个")
            try await Task.sleep(nanoseconds:170_000_000)
            try require(count(f.wire,"response.create")==0,"final wait was converted into permission to answer")
            await segment(f,"end",text:"苹果送给了奶奶。")
            try await waitFor({count(f.wire,"response.create")==1},seconds:1)
        }),
        ("VT-020 a recognized recited poem completes a lead-in instead of being dropped as backchannel",{
            let judge=TestVoiceIntent();judge.replies=[.listen,.keepSpeaking]
            let f=try await fixture(judge:judge,commitDelay:70_000_000);defer{close(f);judge.finish(.listen)}
            var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            await segment(f,"lead",text:"哦，我说")
            try await Task.sleep(nanoseconds:150_000_000)
            await segment(f,"poem",text:"举头望明月。")
            try await waitFor({users.count==1},seconds:1)
            try require(users[0].contains("举头望明月") && judge.queries.count==1,"a known recitation was treated as meaningless background speech")
            try require(VoiceTurnPolicy.quickIntent("妈妈，举头望明月",context:.init(),final:true,semanticAddress:true)==nil,"poem shortcut bypassed recipient review")
        }),
        ("VT-026 trimmed connection pre-roll detects retained speech without indexing discarded samples",{
            var samples=Data(repeating:3,count:9600); samples.append(Data(repeating:0,count:144_000));samples.removeFirst(9600)
            try require(samples.startIndex>0 && !LocalSpeechContinuation.containsSpeech(samples),"discarded sound suppressed the greeting")
            samples.append(Data(repeating:3,count:9600));samples.removeFirst(9600)
            try require(LocalSpeechContinuation.containsSpeech(samples),"speech in trimmed pre-roll was missed")
        }),
        ("VT-021 continuation delay subtracts recognition wait and local teacher greeting avoids cloud generation or speech collision",{
            let judge=TestVoiceIntent()
            let f=try await fixture(judge:judge,commitDelay:220_000_000);defer{close(f);judge.finish(.listen)}
            var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            await segment(f,"slow",text:"小熊去哪里了")
            try await Task.sleep(nanoseconds:180_000_000)
            let resolvedAt=Date()
            judge.finish(.listen)
            try await waitFor({users.count==1},seconds:1)
            try require(Date().timeIntervalSince(resolvedAt)<0.14,"continuation window slept the full delay again after slow classification")
            // Local teacher greeting synthesizes locally without response.create, and skips when user already spoke while connecting.
            for spokeEarly in [false,true] {
                let wire=TestWire(),audio=SilentCallAudio(),speech=FakeTeacherSpeech()
                let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{true},voice:"teacher",inputCommitDelay:0,teacherSpeech:speech)
                defer{call.hangUp();speech.finish()}
                var events:[String]=[];call.onProtocolEvent={events.append($0)}
                try await call.connect(history:[],microphone:true,greet:true)
                if spokeEarly {audio.onMicrophone?(Data(repeating:3,count:9600));await settle()}
                wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                try require(count(wire,"response.create")==0,"teacher greeting still requested a cloud LLM generation")
                if spokeEarly {
                    try require(speech.requests.isEmpty && events.contains("greeting_skipped_for_user_speech"),"greeting talked over user speech buffered during connection")
                } else {
                    try require(speech.requests.count==1 && speech.requests[0].text.contains("我在呢"),"local teacher greeting was not voiced")
                }
            }
        }),
        ("VT-022 first completed story paragraph streams early to TTS and interruption trims saved bookmark to heard paragraphs",{
            let f=try await fixture();defer{close(f)}
            try await f.call.sendText("给我讲个小兔送苹果的故事")
            f.wire.emit(["type":"response.created","response":["id":"stream-story"]]);await settle()
            f.wire.emit(["type":"response.output_text.delta","response_id":"stream-story","item_id":"s1","delta":first+"\n\n奶奶拿出蓝盘子"]);await settle()
            try require(f.speech.requests.count==1 && f.speech.requests[0].text==first,"completed first paragraph waited for response.done before starting TTS")
            f.speech.requests[0].chunk(Data(repeating:1,count:9600));await settle()
            f.wire.emit(["type":"response.output_text.delta","response_id":"stream-story","item_id":"s1","delta":"，小兔把苹果放进去。它们坐到窗边，一起看院子里的花。"]);await settle()
            f.wire.emit(["type":"response.done","response":["id":"stream-story","status":"completed","output":[["id":"s1","type":"message","content":[["type":"output_text","text":first+"\n\n"+second]]]]]]);await settle()
            try require(f.speech.requests.count==1,"response.done duplicated synthesis of the already-streaming first paragraph")
            f.speech.finish();await settle();f.audio.drainOutput();await settle()
            try require(f.speech.requests.count==2 && f.speech.requests[1].text==second,"second paragraph did not continue seamlessly after first paragraph drained")
            f.speech.requests[1].chunk(Data(repeating:1,count:9600));await settle()
            // Interrupt during paragraph 2: saved story must keep paragraph 1 and drop unheard paragraph 2.
            await f.call.stopCurrentTurn()
            let stories=try f.call.valueForTestingSavedStories()
            try require(stories.count==1 && stories[0].summary.contains("轻轻敲门") && !stories[0].summary.contains("蓝盘子"),"interrupted unheard second paragraph remained in the saved story bookmark")
            // Interrupt during paragraph 1 of a brand new call before any paragraph drains: no unheard story remains saved.
            let store2=try phoneFixture(),wire2=TestWire(),audio2=SilentCallAudio(),speech2=FakeTeacherSpeech();audio2.manualDrain=true
            let session2=StorySession()
            let call2=RealtimeCall(store:store2,wire:wire2,audio:audio2,permission:{true},voice:"teacher",session:session2,inputCommitDelay:0,teacherSpeech:speech2)
            defer{call2.hangUp();speech2.finish();try? FileManager.default.removeItem(at:store2.url.deletingLastPathComponent())}
            try await call2.connect(history:[],microphone:true,greet:false)
            wire2.emit(["type":"session.created"]);await settle();wire2.emit(["type":"session.updated"]);await settle()
            try await call2.sendText("给我讲一个小熊看星星的故事")
            wire2.emit(["type":"response.created","response":["id":"unheard"]]);await settle()
            wire2.emit(["type":"response.done","response":["id":"unheard","status":"completed","output":[["id":"u1","type":"message","content":[["type":"output_text","text":"小熊爬上树屋看星星。"]]]]]]);await settle()
            speech2.requests[0].chunk(Data(repeating:1,count:4800));await settle()
            await call2.stopCurrentTurn()
            try require(session2.current==nil && (try store2.stories()).isEmpty,"unheard first paragraph remained saved after stop")
        }),
        ("VT-023 session time limit waits for the active turn to finish and speaks a gentle farewell before hanging up",{
            let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio(),speech=FakeTeacherSpeech()
            audio.manualDrain=true
            let call=RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},voice:"teacher",inputCommitDelay:0,teacherSpeech:speech,sessionDurationNanoseconds:120_000_000)
            defer{call.hangUp();speech.finish();try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
            var events:[String]=[],replies:[String]=[]
            call.onProtocolEvent={events.append($0)};call.onAssistantText={_,text,_,_,_ in replies.append(text)}
            try await call.connect(history:[],microphone:true,greet:false)
            wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
            try await call.sendText("讲个故事")
            wire.emit(["type":"response.created","response":["id":"active-turn"]]);await settle()
            wire.emit(["type":"response.done","response":["id":"active-turn","status":"completed","output":[["id":"a1","type":"message","content":[["type":"output_text","text":first]]]]]]);await settle()
            speech.requests[0].chunk(Data(repeating:1,count:9600));await settle()
            try await Task.sleep(nanoseconds:170_000_000)
            try require(call.active && call.state == .speaking && !events.contains("session_wind_down"),"expiry abruptly cut off an ongoing story sentence")
            speech.finish();await settle();audio.drainOutput();await settle()
            try await waitFor({speech.requests.count==2 && events.contains("session_wind_down")},seconds:1)
            try require(speech.requests[1].text.contains("休息一下") && replies.last?.contains("休息一下")==true,"wind-down did not voice a warm child-friendly farewell")
            speech.requests[1].chunk(Data(repeating:1,count:4800));speech.finish();await settle();audio.drainOutput();await settle()
            try await waitFor({!call.active},seconds:1)
            try require(call.notice.contains("休息一下") && wire.closed,"call did not close cleanly after farewell finished")
        }),
        ("VT-016 a natural pause keeps the default conversation window open and renewed speech cancels the old deadline",{
            let wire=TestWire(),audio=SilentCallAudio()
            // Exercise the production default, rather than a shorter test delay.
            let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{true})
            defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            try await call.connect(history:[],microphone:false,greet:false)
            wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"first"]);await settle()
            await wire.finishInput("first","我们来讲")
            try await Task.sleep(nanoseconds:1_200_000_000)
            try require(users.isEmpty && count(wire,"response.create")==0 && call.state == .listening,"the natural pause was treated as a finished turn")
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"second"]);await settle()
            wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"second","delta":"一个老巫婆"]);await settle()
            try require(call.inputTranscript=="我们来讲一个老巫婆","continued speech hid the first clause")
            try await Task.sleep(nanoseconds:500_000_000)
            try require(users.isEmpty && count(wire,"response.create")==0,"the first deadline answered while the user was still speaking")
            await wire.finishInput("second","一个老巫婆的故事。")
            let completed=Date()
            try await waitFor({count(wire,"response.create")==1},seconds:1.95)
            try require(Date().timeIntervalSince(completed)<1.95,"the old two-second continuation delay remained")
            try require(users==["我们来讲一个老巫婆的故事。"],"continuation was not submitted as one complete turn")
        }),
        ("VT-016 a confirmed stop bypasses continuation waiting and cancels earlier clauses",{
            let f=try await fixture(commitDelay:200_000_000);defer{close(f)}
            var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            try await start(f,first)
            await segment(f,"unfinished",text:"给我讲一个")
            try require(f.audio.paused && f.audio.outputStops==0,"meaningful speech did not promptly pause playback")
            // A committed stop must also preempt the timer if no start event arrived.
            await f.wire.finishInput("stop","莉莉，停一下")
            try require(users==["莉莉，停一下"] && f.call.state == .listening && f.audio.outputStops==1,"a stop waited for the continuation timer")
            try await Task.sleep(nanoseconds:250_000_000)
            try require(count(f.wire,"response.create")==1,"an earlier clause answered after the stop")
        }),
        ("VT-016 late earlier transcription supplies the missing context before a continuation is classified",{
            let judge=TestVoiceIntent();judge.replies=[.listen,.listen]
            let f=try await fixture(judge:judge,commitDelay:60_000_000);defer{close(f);judge.finish(.listen)}
            var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            await segment(f,"first")
            await segment(f,"second",text:"小马过河的故事。")
            try require(judge.queries.isEmpty,"a noun-only continuation was classified without its earlier audio item")
            f.wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"first","transcript":"给我讲一个"]);await settle()
            try await waitFor({users.count==1},seconds:1)
            try require(judge.queries.count==1 && judge.queries.last?.words=="小马过河的故事。" && judge.queries.last?.earlierInTurn=="给我讲一个","same-turn context was missing or presented as an unrelated previous request")
            try require(users==["给我讲一个小马过河的故事。"],"the continued story request lost its second clause")
        }),
        ("VT-017 out-of-order ASR clauses create one actual chat bubble and a later turn stays separate",{
            let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio()
            let app=AppModel(store:store,keyProvider:{"fixture"},callFactory:{store,_,_,session in
                RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},session:session,inputCommitDelay:70_000_000)
            });defer{app.cancel()}
            app.toggleCall();await settle();wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
            let initialRequests=count(wire,"response.create")
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"a"]);await settle()
            wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":"a"]);await settle()
            wire.emit(["type":"input_audio_buffer.committed","item_id":"a"]);await settle()
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"b"]);await settle()
            await wire.finishInput("b","一个老巫婆的故事。")
            wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"我们来讲"]);await settle()
            try await waitFor({app.messages.filter(\.isUser).count==1},seconds:1)
            let message=app.messages.first{$0.isUser}
            try require(message?.externalID=="a" && message?.text=="我们来讲一个老巫婆的故事。","ASR chunk IDs leaked into separate bubbles or changed their order")
            try require(app.conversations.count==1 && count(wire,"response.create")==initialRequests+1,"one utterance created several conversations or replies")
            await wire.finishInput("b","一个老巫婆的故事。")
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"next"]);await settle()
            await wire.finishInput("next","接下来呢？")
            try await waitFor({app.messages.filter(\.isUser).count==2},seconds:1)
            try require(app.messages.filter(\.isUser).map(\.text)==["我们来讲一个老巫婆的故事。","接下来呢？"],"a duplicate or later utterance overwrote the first turn")
        }),
        ("VT-017 joining clauses preserves English word boundaries and Chinese punctuation",{
            let f=try await fixture(commitDelay:60_000_000);defer{close(f)}
            var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            await segment(f,"english-a",text:"I would like")
            await segment(f,"english-b",text:"a story.")
            try await waitFor({users.count==1},seconds:1)
            try require(users==["I would like a story."],"English words were concatenated")
            await segment(f,"chinese-a",text:"不是奶奶，")
            await segment(f,"chinese-b",text:"是一个老巫婆。")
            try await waitFor({users.count==2},seconds:1)
            try require(users.last=="不是奶奶，是一个老巫婆。","joining rewrote or removed Chinese words and punctuation")
        }),
        ("VT-018 mute hangup and typed input cancel an unsubmitted spoken turn",{
            for action in ["mute","hangup","text"] {
                let f=try await fixture(commitDelay:100_000_000);defer{close(f)}
                var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
                await segment(f,"pending",text:"我想听一个故事")
                if action=="mute" {f.call.toggleMute()}
                else if action=="hangup" {f.call.hangUp()}
                else {try await f.call.sendText("改为讲小猫")}
                try await Task.sleep(nanoseconds:150_000_000)
                try require(users.isEmpty && count(f.wire,"response.create")==Int(action=="text" ? 1 : 0),"cancelled voice timer submitted an old turn")
                if action=="mute" {
                    f.call.toggleMute();await segment(f,"new",text:"现在讲小猫")
                    try await waitFor({users.count==1},seconds:1)
                    try require(users==["现在讲小猫"],"unmuting resurrected the cancelled clause")
                }
            }
        }),
        ("VT-018 a continued clause waits for its own late addressee decision",{
            let judge=TestVoiceIntent();judge.replies=[.listen]
            let f=try await fixture(judge:judge,commitDelay:70_000_000);defer{close(f);judge.finish(.keepSpeaking)}
            var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            await segment(f,"real",text:"我想听个故事")
            await segment(f,"side",text:"小明，你拿的是什么？")
            try await Task.sleep(nanoseconds:100_000_000)
            try require(users.isEmpty && count(f.wire,"response.create")==0,"the old timer bypassed a pending addressee decision")
            judge.finish(.keepSpeaking)
            try await waitFor({users.count==1},seconds:1)
            try require(users==["我想听个故事"],"side speech was merged into the accepted turn")
        }),
        ("VT-001 raw VAD leaves a spoken story and its visible speaking state intact",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first+"\n\n"+second)
            let before=f.audio.received.count
            await segment(f,"sound")
            f.speech.requests[0].chunk(Data(repeating:2,count:960));await settle()
            let session=f.wire.sent.first{$0["type"] as? String=="session.update"}?["session"] as? [String:Any]
            let vad=((session?["audio"] as? [String:Any])?["input"] as? [String:Any])?["turn_detection"] as? [String:Any]
            try require(vad?["interrupt_response"] as? Bool==false,"server can still interrupt independently")
            try require(f.audio.received.count==before+960 && f.audio.outputStops==0 && f.call.state == .speaking,"VAD stopped or relabelled the story")
            try require(count(f.wire,"response.cancel")==0 && count(f.wire,"response.create")==1,"VAD created or cancelled a turn")
        }),
        ("VT-002 backchannels noise and playback echo do not interrupt or produce replies",{
            let f=try await fixture();defer{close(f)};var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            try await start(f,first)
            for (index,text) in ["嗯","对对","哈哈","不要停","……",first].enumerated() {await segment(f,"noise-\(index)",text:text)}
            for index in 0..<3 {
                let id="failed-\(index)";await segment(f,id)
                f.wire.emit(["type":"conversation.item.input_audio_transcription.failed","item_id":id,"error":["code":"fixture"]]);await settle()
            }
            try require(f.call.active && f.call.state == .speaking && f.audio.outputStops==0 && users.isEmpty,"non-addressed input stopped the story or became a user message")
            try require(count(f.wire,"response.create")==1,"background input caused a new reply")
        }),
        ("VT-002 short answers after a question and outside playback remain valid",{
            let f=try await fixture();defer{close(f)};var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            try await start(f,"小兔到了奶奶家。你想看看它带来的苹果吗？")
            await segment(f,"answer",text:"好")
            f.speech.finish();await settle();f.audio.drainOutput();await settle()
            try require(users==["好"] && count(f.wire,"response.create")==2,"an answer to a question was treated as background acknowledgement")
            let idle=try await fixture();defer{close(idle)};var idleText="";idle.call.onUserText={_,text in idleText=text}
            await segment(idle,"idle-answer",text:"好")
            try require(idleText=="好" && count(idle.wire,"response.create")==1,"short input was globally blocked")
        }),
        ("VT-003 a meaningful question takes the turn before paragraph completion without a stop keyword",{
            let f=try await fixture();defer{close(f)};var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
            try await start(f,first+"\n\n"+second)
            let old=f.audio.playbackID
            await segment(f,"question",text:"小兔为什么要送苹果")
            try require(f.audio.outputStops==1 && users==["小兔为什么要送苹果"],"a real question was locked behind the paragraph")
            f.speech.finish();await settle()
            f.audio.onDrained?(old);await settle()
            try require(users==["小兔为什么要送苹果"] && count(f.wire,"response.create")==2,"queued question was lost or answered more than once")
            try require(f.speech.requests.count==1,"the next paragraph spoke over the question")
        }),
        ("VT-004 explicit partial stop and polite floor requests override paragraph protection",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first+"\n\n"+second)
            f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":"stop"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"stop","delta":"莉莉，请停一下。"]);await settle()
            try require(f.audio.paused && f.audio.pauses==1 && f.call.state == .listening,"a clear partial stop waited for the paragraph")
            f.wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":"stop"]);await settle()
            f.wire.emit(["type":"input_audio_buffer.committed","item_id":"stop"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"stop","transcript":"莉莉，请停一下。"]);await settle()
            try require(count(f.wire,"response.create")==1,"stop caused an automatic reply or continuation")
            let played=f.audio.received.count;f.speech.requests[0].chunk(Data(repeating:2,count:960));await settle()
            try require(f.audio.outputStops==1 && f.audio.received.count==played,"confirmed stop did not discard late output")
            try require(VoiceTurnPolicy.isUrgent("能不能暂停一下") && VoiceTurnPolicy.isUrgent("我想问一下，为什么会这样"),"natural explicit requests are not recognized")
            try require(!VoiceTurnPolicy.isUrgent("不要停下来") && !VoiceTurnPolicy.isUrgent("小兔说停一下"),"negation or story quotation triggered a stop")
            try require(!VoiceTurnPolicy.isUrgent("停一下是什么意思") && !VoiceTurnPolicy.isUrgent("“停一下”怎么说"),"a question about the command was treated as the command")
            try require(VoiceTurnPolicy.isUrgent("停一下",partial:true) && VoiceTurnPolicy.isUrgent("停一下，",partial:true),"a clear spoken command required punctuation")
            try require(!VoiceTurnPolicy.isControlOnly("停一下，小兔为什么带苹果") && VoiceTurnPolicy.isControlOnly("停一下，别讲了"),"the question after a stop was discarded")
        }),
        ("VT-005 a boundary waits for unfinished speech then resumes only unplayed paragraphs on failure",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first+"\n\n"+second)
            await segment(f,"unclear")
            f.speech.finish();await settle();f.audio.drainOutput();await settle()
            try require(f.speech.requests.count==1,"next paragraph began while input was unresolved")
            f.wire.emit(["type":"conversation.item.input_audio_transcription.failed","item_id":"unclear","error":["code":"fixture"]]);await settle()
            try require(f.speech.requests.map(\.text)==[first,second] && count(f.wire,"response.create")==1,"resumption repeated the first paragraph or asked the model to continue")
        }),
        ("VT-005 empty or timed-out boundary input recovers without restarting the story",{
            for timedOut in [false,true] {
                let f=try await fixture(timeout:30_000_000);defer{close(f)}
                try await start(f,first+"\n\n"+second);await segment(f,"lost")
                f.speech.finish();await settle();f.audio.drainOutput();await settle()
                if !timedOut {f.wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"lost","transcript":"……"])}
                try await waitFor({f.speech.requests.count==2},seconds:1)
                try require(f.speech.requests[1].text==second && count(f.wire,"response.create")==1,"boundary recovery lost the remaining paragraph")
            }
        }),
        ("VT-006 old chunks old drain callbacks and hangup cannot revive or skip paragraphs",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first+"\n\n"+second);let old=f.audio.playbackID
            f.speech.finish();await settle();f.audio.drainOutput();await settle()
            try require(f.speech.requests.count==2,"second paragraph did not begin")
            let before=f.audio.received.count;f.speech.requests[0].chunk(Data(repeating:3,count:960));f.audio.onDrained?(old);await settle()
            try require(f.audio.received.count==before && f.speech.requests.count==2,"old output resurfaced or advanced the new paragraph")
            f.speech.requests[1].chunk(Data(repeating:4,count:960));await settle();let heard=f.audio.received.count
            f.call.hangUp();f.speech.requests[1].chunk(Data(repeating:5,count:960));f.audio.drainOutput();f.speech.finish();await settle()
            try require(!f.call.active && f.audio.received.count==heard,"hangup allowed late speech")
        }),
        ("VT-007 meaningful conversational input yields after recognition rather than raw VAD",{
            let f=try await fixture();defer{close(f)}
            try await start(f,"我也想听听你今天的小发现。可以慢慢说。",prompt:"今天我很开心")
            f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":"chat"]);await settle()
            try require(f.audio.outputStops==0,"conversation was interrupted by VAD alone")
            f.wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":"chat"]);await settle()
            f.wire.emit(["type":"input_audio_buffer.committed","item_id":"chat"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"chat","transcript":"我看到了一只蓝蝴蝶"]);await settle()
            try require(f.audio.outputStops==1 && count(f.wire,"response.create")==2,"normal chat used the story paragraph lock")
        }),
        ("VT-007 VAD noise during an active tool does not invalidate its result",{
            let f=try await fixture();defer{close(f)};f.wire.delayToolOutput=true
            try await f.call.sendText("我喜欢什么")
            f.wire.emit(["type":"response.created","response":["id":"tool-response"]]);await settle()
            f.wire.emit(["type":"response.done","response":["id":"tool-response","status":"completed","output":[["type":"function_call","name":"recall_memories","call_id":"tool","arguments":"{}"]]]]);await settle()
            await segment(f,"noise",text:"……")
            try await waitFor({count(f.wire,"response.create")==2},seconds:1)
            try require(count(f.wire,"response.cancel")==0,"unrecognized sound discarded the tool turn")
        }),
        ("VT-008 paragraph boundaries preserve words quotation and the chosen teacher voice",{
            let prose=String(repeating:"小兔抱着苹果，奶奶正在等它。",count:13)
            let parts=StoryParagraphs.split(prose)
            try require(parts.count>1 && parts.joined()==prose && parts.dropLast().allSatisfy{$0.hasSuffix("。")},"fallback splitting cut a comma or lost text")
            let quote="小兔说：“"+String(repeating:"我们走到小河边。",count:18)+"”奶奶笑了。"
            let quoted=StoryParagraphs.split(quote)
            try require(quoted.joined()==quote && !quoted.dropLast().contains{!$0.hasSuffix("”") && $0.contains("“")},"quotation was split mid-speech")
            let f=try await fixture();defer{close(f)}
            try await start(f,first+"\n\n"+second);f.speech.finish();await settle();f.audio.drainOutput();await settle()
            try require(f.speech.requests.map(\.text)==[first,second] && f.speech.requests.allSatisfy{$0.speaker=="Serena"},"paragraphs changed order or teacher identity")
        }),
        ("VT-010 live transcription acts before commit while microphone packets keep flowing",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first)
            f.audio.onMicrophone?(Data(repeating:1,count:960));await settle()
            f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":"live"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"live","delta":"不是小兔，是小猫"]);await settle()
            try require(f.audio.paused && f.call.transcriptDeltasBeforeCommit==1,"live correction waited for audio commit")
            f.audio.onMicrophone?(Data(repeating:2,count:960));await settle()
            try require(f.call.inputPackets==2 && f.call.inputPacketsWhileSpeaking==1 && count(f.wire,"input_audio_buffer.append")==2,"pausing speech paused the microphone")
            let session=f.wire.sent.first{$0["type"] as? String=="session.update"}?["session"] as? [String:Any]
            let transcription=((session?["audio"] as? [String:Any])?["input"] as? [String:Any])?["transcription"] as? [String:Any]
            try require(transcription?["model"] as? String=="gpt-live-transcribe" && transcription?["delay"] as? String=="medium","continuous preview or its accuracy setting changed")
        }),
        ("VT-011 contextual important sharing yields without requiring a command or question mark",{
            let judge=TestVoiceIntent();judge.replies=[.listen,.listen]
            let f=try await fixture(judge:judge);defer{close(f);judge.finish(.keepSpeaking)}
            try await start(f,first)
            f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":"sharing"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"sharing","delta":"我的朋友刚来我家"]);await settle()
            try require(f.audio.paused && judge.queries.first?.isFinal==false && judge.queries.first?.assistantSpeech==first,"contextual review did not receive the current speech or yield")
            await f.wire.finishInput("sharing","我的朋友刚来我家")
            try require(count(f.wire,"response.create")==2 && f.audio.outputStops==1,"important completed sharing remained queued")
        }),
        ("VT-011 contextual listener reaction can leave the story speaking",{
            let judge=TestVoiceIntent();judge.replies=[.keepSpeaking]
            let f=try await fixture(judge:judge);defer{close(f);judge.finish(.keepSpeaking)}
            try await start(f,first)
            await segment(f,"reaction",text:"哇这个有点意思")
            try require(f.call.state == .speaking && f.audio.pauses==0 && count(f.wire,"response.create")==1,"a contextual acknowledgement stole the turn")
        }),
        ("VT-011 review timeout yields to a complete request and late results cannot reclaim speech",{
            let judge=TestVoiceIntent()
            let f=try await fixture(judge:judge,intentTimeout:30_000_000);defer{close(f);judge.finish(.keepSpeaking)}
            try await start(f,first)
            await segment(f,"request",text:"我的朋友刚来我家")
            try await waitFor({count(f.wire,"response.create")==2},seconds:1)
            judge.finish(.keepSpeaking);await settle()
            try require(f.call.active && f.audio.outputStops==1 && f.audio.resumes==0 && count(f.wire,"response.create")==2,"a slow classifier blocked the user or revived the old story")
        }),
        ("VT-012 a corrected partial acknowledgement resumes the existing audio without regeneration",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first+"\n\n"+second);let original=f.audio.playbackID
            f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":"uncertain"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"uncertain","delta":"为什么"]);await settle()
            try require(f.audio.paused && f.audio.playbackID==original,"partial listening did not preserve the playback buffer")
            f.speech.finish();await settle()
            await f.wire.finishInput("uncertain","嗯，好的")
            try require(!f.audio.paused && f.audio.resumes==1 && f.audio.outputStops==0 && f.audio.playbackID==original,"false interruption restarted or discarded audio")
            try require(f.speech.requests.count==1 && count(f.wire,"response.create")==1 && f.call.state == .speaking,"recovery regenerated the story")
        }),
        ("VT-012 failed recognition releases a provisional pause and hangup never resumes",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first)
            f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":"failed"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"failed","delta":"为什么"]);await settle()
            f.wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":"failed"]);await settle()
            f.wire.emit(["type":"input_audio_buffer.committed","item_id":"failed"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.failed","item_id":"failed","error":["code":"fixture"]]);await settle()
            try require(f.audio.resumes==1 && f.call.state == .speaking,"recognition failure left a permanent pause")
            f.call.hangUp();f.audio.drainOutput();await settle()
            try require(!f.call.active && f.audio.resumes==1,"hangup restarted the previous output")
        }),
        ("VT-004 stop after a discarded acknowledgement does not delete that item twice",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first)
            await segment(f,"ack",text:"嗯，好的")
            await segment(f,"stop",text:"我说你先别讲了")
            let deletes=f.wire.sent.filter{$0["type"] as? String=="conversation.item.delete" && $0["item_id"] as? String=="ack"}
            try require(deletes.count==1 && f.call.active && f.call.state == .listening,"stop repeated an acknowledged deletion or ended the call")
        }),
        ("VT-013 side conversations are reviewed both during playback and while waiting",{
            for playing in [false,true] {
                let judge=TestVoiceIntent();judge.replies=[.keepSpeaking,.keepSpeaking]
                let f=try await fixture(judge:judge);defer{close(f);judge.finish(.keepSpeaking)}
                var users:[String]=[];f.call.onUserText={_,text in users.append(text)}
                if playing {try await start(f,first+"你想听后面吗？")}
                let before=count(f.wire,"response.create")
                await segment(f,"family",text:"妈妈，你能帮我拿一下杯子吗？")
                await segment(f,"other",text:"小明，作业写完了吗？")
                try require(judge.queries.count==2 && users.isEmpty && count(f.wire,"response.create")==before,"a side question bypassed addressee review")
                try require(f.audio.pauses==0 && f.audio.outputStops==0,"side speech interrupted playback")
                let deleted=f.wire.sent.filter{$0["type"] as? String=="conversation.item.delete"}.compactMap{$0["item_id"] as? String}
                try require(deleted.contains("family") && deleted.contains("other"),"rejected conversation remained in model context")
                try require(f.call.state == (playing ? .speaking : .listening),"ignoring a bystander left the call thinking")
            }
        }),
        ("VT-014 partial controls addressed to family do not preempt semantic review",{
            let judge=TestVoiceIntent();judge.replies=[.keepSpeaking,.keepSpeaking]
            let f=try await fixture(judge:judge);defer{close(f);judge.finish(.keepSpeaking)}
            try await start(f,first)
            f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":"family"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"family","delta":"等一下，爸爸，帮我拿杯子"]);await settle()
            try require(f.audio.pauses==0 && judge.queries.count==1,"a quoted or other-directed control used the stop fast path")
            await f.wire.finishInput("family","等一下，爸爸，帮我拿杯子")
            try require(f.audio.outputStops==0 && count(f.wire,"response.create")==1,"family direction cancelled the story")
        }),
        ("VT-014 family mentions role play and directly addressed requests remain conversational",{
            for (speech,words) in [(first,"妈妈今天为什么很累"),("我们来演故事，我演妈妈，你演小兔。","妈妈，你为什么拿走我的苹果？")] {
                let judge=TestVoiceIntent();judge.replies=[.listen]
                let f=try await fixture(judge:judge);defer{close(f);judge.finish(.keepSpeaking)}
                try await start(f,speech);await segment(f,"real-question",text:words)
                try require(count(f.wire,"response.create")==2 && judge.queries.first?.assistantSpeech==speech,"family words were globally rejected or role-play context lost")
            }
            let judge=TestVoiceIntent()
            let f=try await fixture(judge:judge);defer{close(f);judge.finish(.keepSpeaking)}
            try await start(f,first);await segment(f,"direct",text:"莉莉，为什么会下雨？")
            try require(count(f.wire,"response.create")==2 && judge.queries.isEmpty,"directly addressed question unnecessarily waited for a classifier")
        }),
        ("VT-015 failed or missing classification ignores only explicit household directions",{
            for withJudge in [false,true] {
                let judge=TestVoiceIntent()
                let f=try await fixture(judge:withJudge ? judge : nil,intentTimeout:30_000_000);defer{close(f);judge.finish(.listen)}
                try await start(f,first)
                await segment(f,"side",text:"妈妈，你能不能帮我拿杯子")
                if withJudge {try await waitFor({f.wire.sent.contains{$0["type"] as? String=="conversation.item.delete" && $0["item_id"] as? String=="side"}},seconds:1)}
                judge.finish(.listen);await settle()
                try require(f.audio.outputStops==0 && f.audio.pauses==0 && count(f.wire,"response.create")==1,"timeout or late judgment turned household speech into a reply")
                await segment(f,"direct-stop",text:"莉莉，停一下")
                try require(f.audio.outputStops==1 && f.call.state == .listening,"fallback blocked a real stop")
            }
            try require(VoiceTurnPolicy.fallbackIntent("妈妈今天为什么很累",context:.init(),final:true) == .listen,"a family mention was treated as a household command")
        }),
        ("VT-009 interruption retains fully heard paragraphs without inventing a word cursor",{
            let f=try await fixture();defer{close(f)}
            try await start(f,first+"\n\n"+second);f.speech.finish();await settle();f.audio.drainOutput();await settle()
            f.speech.requests[1].chunk(Data(repeating:1,count:960));await settle()
            await segment(f,"stop",text:"停一下")
            let notes=f.wire.sent.compactMap{($0["item"] as? [String:Any])}.filter{$0["role"] as? String=="assistant"}
            let note=(notes.last?["content"] as? [[String:Any]])?.first?["text"] as? String ?? ""
            try require(note.contains(first) && !note.contains(second) && note.contains("没有完整播放"),"context claims an unplayed paragraph was heard")
        })
    ]
}
