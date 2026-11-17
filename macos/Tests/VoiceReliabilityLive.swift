import Foundation
import AVFoundation
import CryptoKit
import AppKit

/// Fixed synthetic speech only. Recognition accuracy, candidate confirmation,
/// and a complete live turn are reported separately.
@MainActor func recognitionRegressionLive() async {
    let args=CommandLine.arguments
    let path=args.firstIndex(of:"--output-dir").flatMap{args.count>$0+1 ? args[$0+1] : nil} ?? "/tmp/tinytales-v0172-recognition"
    let directory=URL(fileURLWithPath:path,isDirectory:true)
    var rows:[[String:Any]]=[],checks:[String:Bool]=[:],trace:[[String:Any]]=[],users:[String]=[],replies:[String]=[],canonical:[String]=[]
    var failure=""
    do {
        guard let key=Credentials.load() else{throw PartnerError.message("Saved connection unavailable")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        func sample(_ id:String,_ text:String) throws -> Data {
            let wav=directory.appendingPathComponent(id+".wav")
            if let data=try? Data(contentsOf:wav),data.count>44 {return Data(data.dropFirst(44))}
            let source=directory.appendingPathComponent(id+".aiff")
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/say")
            process.arguments=["-v","Tingting","-r","175","-o",source.path,text]
            try process.run();process.waitUntilExit()
            try require(process.terminationStatus==0,"synthetic speech failed")
            let pcm=scaledPCM(try pitchedPCM(source,cents:0),rms:0.035)
            try RealtimeNarrator.wave(pcm).write(to:wav);return pcm
        }
        let client=OpenAIClient(key:key)
        let cases=[
            ("poem","举头望明月。"),
            ("poem-correction","嗯，我说的是举头望明月。"),
            ("poem-other","两个黄鹂鸣翠柳。"),
            ("poem-frost","疑是地上霜。"),
            ("fictional-name","小兔的名字叫许明月。")
        ]
        var samples:[String:Data]=[:]
        for (id,reference) in cases {
            let pcm=try sample(id,reference);samples[id]=pcm
            let started=Date()
            let actual=try await client.transcribeFinal(RealtimeNarrator.wave(pcm))
            let correct=SpeechRecognitionContext.equivalent(actual,reference)
            rows.append(["id":id,"category":"independent_transcription","reference":reference,"actual":actual,"passed":correct,"requestSeconds":Date().timeIntervalSince(started),"referenceIncludedInRequest":false,"sha256":SHA256.hash(data:pcm).map{String(format:"%02x",$0)}.joined()])
            print("ASR \(id): \(actual) [\(correct)]");fflush(stdout)
        }
        let poem=samples["poem"]!
        for (id,live,first) in [
            ("preserve-live","举头望明月。","许头望明月。"),
            ("preserve-file","许头望明月。","举头望明月。")
        ] {
            let context=SpeechRecognitionContext(liveText:live,firstPassText:first)
            let actual=try await client.transcribeFinal(RealtimeNarrator.wave(poem),context:context)
            rows.append(["id":id,"category":"candidate_confirmation","actual":actual,"passed":SpeechRecognitionContext.equivalent(actual,"举头望明月"),"candidateHintsIncluded":true])
            print("Confirmation \(id): \(actual)");fflush(stdout)
        }
        let store=try phoneFixture(),wire=ObservedWire(key:key),audio=SilentCallAudio(),speech=FakeTeacherSpeech()
        let call=RealtimeCall(store:store,wire:wire,audio:audio,permission:{false},voice:"teacher",teacherSpeech:speech,intentJudge:client,finalRecognizer:client)
        defer{call.hangUp();speech.finish();try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
        let began=Date();var submittedAt:Date?
        call.onUserText={_,text in users.append(text);submittedAt=Date()}
        call.onAssistantText={_,text,_,_,_ in replies.append(text)}
        call.onProtocolEvent={type in
            if type.hasPrefix("input_") || type.hasPrefix("voice_") || type=="verified_text_committed" {
                trace.append(["type":type,"seconds":Date().timeIntervalSince(began)])
            }
        }
        wire.observe={event in
            if event["type"] as? String=="conversation.item.input_audio_transcription.completed" {
                trace.append(["type":"live_transcript","text":event["transcript"] as? String ?? "","seconds":Date().timeIntervalSince(began)])
            }
        }
        wire.observeSent={event in
            if let item=event["item"] as? [String:Any],item["role"] as? String=="user",let content=(item["content"] as? [[String:Any]])?.first,content["type"] as? String=="input_text",let text=content["text"] as? String {canonical.append(text)}
        }
        func feed(_ pcm:Data) async throws {
            for offset in stride(from:0,to:pcm.count,by:960) {
                try require(call.active,"live call ended")
                audio.onMicrophone?(pcm.subdata(in:offset..<min(offset+960,pcm.count)))
                try await Task.sleep(nanoseconds:20_000_000)
            }
        }
        func silence(_ seconds:Double) async throws {try await feed(Data(repeating:0,count:Int(seconds*48_000)))}
        func until(_ condition:()->Bool) async throws {
            let end=Date().addingTimeInterval(40)
            while !condition(),Date()<end {try await silence(0.02)}
            try require(condition(),"live regression event timed out")
        }
        try await call.connect(history:[],microphone:false,greet:false)
        try await until({call.state == .listening})
        try await feed(try sample("lead-in","哦，我说。"))
        try await until({(call.inputPreviewIsFinal && trace.contains{($0["type"] as? String ?? "").hasPrefix("voice_final_intent:")}) || !users.isEmpty || call.inputNeedsCorrection})
        try await silence(2.0)
        checks["unfinishedLeadInDidNotReply"]=users.isEmpty && replies.isEmpty && !call.inputNeedsCorrection
        try await feed(poem);let finishedSpeaking=Date()
        try await until({!replies.isEmpty || call.inputNeedsCorrection})
        checks["oneCompleteUserMessage"]=users.count==1 && users[0].contains("举头望明月")
        checks["displayAndModelAgree"]=canonical==users
        checks["replyUsesPoem"]=replies.count==1 && (replies[0].contains("静夜思") || replies[0].contains("李白"))
        checks["waitedAtLeast1_6SecondsAfterAudio"]=(submittedAt?.timeIntervalSince(finishedSpeaking) ?? 0)>=1.6
        checks["callStayedConnected"]=call.active && !call.inputNeedsCorrection
        print("Live turn checks: \(checks)");fflush(stdout)
    } catch {failure=error.localizedDescription;print("Recognition regression: \(failure)")}
    let report:[String:Any]=["syntheticOnly":true,"physicalMicrophoneOpened":false,"physicalPlayback":false,"realASRIntentAndConversationAPIs":true,"cases":rows,"turnChecks":checks,"users":users,"canonical":canonical,"replies":replies,"trace":trace,"error":failure,"passed":failure.isEmpty && rows.count==7 && rows.allSatisfy{$0["passed"] as? Bool==true} && checks.count==6 && checks.values.allSatisfy{$0}]
    if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:directory.appendingPathComponent("result.json"))}
    if report["passed"] as? Bool != true {exit(1)}
}

