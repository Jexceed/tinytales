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
    func fixture(timeout:UInt64=12_000_000_000,judge:VoiceIntentJudging?=nil,intentTimeout:UInt64=1_200_000_000) async throws -> Fixture {
        let wire=TestWire(),audio=SilentCallAudio(),speech=FakeTeacherSpeech();audio.manualDrain=true
        let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{true},voice:"teacher",transcriptionTimeout:timeout,inputCommitDelay:0,teacherSpeech:speech,intentJudge:judge,intentTimeout:intentTimeout)
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
            try require(transcription?["model"] as? String=="gpt-live-transcribe" && transcription?["delay"] as? String=="low","committed-only ASR returned")
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
