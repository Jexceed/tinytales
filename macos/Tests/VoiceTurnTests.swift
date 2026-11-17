import Foundation

@MainActor func voiceTurnTestCases()->[(String,@MainActor () async throws -> Void)] {
    func ready(timeout:UInt64=12_000_000_000,commitDelay:UInt64=0) async throws -> (TestWire,SilentCallAudio,RealtimeCall) {
        let wire=TestWire(),audio=SilentCallAudio()
        let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{true},transcriptionTimeout:timeout,inputCommitDelay:commitDelay)
        try await call.connect(history:[],microphone:false,greet:false)
        wire.emit(["type":"session.created"]);await settle()
        wire.emit(["type":"session.updated"]);await settle()
        return (wire,audio,call)
    }
    func count(_ wire:TestWire,_ type:String)->Int {wire.sent.filter{$0["type"] as? String==type}.count}
    func segment(_ wire:TestWire,_ id:String) async {
        wire.emit(["type":"input_audio_buffer.speech_started","item_id":id]);await settle()
        wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":id]);await settle()
        wire.emit(["type":"input_audio_buffer.committed","item_id":id]);await settle()
    }
    func transcript(_ wire:TestWire,_ id:String,_ text:String) async {
        wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":id,"transcript":text]);await settle()
    }
    func permit(_ wire:TestWire)->[String:Any] {
        (wire.sent.last{$0["type"] as? String=="response.create"}?["response"] as? [String:Any])?["metadata"] as? [String:Any] ?? [:]
    }
    func created(_ wire:TestWire,_ id:String) async {
        wire.emit(["type":"response.created","response":["id":id,"metadata":permit(wire)]]);await settle()
    }
    return [
        ("a second clause during endpoint settling joins the first instead of being interrupted",{
            let (wire,_,call)=try await ready(commitDelay:100_000_000);defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            await segment(wire,"first");await transcript(wire,"first","给我讲一个")
            try require(count(wire,"response.create")==0,"response skipped the endpoint settling interval")
            await segment(wire,"second");await transcript(wire,"second","小马过河的故事")
            try await waitFor({count(wire,"response.create")==1},seconds:1)
            try require(users==["给我讲一个小马过河的故事"],"one spoken turn was split into separate user messages")
            await segment(wire,"third");await transcript(wire,"third","再讲个故事")
            await segment(wire,"stop");await transcript(wire,"stop","停一下")
            try require(call.state == .listening && !call.listeningHint.isEmpty,"a stop after a pending request was delayed")
            try await Task.sleep(nanoseconds:150_000_000)
            try require(count(wire,"response.create")==1,"the cancelled settling task started a later response")
        }),
        ("duplicate VAD events do not interrupt or rearm an accepted turn",{
            let (wire,audio,call)=try await ready();defer{call.hangUp()}
            await segment(wire,"user");await transcript(wire,"user","给我讲个故事")
            await created(wire,"reply")
            await segment(wire,"user");await transcript(wire,"user","给我讲个故事")
            wire.emit(["type":"response.output_audio.delta","response_id":"reply","item_id":"a","delta":Data(repeating:1,count:960).base64EncodedString()]);await settle()
            try require(audio.received.count==960 && count(wire,"response.create")==1 && count(wire,"response.cancel")==0,"duplicate VAD invalidated the current reply")
        }),
        ("muted late input events cannot create a turn or leave a thinking spinner",{
            let (wire,_,call)=try await ready();defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            call.toggleMute();await segment(wire,"muted");await transcript(wire,"muted","继续")
            call.toggleMute()
            try require(users.isEmpty && count(wire,"response.create")==0 && call.state == .listening,"muted late input was treated as speech")
            await segment(wire,"real");await transcript(wire,"real","给我讲个故事")
            try require(users==["给我讲个故事"] && count(wire,"response.create")==1,"unmuting did not recover normal input")
        }),
        ("only a recognized user utterance creates a bubble and one reply",{
            let (wire,_,call)=try await ready();defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"request"]);await settle()
            wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"request","delta":"给我讲" ]);await settle()
            try require(call.inputTranscript=="给我讲" && users.isEmpty,"partial speech became a permanent bubble")
            wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":"request"]);await settle()
            wire.emit(["type":"input_audio_buffer.committed","item_id":"request"]);await settle()
            try require(count(wire,"response.create")==0,"VAD or commit authorized an unrecognized reply")
            await transcript(wire,"request","给我讲个故事。")
            await transcript(wire,"request","给我讲个故事。")
            wire.emit(["type":"input_audio_buffer.committed","item_id":"request"]);await settle()
            try require(users==["给我讲个故事。"] && count(wire,"response.create")==1,"duplicate transcript created extra turns")
            try require(call.inputTranscript.isEmpty && call.state == .thinking,"accepted input kept the partial transcript")
        }),
        ("empty transcription is ignored and a later real request still works",{
            let (wire,_,call)=try await ready();defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            await segment(wire,"noise");await transcript(wire,"noise"," ……！？ ")
            try require(users.isEmpty && count(wire,"response.create")==0 && call.state == .listening,"punctuation triggered a conversation")
            try require(!call.listeningHint.isEmpty && count(wire,"conversation.item.delete")==1,"unrecognized audio was left in the model context")
            await segment(wire,"quiet-user");await transcript(wire,"quiet-user","给我讲个故事。")
            try require(users==["给我讲个故事。"] && count(wire,"response.create")==1 && call.listeningHint.isEmpty,"recognition did not recover after silence")
        }),
        ("transcription failure is recoverable and ignores a late completion",{
            let (wire,_,call)=try await ready();defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            await segment(wire,"failed")
            wire.emit(["type":"conversation.item.input_audio_transcription.failed","item_id":"failed","error":["code":"transcription_failed"]]);await settle()
            await transcript(wire,"failed","继续")
            try require(call.active && call.state == .listening && users.isEmpty && count(wire,"response.create")==0,"failed transcription authorized a late continuation")
            await segment(wire,"retry");await transcript(wire,"retry","讲一个小马的故事")
            try require(users==["讲一个小马的故事"] && count(wire,"response.create")==1,"a real retry was not accepted")
        }),
        ("timed-out transcription is removed without blocking later accepted speech",{
            let (wire,_,call)=try await ready(timeout:60_000_000);defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            await segment(wire,"lost");await segment(wire,"next");await transcript(wire,"next","给我讲个故事。")
            try require(users.isEmpty && count(wire,"response.create")==0,"an earlier pending utterance was skipped")
            try await waitFor({count(wire,"conversation.item.delete")==1 && count(wire,"response.create")==1},seconds:1)
            await transcript(wire,"lost","继续")
            try require(users==["给我讲个故事。"] && count(wire,"response.create")==1,"timeout cancelled its own cleanup or resurrected old speech")
        }),
        ("out-of-order transcription preserves the spoken order and waits for the speaker",{
            let (wire,_,call)=try await ready();defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            await segment(wire,"first")
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"second"]);await settle()
            await transcript(wire,"first","给我讲个故事。")
            try require(count(wire,"response.create")==0,"interrupted the user's next phrase")
            wire.emit(["type":"input_audio_buffer.speech_stopped","item_id":"second"]);await settle()
            wire.emit(["type":"input_audio_buffer.committed","item_id":"second"]);await settle()
            await transcript(wire,"second","主角是一匹小马。")
            try require(users==["给我讲个故事。主角是一匹小马。"] && count(wire,"response.create")==1,"phrases were split into competing messages or replies")
            await segment(wire,"third");await segment(wire,"fourth")
            await transcript(wire,"fourth","名字叫小雨。")
            await transcript(wire,"third","小马是蓝色的。")
            try require(users==["给我讲个故事。主角是一匹小马。","小马是蓝色的。名字叫小雨。"] && count(wire,"response.create")==2,"completion order replaced speaking order or merged a later turn")
        }),
        ("playback echo cannot request a continuation and a short stop still works",{
            let (wire,audio,call)=try await ready();defer{call.hangUp()}
            var users:[String]=[];call.onUserText={_,text in users.append(text)}
            try await call.sendText("讲个故事");await created(wire,"story")
            let text="小马穿过彩虹桥，找到一颗闪闪发光的星星。"
            wire.emit(["type":"response.output_audio_transcript.delta","response_id":"story","item_id":"story-a","delta":text]);await settle()
            wire.emit(["type":"response.output_audio.delta","response_id":"story","item_id":"story-a","delta":Data(repeating:0,count:48000).base64EncodedString()]);await settle()
            await segment(wire,"echo");await transcript(wire,"echo",text)
            try require(users.isEmpty && count(wire,"response.create")==1,"assistant playback became a user request")
            await segment(wire,"stop");await transcript(wire,"stop","停一下。")
            try require(users==["停一下。"] && count(wire,"response.create")==1 && call.state == .listening && audio.outputStops>0,"stop request resumed the story")
            try require(!call.listeningHint.isEmpty,"stopping gave no visible acknowledgement")
            var turns=VoiceTurns();turns.begin("repeat",overlap:false);turns.commit("repeat");turns.stop("repeat")
            _=turns.finish("repeat",text,assistantTexts:[text])
            try require(turns.consumeReady()?.first?.text==text,"intentional repetition outside playback was rejected")
        }),
        ("unsolicited server output is cancelled before it can speak",{
            let (wire,audio,call)=try await ready();defer{call.hangUp()}
            wire.emit(["type":"response.created","response":["id":"unsolicited"]]);await settle()
            wire.emit(["type":"response.output_audio.delta","response_id":"unsolicited","item_id":"a","delta":Data(repeating:0,count:960).base64EncodedString()]);await settle()
            try require(audio.received.isEmpty && count(wire,"response.cancel")==1 && call.state == .listening,"unsolicited output started playback")
        }),
        ("an old response cannot consume a newer turn's permission",{
            let (wire,audio,call)=try await ready();defer{call.hangUp()}
            try await call.sendText("旧请求");let old=permit(wire)
            await segment(wire,"new-user");await transcript(wire,"new-user","现在讲小马")
            wire.emit(["type":"response.created","response":["id":"late-old","metadata":old]]);await settle()
            await created(wire,"new-response")
            wire.emit(["type":"response.output_audio.delta","response_id":"new-response","item_id":"new-a","delta":Data(repeating:1,count:960).base64EncodedString()]);await settle()
            try require(audio.received.count==960 && call.state == .speaking,"late response stole the newer turn's authorization")
        }),
        ("slow interruption and stale end events cannot stop a newer reply",{
            let (wire,audio,call)=try await ready();defer{call.hangUp()}
            try await call.sendText("讲个故事");await created(wire,"old")
            wire.emit(["type":"response.output_audio.delta","response_id":"old","item_id":"old-a","delta":Data(repeating:0,count:48000).base64EncodedString()]);await settle()
            wire.delayedTypes.insert("conversation.item.truncate")
            await segment(wire,"new-user")
            wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"new-user","delta":"停一下。"]);await settle()
            await transcript(wire,"new-user","停一下，换个故事")
            try await waitFor({count(wire,"response.create")==2},seconds:1)
            await created(wire,"new")
            wire.emit(["type":"response.output_audio.delta","response_id":"new","item_id":"new-a","delta":Data(repeating:1,count:960).base64EncodedString()]);await settle()
            try await Task.sleep(nanoseconds:100_000_000)
            wire.emit(["type":"response.output_audio.done","response_id":"old","item_id":"old-a"])
            wire.emit(["type":"response.output_audio_transcript.done","response_id":"old","item_id":"old-a","transcript":"继续旧故事" ]);await settle()
            let cancel=wire.sent.last{$0["type"] as? String=="response.cancel"}
            try require(cancel?["response_id"] as? String=="old" && call.state == .speaking,"delayed interruption cancelled or reset the new reply")
            let heard=audio.received.count
            wire.emit(["type":"response.output_audio.delta","response_id":"new","item_id":"new-a","delta":Data(repeating:2,count:960).base64EncodedString()]);await settle()
            try require(audio.received.count==heard+960,"new output authorization was cleared by an old handler")
        }),
        ("duplicate tool completion cannot execute or continue twice",{
            let (wire,_,call)=try await ready();defer{call.hangUp()}
            wire.delayToolOutput=true
            try await call.sendText("我喜欢什么");await created(wire,"tools")
            let done:[String:Any]=["type":"response.done","response":["id":"tools","status":"completed","output":[["type":"function_call","name":"recall_memories","call_id":"tool","arguments":"{}"]]]]
            wire.emit(done);await settle();wire.emit(done);await settle()
            try await waitFor({count(wire,"response.create")==2},seconds:1)
            let outputs=wire.sent.filter{($0["item"] as? [String:Any])?["type"] as? String=="function_call_output"}
            try require(outputs.count==1,"duplicate completion executed the same tool twice")
        }),
        ("microphone pre-roll and later buffers are uploaded once in order",{
            let wire=TestWire(),audio=SilentCallAudio()
            let call=RealtimeCall(store:try phoneFixture(),wire:wire,audio:audio,permission:{true});defer{call.hangUp()}
            try await call.connect(history:[],greet:false)
            let first=Data(repeating:1,count:1440),second=Data(repeating:2,count:960),third=Data(repeating:3,count:1440)
            audio.onMicrophone?(first);await settle()
            try require(wire.deliveredAudio.isEmpty,"audio escaped before the session was configured")
            wire.delayedTypes.insert("input_audio_buffer.append")
            wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
            audio.onMicrophone?(second);audio.onMicrophone?(third)
            try await waitFor({wire.deliveredAudio.count==4},seconds:2)
            try require(wire.maxAudioSends==1 && wire.deliveredAudio.reduce(Data(),+)==first+second+third,"microphone chunks were reordered, duplicated or the beginning was lost")
        }),
        ("muting flushes queued audio and never replays it after unmute",{
            let (wire,audio,call)=try await ready();defer{call.hangUp()}
            wire.delayedTypes.insert("input_audio_buffer.append")
            audio.onMicrophone?(Data(repeating:1,count:2880));await settle()
            call.toggleMute();try await Task.sleep(nanoseconds:100_000_000)
            call.toggleMute();audio.onMicrophone?(Data(repeating:2,count:960))
            try await waitFor({wire.deliveredAudio.count==2},seconds:1)
            try require(wire.deliveredAudio==[Data(repeating:1,count:960),Data(repeating:2,count:960)],"muted backlog was uploaded after unmute")
        }),
        ("repeated recognition failures end cleanly instead of looping replies",{
            let (wire,_,call)=try await ready();defer{call.hangUp()}
            for index in 0..<3 {
                let id="failed-\(index)";await segment(wire,id)
                wire.emit(["type":"conversation.item.input_audio_transcription.failed","item_id":id,"error":["code":"transcription_failed"]]);await settle()
            }
            try require(!call.active && !call.notice.isEmpty && count(wire,"response.create")==0,"persistent ASR failure looped or left an apparently working call")
        })
    ]
}