private struct SpeechEvalCase {
    var id:String,text:String,category:String
    var required:[String]
    var voice="Tingting",rate=175
    var rms=0.035,noise=0.0
    var pitch:Float=0
}

private func speechEvalCases()->[SpeechEvalCase] {
    var cases:[SpeechEvalCase]=[
        .init(id:"picture-direct",text:"给我画一张图片。",category:"drawing",required:["画","图"]),
        .init(id:"picture-context",text:"给这个画蛇添足的故事画一幅图。",category:"drawing",required:["画蛇添足","图"]),
        .init(id:"picture-correction",text:"不是讲故事，是给我画一张图片。",category:"correction",required:["不是","画","图"]),
        .init(id:"witch-answer",text:"是一个老巫婆。",category:"short-answer",required:["老巫婆"]),
        .init(id:"witch-correction",text:"不是奶奶，是一个老巫婆。",category:"correction",required:["不是奶奶","老巫婆"]),
        .init(id:"science",text:"月亮为什么会发光？",category:"question",required:["月亮","为什么","发光"]),
        .init(id:"animal-correction",text:"那是一只海獭，不是小猫。",category:"correction",required:["海獭","不是小猫"]),
        .init(id:"quantity",text:"小兔带着三个红苹果。",category:"statement",required:["小兔","苹果"]),
        .init(id:"negation",text:"不要画蛇，画一只独角兽。",category:"negation",required:["不要画蛇","独角兽"]),
        .init(id:"stop",text:"停一下。",category:"control",required:["停"]),
        .init(id:"stop-and-share",text:"先别讲了，我想说点别的。",category:"control",required:["别讲","我想说"]),
        .init(id:"quoted-stop",text:"停一下这个词是什么意思？",category:"quoted-control",required:["停一下","什么意思"]),
        .init(id:"story-request",text:"给我讲一个小马过河的故事。",category:"story",required:["小马过河","故事"]),
        .init(id:"short-blue",text:"蓝色的。",category:"short-answer",required:["蓝色"]),
        .init(id:"english",text:"请读这个单词，apple。",category:"mixed-language",required:["单词","apple"]),
        .init(id:"bystander",text:"妈妈，帮我拿一下杯子。",category:"bystander",required:["妈妈","杯子"]),
        .init(id:"backchannel",text:"嗯，好的。",category:"backchannel",required:["好"])
    ]
    for (id,text,required) in [("picture","给我画一张图片。",["画","图"]),("witch","是一个老巫婆。",["老巫婆"])] {
        cases.append(.init(id:id+"-second-voice",text:text,category:"second-synthetic-voice",required:required,voice:"Eddy (中文（中国大陆）)",rate:190))
        cases.append(.init(id:id+"-soft",text:text,category:"soft",required:required,rms:0.003))
        cases.append(.init(id:id+"-noise",text:text,category:"noise",required:required,noise:0.008))
        cases.append(.init(id:id+"-higher-pitch",text:text,category:"synthetic-pitch",required:required,pitch:350))
        cases.append(.init(id:id+"-fast",text:text,category:"fast",required:required,rate:235))
    }
    cases.append(.init(id:"silence",text:"",category:"negative-control",required:[],rms:0))
    cases.append(.init(id:"noise-only",text:"",category:"negative-control",required:[],rms:0,noise:0.003))
    return cases
}

