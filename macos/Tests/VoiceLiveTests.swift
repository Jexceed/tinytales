import Foundation
import AVFoundation

/// Fixed synthetic utterances exercise the production microphone queue and API.
/// No physical microphone is opened or uploaded by these evaluations.
@MainActor func voiceRecognitionEvaluation() async {
    guard let key=Credentials.load() else{print("Missing stored credential");exit(1)}
    let args=CommandLine.arguments
    let scenario=args.firstIndex(of:"--voice-eval").flatMap{args.count>$0+1 ? args[$0+1] : nil} ?? "quiet"
    let outputDirectory=args.firstIndex(of:"--output-dir").flatMap{args.count>$0+1 ? args[$0+1] : nil} ?? "/tmp/tinytales-voice-eval"
    let directory=URL(fileURLWithPath:outputDirectory,isDirectory:true)
    let pauseSeconds=1.1
    let teacherMode=args.contains("--teacher")
    let started=Date();var events:[[String:Any]]=[],users:[String]=[],replies:[String]=[],spokenItems=Set<String>()
    var firstAudio:Date?,inputFinished:Date?,earlyBytes=0,earlyResponses=0,stoppedBeforeNextRequest=false
    func fixture(_ name:String,_ text:String) async throws -> Data {
        let url=directory.appendingPathComponent(name+".wav")
        if !FileManager.default.fileExists(atPath:url.path) {try await OpenAIClient(key:key).speech(text,voice:"marin").write(to:url)}
        let file=try AVAudioFile(forReading:url)
        let input=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!;try file.read(into:input)
        let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:24000,channels:1,interleaved:true)!
        let converter=AVAudioConverter(from:file.processingFormat,to:format)!
        let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(Double(file.length)*24000/file.processingFormat.sampleRate)+128)!
        var supplied=false;var error:NSError?
        converter.convert(to:output,error:&error){_,state in
            if supplied {state.pointee = .endOfStream;return nil};supplied=true;state.pointee = .haveData;return input
        }
        if let error{throw error}
        return Data(bytes:output.int16ChannelData![0],count:Int(output.frameLength)*2)
    }
    do {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let store=try phoneFixture();defer{try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
        let wire=ObservedWire(key:key),audio=SilentCallAudio()
        audio.simulatePlayback=teacherMode
        let resources=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("macos/Resources")
        let teacher=teacherMode ? TeacherSpeechClient.discover(resources:resources) : nil
        let client=OpenAIClient(key:key)
        let call=RealtimeCall(store:store,wire:wire,audio:audio,voice:teacherMode ? "teacher" : "shimmer",teacherSpeech:teacher,intentJudge:client,finalRecognizer:client);defer{call.hangUp()}
        var pcm=try await fixture("voice-story-request","给我讲个故事。")
        var second=Data()
        if scenario=="pause" {
            pcm=try await fixture("voice-incomplete-request","给我讲一个")
            second=try await fixture("voice-story-detail","小马过河的故事。")
        } else if scenario=="interrupt" {
            second=try await fixture("voice-stop-request","停一下。")
        } else if scenario=="quiet" {
            let bytes=[UInt8](pcm);var result=Data(),random:UInt64=42
            for i in stride(from:0,to:bytes.count-1,by:2) {
                random=random &* 6364136223846793005 &+ 1
                let noise=(Double((random>>32)&0xffff)/65535-0.5)*60
                let sample=Double(Int16(bitPattern:UInt16(bytes[i])|UInt16(bytes[i+1])<<8))
                var mixed=Int16(clamping:Int((sample*0.12+noise).rounded())).littleEndian
                withUnsafeBytes(of:&mixed){result.append(contentsOf:$0)}
            }
            pcm=result
        }
        wire.observe={event in
            let type=event["type"] as? String ?? ""
            if type=="response.output_audio.delta" {
                if teacherMode {events.append(["type":"unexpected_cloud_audio"]);return}
                if firstAudio==nil {firstAudio=Date()}
                if let item=event["item_id"] as? String {spokenItems.insert(item)}
                return
            }
            guard type.hasPrefix("input_audio_buffer.") || type.contains("input_audio_transcription") || ["response.created","response.done","response.output_audio_transcript.done","error"].contains(type) else{return}
            var record:[String:Any]=["type":type,"atSeconds":Date().timeIntervalSince(started)]
            for field in ["item_id","transcript","delta","audio_start_ms","audio_end_ms"] {if let value=event[field]{record[field]=value}}
            if let error=event["error"] as? [String:Any]{record["errorCode"]=error["code"] ?? "";record["errorParameter"]=error["param"] ?? "";print("Voice API error: \(error["code"] ?? "unknown") parameter: \(error["param"] ?? "")")}
            if let response=event["response"] as? [String:Any]{record["responseID"]=response["id"];record["status"]=response["status"];record["outputTypes"]=(response["output"] as? [[String:Any]] ?? []).map{($0["name"] ?? $0["type"]) as? String ?? ""}}
            events.append(record)
        }
        call.onUserText={_,text in users.append(text)}
        var assistantItem=""
        call.onAssistantText={id,text,_,_,_ in replies.append(text);assistantItem=id}
        if teacherMode {call.onAudio={_ in if firstAudio==nil {firstAudio=Date()};spokenItems.insert(assistantItem)}}
        call.onProtocolEvent={type in if type.hasPrefix("voice_final_intent:") || ["empty_input_ignored","playback_echo_ignored","input_transcription_timeout","unrequested_response_ignored","voice_stop","backchannel_ignored","voice_input_pause"].contains(type) {events.append(["type":type,"atSeconds":Date().timeIntervalSince(started)])}}
        func feed(_ pcm:Data) async throws {
            for offset in stride(from:0,to:pcm.count,by:960) {
                try require(call.active,"call ended during input: \(call.notice)")
                let packet=pcm.subdata(in:offset..<min(offset+960,pcm.count))
                if call.state == .connecting {earlyBytes+=packet.count}
                audio.onMicrophone?(packet)
                try await Task.sleep(nanoseconds:20_000_000)
            }
        }
        try await call.connect(history:[],microphone:false,greet:false)
        if scenario != "early" {try await waitFor({call.state == .listening || !call.active},seconds:25)}
        try await feed(Data(repeating:0,count:5760))
        try await feed(pcm)
        if scenario=="pause" {
            try await feed(Data(repeating:0,count:Int(48000*pauseSeconds)))
            earlyResponses=wire.sentTypes.filter{$0=="response.create"}.count
            try await feed(second)
        }
        inputFinished=Date()
        try await waitFor({call.state != .connecting || !call.active},seconds:25)
        if scenario=="interrupt" {
            let deadline=Date().addingTimeInterval(25)
            while call.state != .speaking && Date()<deadline {try await feed(Data(repeating:0,count:960))}
            try require(call.state == .speaking,"initial narration did not start")
            try await feed(second)
            try await feed(Data(repeating:0,count:48000*9))
            stoppedBeforeNextRequest=users.contains{VoiceTurns.isStopRequest($0)} && replies.count==(teacherMode ? 1 : 0) && audio.outputStops>0 && call.state == .listening && wire.sentTypes.filter{$0=="response.create"}.count==1
            try await feed(pcm)
        }
        try await feed(Data(repeating:0,count:48000*9))
        try await waitFor({!replies.isEmpty || !call.active},seconds:40)
        let before=wire.sentTypes.filter{$0=="response.create"}.count,replyCount=replies.count
        try await feed(Data(repeating:0,count:48000*10))
        let extra=wire.sentTypes.filter{$0=="response.create"}.count-before
        let recognized=VoiceTurns.normalized(users.joined())
        let inputCorrect=scenario=="pause" ? recognized.contains("给我讲一个") && recognized.contains("小马过河的故事") : recognized.contains("给我讲个故事")
        let expectedSpokenItems=scenario=="interrupt" ? 2 : 1
        let expectedReplies=teacherMode && scenario=="interrupt" ? 2 : 1
        let oneTurn=scenario != "pause" || users.count==1
        let success=call.active && inputCorrect && oneTurn && replyCount==expectedReplies && replies.count==expectedReplies && extra==0 && earlyResponses==0 && spokenItems.count==expectedSpokenItems && (scenario != "early" || earlyBytes>0) && (scenario != "interrupt" || stoppedBeforeNextRequest) && !events.contains{$0["type"] as? String=="unexpected_cloud_audio"}
        let report:[String:Any]=["success":success,"scenario":scenario,"teacherVoice":teacherMode,"syntheticOnly":true,"microphoneOpened":false,"physicalPlayback":false,"pauseBetweenClausesSeconds":scenario=="pause" ? pauseSeconds : 0,"oneUserMessageForPause":oneTurn,"inputRMS":AudioMeter.level(pcm)/5,"startupBufferedSeconds":Double(earlyBytes)/48000,"responsesBeforeSecondClause":earlyResponses,"stoppedBeforeNextRequest":stoppedBeforeNextRequest,"users":users,"replies":replies,"spokenItems":spokenItems.count,"extraRequestsDuringTenSecondsSilence":extra,"firstAudioAfterSpeechSeconds":firstAudio.map{$0.timeIntervalSince(inputFinished ?? started)} ?? -1,"notice":call.notice,"events":events]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("\(teacherMode ? "teacher" : "voice")-eval-\(scenario).json"))
        print("Voice \(scenario): \(success); recognized: \(users.joined(separator:" | ")); replies: \(replies.count); spoken items: \(spokenItems.count); extra silence requests: \(extra)")
        if !success{exit(1)}
    }catch{
        let report:[String:Any]=["success":false,"scenario":scenario,"syntheticOnly":true,"microphoneOpened":false,"error":error.localizedDescription,"users":users,"replies":replies,"events":events]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("\(teacherMode ? "teacher" : "voice")-eval-\(scenario).json"))
        print("Voice \(scenario) failed: \(error.localizedDescription)");exit(1)
    }
}
