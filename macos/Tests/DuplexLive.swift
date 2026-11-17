import Foundation

@MainActor func voiceIntentLive() async {
    do {
        guard let key=Credentials.load() else{throw PartnerError.message("Saved connection unavailable")}
        let client=OpenAIClient(key:key)
        let speech="小兔抱着红苹果，沿着小路往奶奶家走。它把篮子放在门口，轻轻敲了三下门。"
        let cases:[(String,VoiceIntent,Bool,String)]=[
            ("嗯，好的",.keepSpeaking,false,speech),
            ("哇，真好玩",.keepSpeaking,false,speech),
            ("它是一只海獭，不是小兔子",.listen,false,speech),
            ("家里刚来了一只小狗，我想跟你讲讲它",.listen,false,speech),
            ("这个故事先放一放，我想讲我今天的事",.listen,false,speech),
            ("好了好了，你先歇一会儿",.stop,false,speech),
            ("停一下这个词是什么意思",.listen,false,speech),
            ("妈妈帮我拿下杯子",.keepSpeaking,false,speech),
            ("爸爸，把窗户关上吧",.keepSpeaking,false,speech),
            ("我想去找妈妈",.listen,false,speech),
            ("好",.listen,true,"你想先听小兔的故事吗？"),
            (speech,.keepSpeaking,false,speech),
            ("妈妈，你能帮我拿一下杯子吗？",.keepSpeaking,false,""),
            ("小明，作业写完了吗？",.keepSpeaking,false,speech),
            ("爸爸，你为什么拿我的杯子？",.keepSpeaking,true,"你想听下一段吗？"),
            ("等一下，爸爸，帮我拿杯子",.keepSpeaking,false,speech),
            ("妈妈今天为什么很累",.listen,false,speech),
            ("莉莉，你为什么喜欢苹果",.listen,false,speech),
            ("妈妈，你为什么拿走我的苹果",.listen,true,"我们来演故事，我演妈妈，你演小兔。你想问妈妈什么？"),
            ("电视里说，停一下，广告马上回来",.keepSpeaking,false,speech),
            ("我不是跟你说，我在跟爸爸说话",.keepSpeaking,false,speech)
        ]
        var results:[[String:Any]]=[]
        for (text,expected,expectsReply,current) in cases {
            let start=Date()
            let result=try await client.voiceIntent(VoiceIntentContext(words:text,assistantSpeech:current,previousRequest:"讲个故事",isFinal:true,expectsReply:expectsReply))
            results.append(["input":text,"expected":expected.rawValue,"actual":result.rawValue,"passed":result==expected,"seconds":Date().timeIntervalSince(start)])
            print("Intent \(result==expected ? "PASS" : "FAIL"): \(text) -> \(result.rawValue)")
        }
        let success=results.allSatisfy{$0["passed"] as? Bool==true}
        try JSONSerialization.data(withJSONObject:["success":success,"model":client.model,"syntheticOnly":true,"physicalMicrophoneOpened":false,"cases":results],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/tmp/tinytales-address-intent.json"))
        if !success{exit(1)}
    }catch{print("Intent check failed: \(error.localizedDescription)");exit(1)}
}

@MainActor func duplexLive() async {
    let args=CommandLine.arguments
    let selected=args.firstIndex(of:"--case").flatMap{args.count>$0+1 ? args[$0+1] : nil}
    let outputDirectory=args.firstIndex(of:"--output-dir").flatMap{args.count>$0+1 ? args[$0+1] : nil} ?? "/tmp/tinytales-duplex"
    let directory=URL(fileURLWithPath:outputDirectory,isDirectory:true)
    do {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        guard let key=Credentials.load(),let teacher=TeacherSpeechClient.discover(resources:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("macos/Resources")) else{throw PartnerError.message("Saved connection or Mandarin runtime unavailable")}
        let first="小兔把三个红苹果放进篮子，准备去看奶奶。它先把蓝色的小伞放好，又在篮子上盖了一块干净的布。一路上，小兔看见蝴蝶停在黄色的花上，也看见小蚂蚁正把一片叶子搬回家。小兔没有着急，沿着平坦的小路慢慢走，终于来到奶奶家门前，轻轻敲了三下门。"
        let second="奶奶打开门，看见篮子里的红苹果，笑着请小兔进屋。它们把苹果洗干净，摆在蓝色盘子里，坐到窗边一起分享。"
        let scenarios=[("question","小兔为什么要带苹果？"), ("correction","不是小兔，是一只小猫，它的名字叫小雨。"), ("sharing","家里刚来了一只小狗，我想和你讲讲它。"), ("stop","我说你先别讲了。")].filter{selected==nil || $0.0==selected}
        func synthesize(_ text:String,file:String)->Task<Data,Error> {Task {
            let path=directory.appendingPathComponent(file+".wav")
            if FileManager.default.fileExists(atPath:path.path) {
                let data=try Data(contentsOf:path)
                if data.count>44 && String(decoding:data.prefix(4),as:UTF8.self)=="RIFF" {return Data(data.dropFirst(44))}
            }
            var bytes=Data();try await teacher.speak(text,speaker:"Vivian"){bytes.append($0)}
            try RealtimeNarrator.wave(bytes).write(to:path);return bytes
        }}
        let acknowledgement=try await synthesize("嗯，好的。",file:"caller-acknowledgement").value
        var overall=true
        for (name,utterance) in scenarios {
            let caller=try await synthesize(utterance,file:"caller-\(name)").value
            let store=try phoneFixture();defer{try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
            let wire=ObservedWire(key:key),audio=SilentCallAudio();audio.simulatePlayback=true
            let judge=OpenAIClient(key:key)
            let call=RealtimeCall(store:store,wire:wire,audio:audio,voice:"teacher",teacherSpeech:teacher,intentJudge:judge,finalRecognizer:judge)
            let started=Date();var phase="setup",targetItem:String?,commit:Double?,paused:Double?,yielded:Double?,firstTargetDelta:Double?,finalInput:Double?
            var users:[String]=[],replies:[String]=[],trace:[[String:Any]]=[],acknowledged=0,paragraphsFinished=0
            call.onUserText={_,text in users.append(text)}
            call.onAssistantText={_,text,_,_,_ in replies.append(text)}
            call.onProtocolEvent={type in
                if type=="backchannel_ignored" {acknowledged+=1}
                if type=="narration_paragraph_finished" {paragraphsFinished+=1}
                if type=="voice_input_pause",phase=="target",paused==nil {paused=Date().timeIntervalSince(started)}
                if type=="voice_input_yield",phase=="target",yielded==nil {yielded=Date().timeIntervalSince(started)}
                if type.hasPrefix("voice_") || ["backchannel_ignored","narration_paragraph_started","narration_paragraph_finished"].contains(type) {trace.append(["type":type,"seconds":Date().timeIntervalSince(started)])}
            }
            wire.observe={event in
                let type=event["type"] as? String ?? "",time=Date().timeIntervalSince(started)
                if type=="input_audio_buffer.speech_started",phase=="target",targetItem==nil {targetItem=event["item_id"] as? String}
                if type=="input_audio_buffer.committed",event["item_id"] as? String==targetItem,commit==nil {commit=time}
                if type=="conversation.item.input_audio_transcription.delta",event["item_id"] as? String==targetItem,firstTargetDelta==nil {firstTargetDelta=time}
                if type=="conversation.item.input_audio_transcription.completed",event["item_id"] as? String==targetItem {finalInput=time}
                if ["input_audio_buffer.speech_started","input_audio_buffer.committed","conversation.item.input_audio_transcription.completed","response.created","error"].contains(type) {
                    var row:[String:Any]=["type":type,"seconds":time]
                    if let text=event["transcript"] {row["transcript"]=text}
                    if let error=event["error"] as? [String:Any] {row["errorCode"]=error["code"] ?? ""}
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
                try require(condition(),"scenario \(name) timed out")
            }
            do {
                try await call.connect(history:[],microphone:false,greet:false)
                try await waitFor({call.state == .listening || !call.active},seconds:25)
                try await call.sendText("给我讲个故事。请原样朗读下面两个自然段，保留空行，不加开场白或问题：\n\n"+first+"\n\n"+second)
                try await silence(until:{call.state == .speaking},seconds:35)
                phase="ack";try await feed(acknowledgement)
                try await silence(until:{acknowledged>0},seconds:10)
                let ackProtected=audio.pauses==0 && audio.outputStops==0 && replies.count==1
                phase="target";let targetStart=Date().timeIntervalSince(started)
                try await feed(caller)
                try await silence(until:{!users.isEmpty && (name=="stop" ? !call.outputSuspended && call.state == .listening : replies.count>=2)},seconds:25)
                let created=wire.sentTypes.filter{$0=="response.create"}.count
                let endedBeforeInput=paragraphsFinished
                try await feed(Data(repeating:0,count:48000*5))
                let beforeCommit=paused != nil && commit != nil && paused!<commit!
                let liveBeforeCommit=firstTargetDelta != nil && commit != nil && firstTargetDelta!<commit!
                let handoff=paused ?? yielded
                let promptHandoff=handoff != nil && finalInput != nil && handoff!<=finalInput!+3
                let stable=wire.sentTypes.filter{$0=="response.create"}.count==created
                let noLostInput=users.joined().contains(name=="question" ? "为什么" : name=="correction" ? "小猫" : name=="sharing" ? "小狗" : "别讲")
                let success=ackProtected && liveBeforeCommit && promptHandoff && endedBeforeInput==0 && noLostInput && stable && call.inputPacketsWhileSpeaking>0 && (name != "stop" || replies.count==1)
                let report:[String:Any]=["success":success,"scenario":name,"voice":"teacher","transcriptionModel":"gpt-live-transcribe","syntheticOnly":true,"physicalMicrophoneOpened":false,"playbackSimulation":true,"acknowledgementProtected":ackProtected,"pausedBeforeCommit":beforeCommit,"liveTextBeforeCommit":liveBeforeCommit,"promptHandoffAfterMeaningfulInput":promptHandoff,"targetStartSeconds":targetStart,"firstTargetDeltaSeconds":firstTargetDelta as Any? ?? NSNull(),"pauseSeconds":paused as Any? ?? NSNull(),"yieldSeconds":yielded as Any? ?? NSNull(),"commitSeconds":commit as Any? ?? NSNull(),"finalInputSeconds":finalInput as Any? ?? NSNull(),"paragraphsFinishedBeforeHandoff":endedBeforeInput,"inputPacketsWhileSpeaking":call.inputPacketsWhileSpeaking,"partialEventsBeforeCommit":call.transcriptDeltasBeforeCommit,"users":users,"replies":replies,"trace":trace]
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("duplex-\(name).json"))
                overall = overall && success
                print("Duplex \(name): \(success), ack protected: \(ackProtected), paused before commit: \(beforeCommit), users: \(users.joined(separator:" | "))")
            }catch{
                overall=false
                try? JSONSerialization.data(withJSONObject:["success":false,"scenario":name,"error":error.localizedDescription,"users":users,"replies":replies,"trace":trace],options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("duplex-\(name).json"))
                print("Duplex \(name) failed: \(error.localizedDescription)")
            }
            call.hangUp();await settle()
        }
        if !overall{exit(1)}
    }catch{print("Duplex evaluation failed: \(error.localizedDescription)");exit(1)}
}