private func addSpeechTestNoise(_ pcm:Data,rms:Double)->Data {
    guard rms>0 else{return pcm}
    let input=[UInt8](pcm);var result=Data(),random:UInt64=731
    for i in stride(from:0,to:input.count-1,by:2) {
        random=random &* 6364136223846793005 &+ 1
        let noise=(Double((random>>32)&0xffff)/65535-0.5)*sqrt(12)*rms*32768
        let original=Double(Int16(bitPattern:UInt16(input[i]) | UInt16(input[i+1])<<8))
        var sample=Int16(clamping:Int((original+noise).rounded())).littleEndian
        withUnsafeBytes(of:&sample){result.append(contentsOf:$0)}
    }
    return result
}

@MainActor private func baselineSpeech(_ pcm:Data,key:String) async -> [String:Any] {
    let wire=OpenAIRealtimeWire(key:key,model:"gpt-realtime-2.1");defer{wire.close()}
    var created=false,ready=false,error="",order:[String]=[],words:[String:String]=[:],vad=0
    var start=Date(),first:Double?,last:Double?
    wire.onError={_ in error="connection_error"}
    wire.onEvent={event in
        let type=event["type"] as? String ?? ""
        if type=="session.created" {created=true}
        if type=="session.updated" {ready=true}
        if type=="error" {error=(event["error"] as? [String:Any])?["code"] as? String ?? "api_error"}
        if type=="input_audio_buffer.speech_started" {vad+=1}
        if type=="input_audio_buffer.committed",let id=event["item_id"] as? String,!order.contains(id) {order.append(id)}
        if type=="conversation.item.input_audio_transcription.delta",first==nil {first=Date().timeIntervalSince(start)}
        if type=="conversation.item.input_audio_transcription.completed",let id=event["item_id"] as? String,let text=event["transcript"] as? String {words[id]=text;last=Date().timeIntervalSince(start)}
    }
    do {
        wire.connect();try await waitFor({created || !error.isEmpty},seconds:20)
        guard error.isEmpty else{throw PartnerError.message("baseline_connection_failed")}
        let input:[String:Any]=["format":["type":"audio/pcm","rate":24000],"transcription":["model":"gpt-live-transcribe","delay":"low","languages":["zh","en"],"keywords":["莉莉","讲故事","停一下","暂停"],"prompt":"中文故事交流，可能自然穿插少量英语。准确保留用户的短指令，不补全没有听到的内容。"],"noise_reduction":["type":"far_field"],"turn_detection":["type":"semantic_vad","eagerness":"low","create_response":false,"interrupt_response":false]]
        try await wire.send(["type":"session.update","session":["type":"realtime","model":"gpt-realtime-2.1","output_modalities":["text"],"audio":["input":input]]])
        try await waitFor({ready || !error.isEmpty},seconds:20)
        guard error.isEmpty else{throw PartnerError.message("baseline_configuration_failed")}
        start=Date()
        let stream=Data(repeating:0,count:14_400)+pcm+Data(repeating:0,count:288_000)
        for offset in stride(from:0,to:stream.count,by:960) {
            try await wire.send(["type":"input_audio_buffer.append","audio":stream.subdata(in:offset..<min(offset+960,stream.count)).base64EncodedString()])
            try await Task.sleep(nanoseconds:20_000_000)
        }
        return ["text":order.compactMap{words[$0]}.joined(),"vadStarts":vad,"commits":order.count,"missingCompletions":order.filter{words[$0]==nil}.count,"firstDeltaSeconds":first as Any? ?? NSNull(),"finalSeconds":last as Any? ?? NSNull(),"error":error]
    }catch _ {return ["text":"","error":error.isEmpty ? "baseline_probe_failed" : error]}
}

