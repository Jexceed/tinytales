import Foundation
import AppKit

@MainActor final class FakeFinalSpeech:FinalSpeechRecognizing {
    var requests:[Data]=[]
    var contexts:[SpeechRecognitionContext]=[]
    var automaticallyConfirm=true
    var pending:[CheckedContinuation<String,Error>?]=[]
    func transcribeFinal(_ wav:Data) async throws -> String {
        requests.append(wav)
        return try await withCheckedThrowingContinuation{pending.append($0)}
    }
    func transcribeFinal(_ wav:Data,context:SpeechRecognitionContext) async throws -> String {
        contexts.append(context)
        if automaticallyConfirm,context.isConfirmation {return context.firstPassText}
        return try await transcribeFinal(wav)
    }
    func finish(_ index:Int,_ text:String) {
        guard pending.indices.contains(index),let continuation=pending[index] else{return}
        pending[index]=nil;continuation.resume(returning:text)
    }
    func fail(_ index:Int) {
        guard pending.indices.contains(index),let continuation=pending[index] else{return}
        pending[index]=nil;continuation.resume(throwing:PartnerError.message("fixture failure"))
    }
    func close() {for index in pending.indices {finish(index,"")}}
}

@MainActor final class ReliabilityFixture {
    let store:LocalStore,wire=TestWire(),audio=SilentCallAudio(),speech=FakeTeacherSpeech(),recognizer=FakeFinalSpeech()
    let call:RealtimeCall
    var milliseconds=0,uploaded=0
    var users:[(String,String)]=[]
    init(delay:UInt64=0,timeout:UInt64=8_000_000_000,judge:VoiceIntentJudging?=nil,illustrator:((IllustrationRequest) async throws -> GeneratedArtwork)?=nil) throws {
        store=try phoneFixture();audio.manualDrain=true
        call=RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},voice:"teacher",illustrator:illustrator,inputCommitDelay:delay,teacherSpeech:speech,intentJudge:judge,finalRecognizer:recognizer,finalRecognitionTimeout:timeout)
        call.onUserText={[weak self] id,text in self?.users.append((id,text))}
    }
    func connect() async throws {
        try await call.connect(history:[],microphone:true,greet:false)
        wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
    }
    func input(_ id:String,_ raw:String,commit:Bool=true,emitTranscript:Bool=true) async throws {
        wire.emit(["type":"input_audio_buffer.speech_started","item_id":id,"audio_start_ms":milliseconds]);await settle()
        let data=Data(repeating:3,count:48_000);uploaded+=data.count
        audio.onMicrophone?(data)
        try await waitFor({self.wire.deliveredAudio.reduce(0){$0+$1.count}>=self.uploaded},seconds:2)
        milliseconds+=1000
        wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":id,"audio_end_ms":milliseconds]);await settle()
        if commit {wire.emit(["type":"input_audio_buffer.committed","item_id":id]);await settle()}
        if emitTranscript {wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":id,"transcript":raw]);await settle()}
    }
    func reply(_ text:String,id:String="reply") async throws {
        wire.emit(["type":"response.created","response":["id":id]]);await settle()
        wire.emit(["type":"response.output_text.delta","response_id":id,"item_id":id+"-text","delta":text]);await settle()
        wire.emit(["type":"response.done","response":["id":id,"status":"completed","output":[["id":id+"-text","type":"message","content":[["type":"output_text","text":text]]]]]]);await settle()
        try await waitFor({!self.speech.requests.isEmpty},seconds:1)
        speech.requests.last!.chunk(Data(repeating:1,count:9600));await settle()
    }
    var responseCount:Int {wire.sent.filter{$0["type"] as? String=="response.create"}.count}
    var userTexts:[String] {users.map{$0.1}}
    func close() {call.hangUp();recognizer.close();speech.finish();try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
}

@MainActor func voiceReliabilityTestCases()->[(String,@MainActor () async throws -> Void)] {
    func ready(delay:UInt64=0,timeout:UInt64=8_000_000_000,judge:VoiceIntentJudging?=nil) async throws -> ReliabilityFixture {
        let f=try ReliabilityFixture(delay:delay,timeout:timeout,judge:judge);try await f.connect();return f
    }
    return [
        ("VR-010 correct live words cannot be silently replaced by a conflicting final pass",{
            let f=try await ready(delay:60_000_000);defer{f.close()}
            f.recognizer.automaticallyConfirm=false
            try await f.input("poem","举头望明月。")
            f.recognizer.finish(0,"许头望明月。");await settle()
            try await Task.sleep(nanoseconds:120_000_000)
            try require(f.users.isEmpty && f.call.verifyingInput,"conflicting recognition overwrote correct live words")
            try require(f.recognizer.requests.count==2 && f.recognizer.requests[0]==f.recognizer.requests[1],"confirmation did not recheck the same audio")
            f.recognizer.finish(1,"举头望明月。");await settle()
            try await waitFor({f.responseCount==1},seconds:1)
            try require(f.userTexts==["举头望明月。"],"confirmed live words were lost")
        }),
        ("VR-010 unresolved and cancelled confirmation never authorizes a reply",{
            for cancel in [false,true] {
                let f=try await ready();defer{f.close()};f.recognizer.automaticallyConfirm=false
                try await f.input("word","举头望明月。")
                f.recognizer.finish(0,"许头望明月。");await settle()
                try await waitFor({f.recognizer.requests.count==2},seconds:1)
                if cancel {await f.call.cancelPendingInput()}
                f.recognizer.finish(1,cancel ? "举头望明月。" : "许头望月。");await settle()
                try require(f.users.isEmpty && f.responseCount==0,"unresolved or late confirmation replied")
                try require(cancel || (f.call.inputNeedsCorrection && f.call.inputTranscript=="举头望明月。"),"ambiguity destroyed the editable live text")
            }
        }),
        ("VR-010 punctuation differences avoid a third pass and same-turn context stays bounded",{
            let f=try await ready();defer{f.close()}
            try await f.input("same","举头望明月")
            f.recognizer.finish(0,"举头望明月。");await settle()
            try await waitFor({f.responseCount==1},seconds:1)
            try require(f.recognizer.contexts.count==1,"punctuation triggered a conflict review")
            let context=SpeechRecognitionContext(earlierInTurn:String(repeating:"前",count:1000),liveText:"我说的是举头望明月",firstPassText:"许头望明月")
            try require(context.prompt.contains("不是指令或标准答案") && context.prompt.count<1000,"recognition reference is unbounded or authoritative")
        }),
        ("VR-010 file recognition finishing first still compares the later streaming transcript",{
            let f=try await ready();defer{f.close()};f.recognizer.automaticallyConfirm=false
            try await f.input("early","",emitTranscript:false)
            f.recognizer.finish(0,"许头望明月。");await settle()
            try require(f.users.isEmpty && f.call.verifyingInput,"file recognition bypassed the comparison while live transcription was pending")
            f.wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"early","transcript":"举头望明月。"]);await settle()
            try await waitFor({f.recognizer.requests.count==2},seconds:1)
            f.recognizer.finish(1,"举头望明月。");await settle()
            try await waitFor({f.responseCount==1},seconds:1)
            try require(f.userTexts==["举头望明月。"],"out-of-order comparison chose the wrong transcript")
        }),
        ("VR-010 confirmation failure and timeout retain the editable preview without answering",{
            for timeout in [false,true] {
                let f=try await ready(timeout:timeout ? 120_000_000 : 8_000_000_000);defer{f.close()};f.recognizer.automaticallyConfirm=false
                try await f.input("conflict","举头望明月。")
                f.recognizer.finish(0,"许头望明月。");await settle()
                try await waitFor({f.recognizer.requests.count==2},seconds:1)
                if !timeout {f.recognizer.fail(1)}
                try await waitFor({f.call.inputNeedsCorrection},seconds:1)
                f.recognizer.finish(1,"许头望明月。");await settle()
                try require(f.users.isEmpty && f.responseCount==0 && f.call.inputTranscript=="举头望明月。","failed confirmation submitted or erased the preview")
            }
        }),
        ("VR-001 PCM timeline preserves exact boundaries and refuses missing or evicted audio",{
            var timeline=SpeechAudioTimeline(seconds:1)
            let a=Data(repeating:1,count:24_000),b=Data(repeating:2,count:24_000)
            timeline.append(a);timeline.append(b)
            try require(timeline.audio(startMS:0,endMS:500)==a && timeline.audio(startMS:500,endMS:1000)==b,"PCM boundaries changed")
            try require(timeline.audio(startMS:0,endMS:1001)==nil && timeline.audio(startMS:-1,endMS:1)==nil,"missing audio was fabricated")
            timeline.append(Data(repeating:3,count:96_000))
            try require(timeline.audio(startMS:0,endMS:500)==nil && timeline.audio(startMS:2500,endMS:3000)==Data(repeating:3,count:24_000),"rolling eviction rewound the session clock")
            timeline.reset();try require(timeline.retainedBytes==0 && timeline.durationMilliseconds==0,"hangup retained samples")
        }),
        ("VR-001 uploaded frames are captured once and muted input does not shift the audio clock",{
            let f=try await ready();defer{f.close()}
            f.call.toggleMute();f.audio.onMicrophone?(Data(repeating:9,count:48_000));await settle();f.call.toggleMute()
            try await f.input("a","错误字幕")
            try require(f.recognizer.requests.count==1 && f.recognizer.requests[0].count==48_044,"muted or repeated frames entered the audio slice")
            try require(Data(f.recognizer.requests[0].dropFirst(44))==Data(repeating:3,count:48_000),"captured PCM did not match uploaded audio")
        }),
        ("VR-002 verified drawing request replaces wrong live text and native audio before the response",{
            let f=try await ready();defer{f.close()}
            try await f.input("raw-picture","今天画上的故事")
            try require(f.users.isEmpty && f.responseCount==0 && f.call.verifyingInput,"unverified subtitles authorized an answer")
            f.recognizer.finish(0,"给我画一张图片。")
            try await waitFor({f.responseCount==1},seconds:1)
            let entries=f.wire.sent.compactMap{$0["item"] as? [String:Any]}
            let input=entries.last{$0["role"] as? String=="user"}
            let content=(input?["content"] as? [[String:Any]])?.first
            try require(entries.compactMap{$0["id"] as? String}.allSatisfy{$0.count<=32},"client item IDs exceed the Realtime API limit")
            try require(f.userTexts==["给我画一张图片。"] && content?["type"] as? String=="input_text" && content?["text"] as? String==f.userTexts.first,"display and model inputs diverged")
            let delete=f.wire.sent.firstIndex{$0["type"] as? String=="conversation.item.delete" && $0["item_id"] as? String=="raw-picture"}
            let create=f.wire.sent.firstIndex{($0["item"] as? [String:Any])?["role"] as? String=="user"}
            try require(delete != nil && create != nil && delete!<create!,"native audio remained authoritative")
            let response=f.wire.sent.last{$0["type"] as? String=="response.create"}?["response"] as? [String:Any]
            try require((response?["tool_choice"] as? [String:Any])?["name"] as? String=="illustrate_story","drawing was routed as another story")
        }),
        ("VR-003 out-of-order final recognition keeps both clauses and their addressee context",{
            let judge=TestVoiceIntent();judge.replies=[.listen,.listen]
            let f=try await ready(delay:60_000_000,judge:judge);defer{f.close();judge.finish(.listen)}
            try await f.input("first","给我讲一个")
            try await f.input("second","今天故事")
            f.recognizer.finish(1,"老巫婆的故事。" );await settle()
            try require(f.users.isEmpty && judge.queries.isEmpty,"later recognition skipped the earlier clause")
            f.recognizer.finish(0,"给我讲一个")
            try await waitFor({f.responseCount==1},seconds:1)
            try require(f.userTexts==["给我讲一个老巫婆的故事。"] && judge.queries.last?.earlierInTurn=="给我讲一个","verified clauses lost their context")
            f.wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"second","transcript":"迟到的错误" ]);await settle()
            try require(f.responseCount==1 && f.userTexts.count==1 && f.recognizer.requests.count==2,"duplicate live text re-ran a turn")
        }),
        ("VR-003 recognition finishing before the server commit cannot delete an uncreated item or reply",{
            let f=try await ready();defer{f.close()}
            try await f.input("early","是一个老巫婆",commit:false)
            f.recognizer.finish(0,"是一个老巫婆。" );await settle()
            try require(f.responseCount==0 && f.users.isEmpty,"recognition raced ahead of the server audio commit")
            f.wire.emit(["type":"input_audio_buffer.committed","item_id":"early"]);await settle()
            try await waitFor({f.responseCount==1},seconds:1)
        }),
        ("VR-003 explicit stop does not wait for slow final recognition or the continuation window",{
            let f=try await ready(delay:VoiceTurns.continuationDelay);defer{f.close()}
            try await f.call.sendText("讲一个故事");try await f.reply("小猫沿着花园的小路慢慢走。")
            try await f.input("stop","莉莉，停一下。")
            try require(f.call.state == .listening && f.audio.outputStops>0 && f.responseCount==1,"a clear stop waited for ASR")
            f.recognizer.finish(0,"讲一个故事。" );await settle()
            try require(f.responseCount==1 && f.call.active,"late recognition restarted the story")
        }),
        ("VR-004 manual stop immediately halts playback but keeps the microphone and connection alive",{
            let f=try await ready();defer{f.close()}
            try await f.call.sendText("讲个故事");try await f.reply("小兔抱着苹果去找奶奶。")
            let stops=f.audio.stops
            f.wire.delayedTypes.insert("conversation.item.delete")
            let stopping=Task{await f.call.stopCurrentTurn()};await settle()
            try require(f.audio.outputStops==1 && f.audio.stops==stops && f.call.active,"manual stop waited for the network or hung up")
            await stopping.value
            let bytes=f.audio.received.count
            f.speech.requests[0].chunk(Data(repeating:2,count:960));await settle()
            try require(f.audio.received.count==bytes && f.call.state == .listening,"late TTS chunks resumed cancelled playback")
        }),
        ("VR-004 stopping before a response starts rejects its late server events",{
            let f=try await ready();defer{f.close()}
            try await f.call.sendText("讲个故事")
            await f.call.stopCurrentTurn()
            f.wire.emit(["type":"response.created","response":["id":"late"]]);await settle()
            f.wire.emit(["type":"response.output_text.delta","response_id":"late","item_id":"late-text","delta":"继续讲旧故事"]);await settle()
            try require(f.speech.requests.isEmpty && f.call.active && f.wire.sent.contains{$0["type"] as? String=="response.cancel"},"late generation escaped the stop")
        }),
        ("VR-004 stopping while a tool result is in flight prevents its follow-up response",{
            let f=try await ready();defer{f.close()}
            f.wire.delayToolOutput=true
            try await f.call.sendText("我喜欢什么")
            f.wire.emit(["type":"response.created","response":["id":"tools"]]);await settle()
            f.wire.emit(["type":"response.done","response":["id":"tools","status":"completed","output":[["id":"tool-call","type":"function_call","name":"recall_memories","call_id":"lookup","arguments":"{}"]]]]);await settle()
            await f.call.stopCurrentTurn();try await Task.sleep(nanoseconds:100_000_000)
            try require(f.responseCount==1 && f.call.active && f.call.state == .listening,"a stopped tool generated a follow-up")
        }),
        ("VR-004 a picture completing after manual cancellation is neither published nor saved",{
            let image=NSImage(size:NSSize(width:16,height:16));image.lockFocus();NSColor.orange.setFill();NSRect(x:0,y:0,width:16,height:16).fill();image.unlockFocus()
            let png=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            var pending:CheckedContinuation<GeneratedArtwork,Error>?,published=0
            let f=try ReliabilityFixture(illustrator:{_ in try await withCheckedThrowingContinuation{pending=$0}})
            defer{pending?.resume(throwing:CancellationError());f.close()}
            try await f.connect();f.call.onArtwork={_,_ in published+=1}
            try await f.call.sendText("给我画一张图片")
            f.wire.emit(["type":"response.created","response":["id":"drawing"]]);await settle()
            f.wire.emit(["type":"response.done","response":["id":"drawing","status":"completed","output":[["id":"drawing-call","type":"function_call","name":"illustrate_story","call_id":"draw","arguments":"{}"]]]]);await settle()
            try await waitFor({pending != nil},seconds:1)
            await f.call.stopCurrentTurn()
            let completion=pending;pending=nil
            completion?.resume(returning:GeneratedArtwork(data:png,caption:"橙色的画面。",source:Story(title:"橙色",summary:"橙色的画面。")))
            try await Task.sleep(nanoseconds:30_000_000)
            try require(published==0 && f.responseCount==1 && f.call.active && (try f.store.stories()).isEmpty,"cancelled image escaped into the UI or story store")
        }),
        ("VR-005 cancel input ignores late recognition and allows the next utterance",{
            let f=try await ready();defer{f.close()}
            try await f.input("cancelled","今天画上的故事")
            await f.call.cancelPendingInput();f.recognizer.finish(0,"给我画一张图片");await settle()
            try require(f.users.isEmpty && f.responseCount==0 && f.call.inputTranscript.isEmpty && f.call.active,"cancelled input still reached the model")
            try await f.input("next","今天的话")
            f.recognizer.finish(1,"说说月亮吧。");try await waitFor({f.responseCount==1},seconds:1)
            try require(f.userTexts==["说说月亮吧。"],"cancellation broke the next audio span")
        }),
        ("VR-005 cancellation before commit removes the later-created audio item exactly once",{
            let f=try await ready();defer{f.close()}
            try await f.input("cancelled","讲个故事",commit:false)
            await f.call.cancelPendingInput()
            f.wire.emit(["type":"input_audio_buffer.committed","item_id":"cancelled"]);await settle()
            f.recognizer.finish(0,"讲个故事");await settle()
            try require(f.users.isEmpty && f.wire.sent.filter{$0["type"] as? String=="conversation.item.delete" && $0["item_id"] as? String=="cancelled"}.count==1,"uncommitted cancellation left an audio item or duplicated deletion")
        }),
        ("VR-006 retraction removes canonical input and related replies from the current context",{
            let f=try await ready();defer{f.close()}
            try await f.input("raw","错误故事");f.recognizer.finish(0,"讲小猫的故事")
            try await waitFor({f.users.count==1},seconds:1)
            try await f.reply("小猫正在草地上散步。")
            var retracted:String?,related=Set<String>()
            f.call.onVoiceInputRetracted={retracted=$0;related=$1}
            let originalID=f.users[0].0,text=await f.call.retractLatestVoiceInput()
            try require(text=="讲小猫的故事" && retracted==originalID && related.contains("reply-text") && f.call.latestVoiceInputID==nil,"retraction lost its message association")
            let deleted=f.wire.sent.filter{$0["type"] as? String=="conversation.item.delete"}.compactMap{$0["item_id"] as? String}
            try require(deleted.contains(originalID) && deleted.filter{$0=="reply-text"}.count==1 && f.call.active,"withdrawn input remained on the server, was deleted twice, or hung up")
            try await f.call.sendText("给我画一张图片")
            try require(f.responseCount==2,"corrected text could not start a new response")
        }),
        ("VR-007 a failed final pass never falls back to incorrect live subtitles",{
            let f=try await ready();defer{f.close()}
            try await f.input("bad","今天画上的故事");f.recognizer.fail(0)
            try await waitFor({f.call.inputNeedsCorrection},seconds:1)
            try require(f.users.isEmpty && f.responseCount==0 && f.call.active && f.call.inputTranscript=="今天画上的故事","failure authorized wrong text or hid the editable draft")
            try await f.call.sendText("给我画一张图片")
            try require(f.responseCount==1 && !f.call.inputNeedsCorrection,"typed correction did not recover")
        }),
        ("VR-006 a fast corrected request waits until withdrawn server context is removed",{
            let f=try await ready();defer{f.close()}
            try await f.input("raw","错误故事");f.recognizer.finish(0,"讲小猫的故事")
            try await waitFor({f.users.count==1},seconds:1)
            let original=f.users[0].0
            f.wire.delayedTypes.insert("conversation.item.delete")
            let retract=Task{await f.call.retractLatestVoiceInput()};await settle()
            let corrected=Task{try await f.call.sendText("给我画一张图片")};await settle()
            try require(f.responseCount==1,"new response ran before retraction cleanup completed")
            await retract.value;try await corrected.value
            let deletion=f.wire.sent.firstIndex{$0["type"] as? String=="conversation.item.delete" && $0["item_id"] as? String==original}
            let replacement=f.wire.sent.lastIndex{(($0["item"] as? [String:Any])?["content"] as? [[String:Any]])?.first?["text"] as? String=="给我画一张图片"}
            try require(deletion != nil && replacement != nil && deletion!<replacement! && f.responseCount==2,"corrected text raced with stale context")
        }),
        ("VR-007 timeout invalidates late recognition without ending the call",{
            let f=try await ready(timeout:45_000_000);defer{f.close()}
            try await f.input("late","错误文字")
            try await waitFor({f.call.inputNeedsCorrection},seconds:1)
            f.recognizer.finish(0,"给我画图");await settle()
            try require(f.call.active && !f.call.verifyingInput && f.users.isEmpty && f.responseCount==0,"timed-out ASR came back to life")
        }),
        ("VR-007 missing audio offers correction without sending unrelated buffered audio",{
            let f=try await ready();defer{f.close()}
            f.wire.emit(["type":"input_audio_buffer.speech_started","item_id":"missing","audio_start_ms":0]);await settle()
            f.wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":"missing","audio_end_ms":1000]);await settle()
            f.wire.emit(["type":"input_audio_buffer.committed","item_id":"missing"]);await settle()
            f.wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"missing","transcript":"猜出来的故事"]);await settle()
            try require(f.recognizer.requests.isEmpty && f.call.inputNeedsCorrection && f.responseCount==0,"missing PCM fell back to guessed words")
        }),
        ("VR-008 empty final recognition and bystander speech do not create requests",{
            let judge=TestVoiceIntent();judge.replies=[.keepSpeaking]
            let f=try await ready(judge:judge);defer{f.close();judge.finish(.keepSpeaking)}
            try await f.input("noise","谢谢观看");f.recognizer.finish(0,"");await settle()
            try await f.input("side","画图");f.recognizer.finish(1,"妈妈，帮我拿一下杯子。");await settle()
            try require(f.responseCount==0 && f.users.isEmpty && f.call.active,"noise or household speech triggered a reply")
        }),
        ("VR-008 a failed streaming recognizer can still recover from the captured audio",{
            let f=try await ready();defer{f.close()}
            try await f.input("recover","")
            f.wire.emit(["type":"conversation.item.input_audio_transcription.failed","item_id":"recover","error":["code":"fixture"]]);await settle()
            f.recognizer.finish(0,"是一个老巫婆。")
            try await waitFor({f.responseCount==1},seconds:1)
            try require(f.userTexts==["是一个老巫婆。"],"streaming failure discarded recoverable audio")
        }),
        ("VR-009 hanging up during correction preserves its draft and clears the editing state",{
            let f=try ReliabilityFixture();defer{f.close()}
            let app=AppModel(store:f.store,keyProvider:{"fixture"},callFactory:{_,_,_,_ in f.call});defer{app.cancel()}
            app.toggleCall();await settle();f.wire.emit(["type":"session.created"]);await settle();f.wire.emit(["type":"session.updated"]);await settle()
            try await f.input("raw","今天画上的故事");f.recognizer.finish(0,"今天画上的故事")
            try await waitFor({app.messages.contains{$0.isUser}},seconds:1)
            app.editVoiceInput(app.messages.first{$0.isUser}?.externalID)
            try await waitFor({app.isCorrectingVoice},seconds:1)
            app.voiceCorrectionText="给我画一张图片";app.toggleCall();await settle()
            try require(!app.inCall && !app.isCorrectingVoice && app.draft=="给我画一张图片","hangup hid the correction text or left stale editing controls")
        }),
        ("VR-009 shared app controls edit the latest voice message without losing an unsent draft",{
            let f=try ReliabilityFixture();defer{f.close()}
            let app=AppModel(store:f.store,keyProvider:{"fixture"},callFactory:{_,_,_,_ in f.call});defer{app.cancel()}
            app.draft="下次想问的话";app.toggleCall();await settle()
            f.wire.emit(["type":"session.created"]);await settle();f.wire.emit(["type":"session.updated"]);await settle()
            try await f.input("raw","今天画上的故事");f.recognizer.finish(0,"今天画上的故事")
            try await waitFor({app.messages.contains{$0.isUser}},seconds:1)
            let message=app.messages.first{$0.isUser}!
            try require(app.canCorrectVoice(message),"latest voice bubble did not expose correction")
            app.editVoiceInput(message.externalID)
            try await waitFor({app.isCorrectingVoice},seconds:1)
            try require(f.call.muted && app.messages.first{$0.isUser}?.isRetracted==true && app.draft=="下次想问的话","editing lost history or the unrelated draft")
            app.voiceCorrectionText="给我画一张图片";app.sendVoiceCorrection();await settle()
            try require(!app.isCorrectingVoice && !f.call.muted && app.draft=="下次想问的话","correction did not restore listening and the unsent draft")
            try require(app.conversationTitle.contains("给我画"),"the withdrawn transcript still named the conversation")
            try require(app.messages.filter{$0.isUser && !$0.isRetracted}.count==1 && app.inCall,"correction duplicated an active user message or ended the call")
            app.toggleCall();await settle();app.toggleCall();await settle()
            f.wire.emit(["type":"session.created"]);await settle()
            let session=f.wire.sent.last{$0["type"] as? String=="session.update"}?["session"] as? [String:Any]
            let instructions=session?["instructions"] as? String ?? ""
            try require(instructions.contains("给我画一张图片") && !instructions.contains("今天画上的故事"),"withdrawn misrecognition returned when reconnecting")
        })
    ]
}
