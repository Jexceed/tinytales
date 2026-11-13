import Foundation

/// Controlled user recordings + real OpenAI and Mandarin TTS, with playback-time
/// simulation. No room microphone or physical loudspeaker is opened.
@MainActor func naturalTurnLive() async {
    let explicitQuestion=CommandLine.arguments.contains("--floor-question")
    var trace:[[String:Any]]=[];let clock=Date()
    var users:[String]=[],replies:[String]=[],finished=0,backchannels=0,deferred=0
    var firstBoundary:Date?,secondRequest:Date?,receivedAudio=0
    let directory=URL(fileURLWithPath:"artifacts/v012-natural-turns",isDirectory:true)
    do {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        guard let key=Credentials.load() else{throw PartnerError.message("Saved connection unavailable")}
        let resources=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("macos/Resources")
        guard let teacher=TeacherSpeechClient.discover(resources:resources) else{throw PartnerError.message("Mandarin runtime unavailable")}
        func caller(_ text:String,_ filename:String) async throws -> Data {
            var bytes=Data();try await teacher.speak(text,speaker:"Vivian"){bytes.append($0)}
            try RealtimeNarrator.wave(bytes).write(to:directory.appendingPathComponent(filename+".wav"));return bytes
        }
        let acknowledgement=try await caller("嗯，好的。","caller-acknowledgement")
        let question=try await caller(explicitQuestion ? "停一下，小兔为什么要带苹果？" : "小兔为什么要带苹果？",explicitQuestion ? "caller-explicit-question" : "caller-question")
        let store=try phoneFixture();defer{try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
        let wire=ObservedWire(key:key),audio=SilentCallAudio();audio.simulatePlayback=true
        let call=RealtimeCall(store:store,wire:wire,audio:audio,voice:"teacher",teacherSpeech:teacher);defer{call.hangUp()}
        call.onUserText={_,text in users.append(text)}
        call.onAssistantText={_,text,_,_,_ in replies.append(text)}
        call.onAudio={receivedAudio+=$0.count}
        call.onProtocolEvent={event in
            if event=="narration_paragraph_finished" {finished+=1;if firstBoundary==nil{firstBoundary=Date()}}
            if event=="backchannel_ignored" {backchannels+=1}
            if event=="input_waiting_for_paragraph" {deferred+=1}
            if ["narration_paragraph_started","narration_paragraph_finished","backchannel_ignored","input_waiting_for_paragraph","explicit_voice_interruption","input_transcription_timeout"].contains(event) {
                trace.append(["type":event,"seconds":Date().timeIntervalSince(clock)])
            }
        }
        wire.observe={event in
            let type=event["type"] as? String ?? ""
            if type=="response.created",!replies.isEmpty,secondRequest==nil {secondRequest=Date()}
            if ["response.created","input_audio_buffer.speech_started","input_audio_buffer.speech_stopped","conversation.item.input_audio_transcription.completed","error"].contains(type) {
                var row:[String:Any]=["type":type,"seconds":Date().timeIntervalSince(clock)]
                if let text=event["transcript"] {row["transcript"]=text}
                if let error=event["error"] as? [String:Any] {row["errorCode"]=error["code"]}
                trace.append(row)
            }
        }
        func feed(_ bytes:Data) async throws {
            for offset in stride(from:0,to:bytes.count,by:960) {
                try require(call.active,"call ended: \(call.notice)")
                audio.onMicrophone?(bytes.subdata(in:offset..<min(offset+960,bytes.count)))
                try await Task.sleep(nanoseconds:20_000_000)
            }
        }
        func silence(until condition:()->Bool,seconds:Double) async throws {
            let deadline=Date().addingTimeInterval(seconds)
            while !condition() && Date()<deadline {try await feed(Data(repeating:0,count:960))}
            try require(condition(),"expected voice event did not arrive")
        }
        try await call.connect(history:[],microphone:false,greet:false)
        try await waitFor({call.state == .listening || !call.active},seconds:25)
        let first="小兔把三个红苹果放进篮子，准备去看奶奶。它先把蓝色的小伞放好，又在篮子上盖了一块干净的布。一路上，小兔看见蝴蝶停在黄色的花上，也看见小蚂蚁正把一片叶子搬回家。小兔没有着急，沿着平坦的小路慢慢走，终于来到奶奶家门前，轻轻敲了三下门。"
        let second="奶奶打开门，看见篮子里的红苹果，笑着请小兔进屋。它们把苹果洗干净，摆在蓝色盘子里，坐到窗边一起分享。"
        try await call.sendText("给我讲个故事。请原样朗读下面两个自然段，保留中间的空行，不加开场白或问题：\n\n"+first+"\n\n"+second)
        try await silence(until:{call.state == .speaking},seconds:35)
        let beforeStops=audio.outputStops,beforeRequests=wire.sentTypes.filter{$0=="response.create"}.count
        try await feed(acknowledgement)
        try await silence(until:{backchannels>0},seconds:8)
        let acknowledgementProtected=audio.outputStops==beforeStops && wire.sentTypes.filter{$0=="response.create"}.count==beforeRequests && call.state == .speaking
        try await feed(question)
        if !explicitQuestion {try await silence(until:{deferred>0},seconds:8)}
        let questionProtected=explicitQuestion || (finished==0 && audio.outputStops==beforeStops && wire.sentTypes.filter{$0=="response.create"}.count==beforeRequests)
        try await silence(until:{replies.count>=2},seconds:45)
        let handedOffAtBoundary=explicitQuestion ? firstBoundary==nil && audio.outputStops>beforeStops : firstBoundary != nil && secondRequest != nil && secondRequest!>=firstBoundary!
        let countAfterReply=wire.sentTypes.filter{$0=="response.create"}.count
        try await feed(Data(repeating:0,count:48000*5))
        let questionAnswered=replies.last?.contains("奶奶")==true && ["苹果","礼物","分享"].contains{replies.last?.contains($0)==true}
        let success=acknowledgementProtected && questionProtected && handedOffAtBoundary && questionAnswered && users.count==1 && users[0].contains("为什么") && countAfterReply==2 && wire.sentTypes.filter{$0=="response.create"}.count==2 && receivedAudio>0
        let report:[String:Any]=["success":success,"syntheticOnly":true,"physicalMicrophoneOpened":false,"playbackSimulation":true,"voice":"teacher","explicitQuestion":explicitQuestion,"questionAnswered":questionAnswered,"acknowledgementProtected":acknowledgementProtected,"questionProtectedUntilPlaybackBoundary":questionProtected,"handedOffCorrectly":handedOffAtBoundary,"users":users,"replies":replies,"responseRequests":countAfterReply,"audioBytes":receivedAudio,"trace":trace]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(explicitQuestion ? "explicit-question-check.json" : "real-interface-check.json"))
        print("Natural turns: \(success), acknowledgement protected: \(acknowledgementProtected), question waited for playback: \(questionProtected), boundary handoff: \(handedOffAtBoundary)")
        if !success{exit(1)}
    }catch{
        try? JSONSerialization.data(withJSONObject:["success":false,"error":error.localizedDescription,"users":users,"replies":replies,"trace":trace],options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(explicitQuestion ? "explicit-question-check.json" : "real-interface-check.json"))
        print("Natural turn check failed: \(error.localizedDescription)");exit(1)
    }
}