private func characterDistance(_ a:String,_ b:String)->Int {
    let a=Array(VoiceTurns.normalized(a)),b=Array(VoiceTurns.normalized(b));var prior=Array(0...b.count)
    for (i,x) in a.enumerated() {
        var next=[i+1]
        for (j,y) in b.enumerated(){next.append(min(next[j]+1,prior[j+1]+1,prior[j]+(x==y ? 0 : 1)))}
        prior=next
    }
    return prior.last ?? 0
}

@MainActor func voiceAccuracyLive() async {
    let args=CommandLine.arguments
    let output=args.firstIndex(of:"--output-dir").flatMap{args.count>$0+1 ? args[$0+1] : nil} ?? "/tmp/tinytales-v017-accuracy"
    let directory=URL(fileURLWithPath:output,isDirectory:true)
    let finalModel=args.firstIndex(of:"--final-model").flatMap{args.count>$0+1 ? args[$0+1] : nil} ?? "gpt-transcribe"
    let priorPath=args.firstIndex(of:"--baseline-report").flatMap{args.count>$0+1 ? args[$0+1] : nil}
    var results:[[String:Any]]=[]
    do {
        guard let key=Credentials.load() else{throw PartnerError.message("Saved connection unavailable")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let prior=priorPath.flatMap{try? Data(contentsOf:URL(fileURLWithPath:$0))}.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        let priorRows=(prior?["cases"] as? [[String:Any]] ?? [])
        let cases=speechEvalCases();var audio:[Data]=[]
        for sample in cases {
            let fixed=directory.appendingPathComponent(sample.id+".wav")
            if let saved=try? Data(contentsOf:fixed),saved.count>=44,String(decoding:saved.prefix(4),as:UTF8.self)=="RIFF" {
                audio.append(Data(saved.dropFirst(44)));continue
            }
            var pcm:Data
            if sample.text.isEmpty {pcm=Data(repeating:0,count:144_000)}
            else {
                let source=directory.appendingPathComponent(sample.id+".aiff")
                if !FileManager.default.fileExists(atPath:source.path) {
                    let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/say")
                    process.arguments=["-v",sample.voice,"-r",String(sample.rate),"-o",source.path,sample.text]
                    try process.run();process.waitUntilExit()
                    guard process.terminationStatus==0 else{throw PartnerError.message("Synthetic voice fixture failed")}
                }
                pcm=scaledPCM(try pitchedPCM(source,cents:sample.pitch),rms:sample.rms)
            }
            pcm=addSpeechTestNoise(pcm,rms:sample.noise);audio.append(pcm)
            try RealtimeNarrator.wave(pcm).write(to:directory.appendingPathComponent(sample.id+".wav"))
        }
        func evaluate(_ index:Int) async -> [String:Any] {
            let sample=cases[index],pcm=audio[index]
            let began=Date()
            let hash=SHA256.hash(data:pcm).map{String(format:"%02x",$0)}.joined()
            let cached=priorRows.first{$0["id"] as? String==sample.id && $0["sha256"] as? String==hash}?["baseline"] as? [String:Any]
            func oldResult() async -> [String:Any] {if let cached{return cached};return await baselineSpeech(pcm,key:key)}
            async let baseline=oldResult()
            var final:[String:Any]
            do {let text=try await OpenAIClient(key:key,transcriptionModel:finalModel).transcribeFinal(RealtimeNarrator.wave(pcm));final=["text":text,"requestSeconds":Date().timeIntervalSince(began),"error":""]}
            catch {final=["text":"","error":error.localizedDescription]}
            var old=await baseline
            func score(_ text:String)->[String:Any] {
                let normalized=VoiceTurns.normalized(text)
                return ["characterErrors":characterDistance(sample.text,text),"referenceCharacters":VoiceTurns.normalized(sample.text).count,"criticalContentPreserved":sample.text.isEmpty ? normalized.isEmpty : sample.required.allSatisfy{normalized.contains(VoiceTurns.normalized($0))},"empty":normalized.isEmpty]
            }
            final["score"]=score(final["text"] as? String ?? "")
            old["score"]=score(old["text"] as? String ?? "")
            return ["id":sample.id,"reference":sample.text,"category":sample.category,"voice":sample.voice,"rate":sample.rate,"pitchCents":sample.pitch,"rms":AudioMeter.level(pcm)/5,"noiseRMS":sample.noise,"seconds":Double(pcm.count)/48_000,"sha256":hash,"baselineReused":cached != nil,"baseline":old,"finalPass":final]
        }
        for start in stride(from:0,to:cases.count,by:4) {
            await withTaskGroup(of:[String:Any].self) { group in
                for index in start..<min(start+4,cases.count) {group.addTask {@MainActor in await evaluate(index)}}
                for await row in group {
                    results.append(row)
                    let old=row["baseline"] as? [String:Any] ?? [:],new=row["finalPass"] as? [String:Any] ?? [:]
                    print("\(row["id"] ?? ""): live=\(old["text"] ?? "") | final=\(new["text"] ?? "")");fflush(stdout)
                    let report:[String:Any]=["syntheticOnly":true,"physicalMicrophoneOpened":false,"physicalPlayback":false,"referenceNotIncludedInRequest":true,"finalModel":finalModel,"scope":"ASR component comparison; direct file transcription negative controls are not production VAD false-positive rates.","completed":results.count==cases.count,"cases":results.sorted{($0["id"] as? String ?? "")<($1["id"] as? String ?? "")}]
                    if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:directory.appendingPathComponent("comparison.json"))}
                }
            }
        }
        print("Completed \(results.count) paired synthetic ASR cases.")
    }catch{print("Accuracy evaluation failed: \(error.localizedDescription)");exit(1)}
}

