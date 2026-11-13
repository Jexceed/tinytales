import Foundation

@MainActor final class FakeTeacherSpeech:TeacherSpeech {
    var prepared=0
    var requests:[(text:String,speaker:String,chunk:@MainActor (Data)->Void)]=[]
    var pending:[CheckedContinuation<Void,Error>]=[]
    var pausePreparation=false
    var readyWaiters:[CheckedContinuation<Void,Error>]=[]
    func prepare() async throws {prepared+=1;if pausePreparation{try await withCheckedThrowingContinuation{readyWaiters.append($0)}}}
    func speak(_ text:String,speaker:String,onChunk:@escaping @MainActor (Data)->Void) async throws {
        requests.append((text,speaker,onChunk))
        try await withCheckedThrowingContinuation{pending.append($0)}
    }
    func finish() {let values=pending+readyWaiters;pending=[];readyWaiters=[];for value in values{value.resume()}}
}

@MainActor func teacherSpeechTestCases()->[(String,@MainActor () async throws -> Void)] {
    func ready(voice:String="teacher") async throws -> (TestWire,SilentCallAudio,FakeTeacherSpeech,RealtimeCall) {
        let wire=TestWire(),audio=SilentCallAudio(),speech=FakeTeacherSpeech()
        let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{true},voice:voice,inputCommitDelay:0,teacherSpeech:speech)
        try await call.connect(history:[],microphone:true,greet:false)
        wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
        return (wire,audio,speech,call)
    }
    func respond(_ wire:TestWire,_ id:String,_ text:String) async {
        wire.emit(["type":"response.created","response":["id":id]]);await settle()
        wire.emit(["type":"response.output_text.delta","response_id":id,"item_id":id+"-item","delta":text]);await settle()
        wire.emit(["type":"response.done","response":["id":id,"status":"completed","output":[["id":id+"-item","type":"message","content":[["type":"output_text","text":text]]]]]]);await settle()
    }
    return [
        ("cold teacher preparation does not delay microphone capture or the connection",{
            let wire=TestWire(),audio=SilentCallAudio(),speech=FakeTeacherSpeech();speech.pausePreparation=true
            let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{true},voice:"teacher",teacherSpeech:speech)
            defer{call.hangUp();speech.finish()}
            let connecting=Task {try await call.connect(history:[],greet:false)};await settle()
            let listeningStarted=audio.starts==1 && wire.connections==1
            speech.finish();try await connecting.value
            try require(listeningStarted,"a cold speech model delayed the user's first utterance")
        }),
        ("teacher calls request cloud text and use the installed Mandarin voice",{
            let (wire,_,speech,call)=try await ready();defer{call.hangUp();speech.finish()}
            let config=wire.sent.first{$0["type"] as? String=="session.update"}?["session"] as? [String:Any]
            try require(config?["output_modalities"] as? [String]==["text"] && speech.prepared==1,"teacher mode still requested the foreign-language audio voice")
            try require((config?["audio"] as? [String:Any])?["output"]==nil,"teacher profile leaked into the cloud voice parameter")
            try require((config?["instructions"] as? String ?? "").contains("幼儿园老师"),"teacher style is missing from the conversation")
        }),
        ("a completed paragraph is spoken once without comma-by-comma synthesis",{
            let (wire,audio,speech,call)=try await ready();defer{call.hangUp();speech.finish()}
            let text="小兔子抱着红苹果，走到奶奶家。它轻轻敲门，奶奶笑着打开了门。"
            try await call.sendText("讲个故事");await respond(wire,"paragraph",text)
            try require(speech.requests.count==1 && speech.requests[0].text==text && speech.requests[0].speaker=="Serena","paragraph or teacher identity changed during synthesis")
            try require(call.state == .thinking,"speaking state started before any local sound")
            let starts=audio.starts,stops=audio.stops
            speech.requests[0].chunk(Data(repeating:1,count:960));await settle()
            try require(call.state == .speaking && audio.received.count==960,"local audio did not stream into the phone graph")
            speech.finish();await settle()
            try require(call.state == .listening && audio.starts==starts && audio.stops==stops,"finishing local speech restarted the microphone")
        }),
        ("teacher barge-in stops local output, rejects late chunks and removes unplayed text",{
            let (wire,audio,speech,call)=try await ready();defer{call.hangUp();speech.finish()}
            try await call.sendText("讲个故事");await respond(wire,"old","小兔子抱着苹果去看奶奶。")
            speech.requests[0].chunk(Data(repeating:1,count:960));await settle()
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"stop"]);await settle()
            wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"stop","delta":"停一下。"]);await settle()
            await wire.finishInput("stop","停一下")
            let heard=audio.received.count
            speech.requests[0].chunk(Data(repeating:2,count:960));speech.finish();await settle()
            try require(audio.received.count==heard && audio.outputStops>0 && call.state == .listening,"cancelled local speech resumed")
            try require(wire.sent.contains{$0["type"] as? String=="conversation.item.delete" && $0["item_id"] as? String=="old-item"},"unplayed server text stayed in context")
            try require(!wire.sent.contains{$0["type"] as? String=="conversation.item.truncate"},"text response used audio-only truncation")
        }),
        ("teacher tool preambles remain silent and only the final response is voiced",{
            let (wire,_,speech,call)=try await ready();defer{call.hangUp();speech.finish()}
            try await call.sendText("还记得什么故事")
            wire.emit(["type":"response.created","response":["id":"lookup"]]);await settle()
            wire.emit(["type":"response.output_text.delta","response_id":"lookup","item_id":"preamble","delta":"我来翻翻故事本。"]);await settle()
            wire.emit(["type":"response.done","response":["id":"lookup","status":"completed","output":[["type":"function_call","name":"find_stories","call_id":"find","arguments":"{\"query\":\"\"}"]]]]);await settle()
            try require(speech.requests.isEmpty,"a tool preamble was spoken as an extra reply")
            await respond(wire,"final","我们一起给小兔子编个新故事吧。")
            try require(speech.requests.map(\.text)==["我们一起给小兔子编个新故事吧。"],"final content was repeated or replaced")
        }),
        ("changing to the bright teacher selects Vivian without cloud audio",{
            let (wire,audio,speech,call)=try await ready(voice:"teacher-bright");defer{call.hangUp();speech.finish()}
            try await call.sendText("你好");await respond(wire,"hello","你好呀，我是莉莉。")
            wire.emit(["type":"response.output_audio.delta","response_id":"hello","item_id":"hello-item","delta":Data(repeating:1,count:960).base64EncodedString()]);await settle()
            try require(speech.requests.first?.speaker=="Vivian" && audio.received.isEmpty,"teacher selection or duplicate voice routing failed")
        }),
        ("ending a teacher call prevents local completion from reviving playback",{
            let (wire,audio,speech,call)=try await ready();defer{speech.finish()}
            try await call.sendText("你好");await respond(wire,"ending","你好呀。")
            call.hangUp();let heard=audio.received.count
            speech.requests[0].chunk(Data(repeating:1,count:960));speech.finish();await settle()
            try require(!call.active && wire.closed && audio.received.count==heard,"late local synthesis survived hangup")
        }),
        ("missing teacher files fail before microphone access or a paid connection",{
            let wire=TestWire(),audio=SilentCallAudio();var permissionCalls=0
            let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{permissionCalls+=1;return true},voice:"teacher")
            do {try await call.connect(history:[]);throw PartnerError.message("TEST: missing speech runtime was accepted")}
            catch {try require(!call.active && wire.connections==0 && audio.starts==0 && permissionCalls==0,"missing runtime opened hardware or network")}
        })
    ]
}