/// Real ASR, intent and conversation APIs; fixed microphone input and simulated
/// playback timing. Only the drawing scenario invokes the real image service.
@MainActor func voiceScenariosLive() async {
    let args=CommandLine.arguments
    let output=args.firstIndex(of:"--output-dir").flatMap{args.count>$0+1 ? args[$0+1] : nil} ?? "/tmp/tinytales-v017-scenarios"
    let selected=args.firstIndex(of:"--case").flatMap{args.count>$0+1 ? args[$0+1] : nil}
    let directory=URL(fileURLWithPath:output,isDirectory:true)
    let sources=URL(fileURLWithPath:"/tmp/tinytales-v017-accuracy",isDirectory:true)
    let allScenarios:[String]=["drawing","witch-answer","quoted-stop","voice-stop","backchannel","manual-stop","cancel-retry","edit-request","noise"]
    let scenarios=allScenarios.filter{selected==nil || selected==$0}
    var overall=true
    do {
        guard let key=Credentials.load() else{throw PartnerError.message("Saved connection unavailable")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let swatch=NSImage(size:NSSize(width:32,height:32));swatch.lockFocus();NSColor.green.setFill();NSRect(x:0,y:0,width:32,height:32).fill();swatch.unlockFocus()
        let fixtureImage=NSBitmapImageRep(data:swatch.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        for scenario in scenarios {
            let store=try phoneFixture(),wire=ObservedWire(key:key),audio=SilentCallAudio(),speech=FakeTeacherSpeech(),client=OpenAIClient(key:key),session=StorySession()
            audio.simulatePlayback=true
            var users:[String]=[],replies:[String]=[],trace:[[String:Any]]=[],canonical:[String]=[],deleted:[String]=[]
            var pictureRequests:[String]=[],pictures=0,cancelTriggered=false,phase="setup"
            var pictureReferences:[[String:Any]]=[],picturePlans:[String]=[],toolResults:[String]=[]
            var pictureFailure:String?
            client.onArtworkPlan={if let text=$0 {picturePlans.append(text)}}
            let began=Date()
            let call=RealtimeCall(store:store,wire:wire,audio:audio,voice:"teacher",session:session,illustrator:{request in
                pictureRequests.append(request.text)
                pictureReferences.append(request.referenceData)
                if scenario=="drawing" {
                    do{return try await client.illustrate(request)}
                    catch{pictureFailure=error.localizedDescription;throw error}
                }
                return GeneratedArtwork(data:fixtureImage,caption:"一张绿色的测试色块。",source:Story(title:"测试色块",summary:"画面是一张绿色色块。"))
            },teacherSpeech:speech,intentJudge:client,finalRecognizer:client)
            defer{call.hangUp();speech.finish();try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
            call.onUserText={_,text in users.append(text)}
            call.onAssistantText={_,text,_,_,_ in replies.append(text)}
            call.onArtwork={_,art in
                pictures+=1
                if scenario=="drawing" {try? FileManager.default.copyItem(at:art.url,to:directory.appendingPathComponent("drawing-result."+art.fileExtension))}
            }
            call.onProtocolEvent={type in
                if type.hasPrefix("input_final_") || type.hasPrefix("voice_final_intent:") || ["manual_turn_stopped","input_needs_correction","verified_text_committed","voice_input_pause","voice_stop","backchannel_ignored"].contains(type) {
                    trace.append(["type":type,"seconds":Date().timeIntervalSince(began)])
                }
                if scenario=="cancel-retry",phase=="cancel",type=="input_final_recognition_started",!cancelTriggered {
                    cancelTriggered=true;Task{await call.cancelPendingInput()}
                }
            }
            wire.observe={event in
                let type=event["type"] as? String ?? ""
                if ["conversation.item.input_audio_transcription.completed","input_audio_buffer.speech_started","input_audio_buffer.speech_stopped","response.created","error"].contains(type) {
                    var row:[String:Any]=["type":type,"seconds":Date().timeIntervalSince(began)]
                    for key in ["transcript","audio_start_ms","audio_end_ms"] {if let value=event[key]{row[key]=value}}
                    if let error=event["error"] as? [String:Any]{row["errorCode"]=error["code"];row["parameter"]=error["param"]}
                    trace.append(row)
                }
            }
            wire.observeSent={event in
                if event["type"] as? String=="conversation.item.delete",let id=event["item_id"] as? String{deleted.append(id)}
                if let item=event["item"] as? [String:Any],item["role"] as? String=="user",let content=(item["content"] as? [[String:Any]])?.first,content["type"] as? String=="input_text",let text=content["text"] as? String {canonical.append(text)}
                if let item=event["item"] as? [String:Any],item["type"] as? String=="function_call_output",let text=item["output"] as? String {toolResults.append(text)}
            }
            func feed(_ pcm:Data) async throws {
                for offset in stride(from:0,to:pcm.count,by:960) {
                    try require(call.active,"call ended: \(call.notice)")
                    audio.onMicrophone?(pcm.subdata(in:offset..<min(offset+960,pcm.count)))
                    try await Task.sleep(nanoseconds:20_000_000)
                }
            }
            func silence(_ seconds:Double) async throws {try await feed(Data(repeating:0,count:Int(seconds*48_000)))}
            func until(_ condition:()->Bool,seconds:Double=35) async throws {
                let end=Date().addingTimeInterval(seconds)
                while !condition(),Date()<end {try await silence(0.02)}
                try require(condition(),"expected scenario event timed out")
            }
            func say(_ name:String) async throws {
                let data=try Data(contentsOf:sources.appendingPathComponent(name+".wav"))
                try require(data.count>44,"missing fixed speech")
                try await feed(Data(data.dropFirst(44)))
            }
            func beginNarration(question:Bool=false) async throws {
                let text=question ? "你觉得小木屋里会是谁在等小猫？" : "小兔带着三个红苹果去看奶奶。它沿着花园的小路慢慢走，先经过一棵大树，再走过小桥。"
                try await call.sendText("请原样说出这段话，不增加别的内容："+text)
                try await until({!speech.requests.isEmpty})
                speech.requests.last!.chunk(Data(repeating:1,count:question ? 14_400 : 1_440_000));speech.finish()
                if question {try await silence(0.8)}
            }
            var checks:[String:Bool]=[:]
            do {
                try await call.connect(history:[],microphone:false,greet:false)
                try await until({call.state == .listening},seconds:25)
                phase="target"
                switch scenario {
                case "drawing":
                    session.current=Story(id:"eval-drawing-story",title:"画蛇添足",summary:"一个人先画好了一条蛇，又给蛇添了脚。另一个人说蛇本来没有脚。")
                    try await say("picture-direct")
                    try await until({pictures==1 || pictureFailure != nil},seconds:150)
                    checks["drawingIntentPreserved"]=users.count==1 && users[0].contains("画") && users[0].contains("图")
                    checks["actualPictureCreated"]=pictures==1 && pictureRequests.count==1
                case "witch-answer":
                    try await beginNarration(question:true);let before=replies.count
                    try await say("witch-answer");try await until({replies.count>before})
                    checks["witchPreserved"]=users.last?.contains("老巫婆")==true && replies.last?.contains("巫婆")==true
                case "quoted-stop":
                    try await beginNarration();let before=replies.count
                    try await say("quoted-stop");try await until({replies.count>before})
                    checks["wordQuestionAnswered"]=users.last?.contains("意思")==true && !trace.contains{$0["type"] as? String=="voice_stop"}
                case "voice-stop":
                    try await beginNarration();let before=replies.count
                    try await say("stop");try await until({call.state == .listening && audio.outputStops>0})
                    checks["spokenStopWorks"]=users.last.map{VoiceTurns.isStopRequest($0)}==true && replies.count==before
                case "backchannel":
                    try await beginNarration();let before=replies.count
                    try await say("backchannel");try await silence(6)
                    checks["acknowledgementDoesNotInterrupt"]=users.isEmpty && audio.outputStops==0 && replies.count==before
                case "manual-stop":
                    try await beginNarration();let stops=audio.stops,start=Date()
                    await call.stopCurrentTurn()
                    checks["localStopUnder300ms"]=audio.lastOutputStopDate.map{$0.timeIntervalSince(start)<0.3 && $0>=start} == true
                    let bytes=audio.received.count;speech.requests[0].chunk(Data(repeating:1,count:960));try await silence(2)
                    checks["callRemainsConnected"]=call.active && audio.stops==stops && call.state == .listening
                    checks["noLatePlayback"]=audio.received.count==bytes
                case "cancel-retry":
                    phase="cancel";try await say("picture-direct");try await until({cancelTriggered});try await silence(1)
                    checks["cancelDidNotExecute"]=users.isEmpty && pictureRequests.isEmpty && canonical.isEmpty
                    phase="retry";try await say("science");try await until({!replies.isEmpty})
                    checks["nextRequestRecovered"]=users.count==1 && users[0].contains("月亮") && pictureRequests.isEmpty
                case "edit-request":
                    try await say("story-request");try await until({!replies.isEmpty})
                    let originalID=call.latestVoiceInputID
                    call.toggleMute()
                    await call.retractLatestVoiceInput()
                    try await call.sendText("给我画一张图片")
                    try await until({pictures==1})
                    checks["oldInputRemoved"]=originalID.map{deleted.contains($0)}==true
                    checks["correctedPictureRequest"]=pictures==1 && pictureRequests.last?.contains("给我画一张图片")==true
                    call.toggleMute();let before=replies.count
                    try await silence(0.6);try await say("science");try await until({replies.count>before})
                    checks["voiceAfterEditingRecovered"]=users.last?.contains("月亮")==true && !call.inputNeedsCorrection && pictures==1
                default:
                    try await say("noise-only");try await say("silence");try await silence(5)
                    checks["noiseProducesNoTurn"]=users.isEmpty && replies.isEmpty && canonical.isEmpty
                }
                if !users.isEmpty {checks["displayMatchesCanonicalInput"]=users.allSatisfy{canonical.contains($0)}}
                checks["connectionHealthy"]=call.active && call.notice.isEmpty
                checks["noProtocolErrors"] = !trace.contains{$0["type"] as? String=="error"}
            }catch {checks["scenarioCompleted"]=false;trace.append(["error":error.localizedDescription])}
            let success=checks.values.allSatisfy{$0};overall=overall && success
            let report:[String:Any]=["scenario":scenario,"success":success,"checks":checks,"syntheticOnly":true,"physicalMicrophoneOpened":false,"physicalPlayback":false,"playbackSimulated":true,"realImagePipelineRequested":scenario=="drawing" && !pictureRequests.isEmpty,"actualImageGenerationCompleted":scenario=="drawing" && client.artworkDiagnostics["generationSeconds_1"] != nil,"users":users,"replies":replies,"canonicalInputs":canonical,"pictureRequests":pictureRequests,"pictureReferences":pictureReferences,"picturePlans":picturePlans,"pictureFailure":pictureFailure as Any? ?? NSNull(),"artworkDiagnostics":client.artworkDiagnostics,"toolResults":toolResults,"pictures":pictures,"inputPackets":call.inputPackets,"trace":trace]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(scenario+".json"))
            print("Scenario \(scenario): \(success), users: \(users.joined(separator:" | "))");fflush(stdout)
            call.hangUp();speech.finish()
        }
        if !overall{exit(1)}
    }catch{print("Scenario evaluation failed: \(error.localizedDescription)");exit(1)}
}
