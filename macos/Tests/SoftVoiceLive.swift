import Foundation
import AVFoundation

func pitchedPCM(_ url:URL,cents:Float) throws -> Data {
    let file=try AVAudioFile(forReading:url)
    let engine=AVAudioEngine(),player=AVAudioPlayerNode(),pitch=AVAudioUnitTimePitch()
    pitch.pitch=cents;pitch.rate=1
    let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:24000,channels:1,interleaved:false)!
    engine.attach(player);engine.attach(pitch)
    engine.connect(player,to:pitch,format:file.processingFormat);engine.connect(pitch,to:engine.mainMixerNode,format:format)
    try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
    let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
    player.scheduleFile(file,at:nil)
    try engine.start();player.play();defer{player.stop();engine.stop()}
    let length=Int64(Double(file.length)*24000/file.processingFormat.sampleRate)+24000
    var data=Data(),attempts=0
    while engine.manualRenderingSampleTime<length && attempts<10000 {
        attempts+=1
        let count=AVAudioFrameCount(min(4096,length-engine.manualRenderingSampleTime))
        let status=try engine.renderOffline(count,to:buffer)
        if status == .success,let samples=buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) {
                var sample=Int16(clamping:Int((max(-1,min(1,samples[i]))*32767).rounded())).littleEndian
                withUnsafeBytes(of:&sample){data.append(contentsOf:$0)}
            }
        }else if status == .error {throw PartnerError.message("Offline pitch fixture failed")}
    }
    guard !data.isEmpty else{throw PartnerError.message("Offline pitch fixture was empty")}
    return data
}
func scaledPCM(_ data:Data,rms:Double)->Data {
    let gain=rms/max(0.000001,AudioMeter.level(data)/5),bytes=[UInt8](data)
    var output=Data()
    for i in stride(from:0,to:bytes.count-1,by:2) {
        let sample=Double(Int16(bitPattern:UInt16(bytes[i]) | UInt16(bytes[i+1])<<8))
        var value=Int16(clamping:Int((sample*gain).rounded())).littleEndian
        withUnsafeBytes(of:&value){output.append(contentsOf:$0)}
    }
    return output
}
@MainActor func softVoiceComparisonLive() async {
    let label=CommandLine.arguments.last ?? "baseline"
    let directory=URL(fileURLWithPath:"artifacts/v016-child-input",isDirectory:true)
    var report:[String:Any]=["profile":label,"syntheticOnly":true,"microphoneOpened":false,"notActualChildVoice":true]
    do {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        guard let key=Credentials.load() else{throw PartnerError.message("No saved connection")}
        let source=URL(fileURLWithPath:"artifacts/v013-duplex")
        let normal=try pitchedPCM(source.appendingPathComponent("caller-question.wav"),cents:0)
        let high=try pitchedPCM(source.appendingPathComponent("caller-correction.wav"),cents:400)
        let soft=try pitchedPCM(source.appendingPathComponent("caller-sharing.wav"),cents:400)
        let quiet=try pitchedPCM(source.appendingPathComponent("caller-stop.wav"),cents:400)
        var noise=Data(),random:UInt64=42
        for _ in 0..<72000 {random=random &* 6364136223846793005 &+ 1;var value=Int16(Int((random>>32)&0xff)-128).littleEndian;withUnsafeBytes(of:&value){noise.append(contentsOf:$0)}}
        let fixtures:[(String,Data,[String])]=[("normal",scaledPCM(normal,rms:0.03),["小兔","苹果"]),("higher-pitch",scaledPCM(high,rms:0.03),["小猫"]),("soft-higher-pitch",scaledPCM(soft,rms:0.003),["小狗"]),("very-soft-higher-pitch",scaledPCM(quiet,rms:0.001),["别讲"]),("noise",scaledPCM(noise,rms:0.002),[])]
        let wire=OpenAIRealtimeWire(key:key,model:"gpt-realtime-2.1");defer{wire.close()}
        var created=false,ready=false,wireError="",current="",transcripts:[String]=[],deltas=0,starts=0,commits=0,latencies:[Double]=[]
        var began=Date()
        wire.onError={wireError=$0}
        wire.onEvent={event in
            let type=event["type"] as? String ?? ""
            if type=="session.created" {created=true}
            if type=="session.updated" {ready=true}
            if type=="error" {wireError=(event["error"] as? [String:Any])?["code"] as? String ?? "api_error"}
            if type=="input_audio_buffer.speech_started" {starts+=1}
            if type=="input_audio_buffer.committed" {commits+=1}
            if type=="conversation.item.input_audio_transcription.delta" {deltas+=1}
            if type=="conversation.item.input_audio_transcription.completed",let words=event["transcript"] as? String {transcripts.append(words);latencies.append(Date().timeIntervalSince(began))}
        }
        wire.connect()
        let connected=Date()
        while !created && wireError.isEmpty && Date().timeIntervalSince(connected)<20 {try await Task.sleep(nanoseconds:20_000_000)}
        guard created else{throw PartnerError.message(wireError.isEmpty ? "Connection timed out" : wireError)}
        let sensitive=label=="sensitive" || label=="gentle"
        let noFilter=label=="no-filter" || label=="gentle" || label=="boosted"
        var input:[String:Any]=["format":["type":"audio/pcm","rate":24000],"transcription":["model":"gpt-live-transcribe","delay":"low","languages":["zh","en"],"keywords":["莉莉","讲故事","停一下","暂停"],"prompt":"中文故事交流，可能自然穿插少量英语。准确保留用户的短指令，不补全没有听到的内容。"],"noise_reduction":noFilter ? NSNull() : ["type":"far_field"]]
        input["turn_detection"]=sensitive ? ["type":"server_vad","threshold":NSDecimalNumber(string:"0.3"),"prefix_padding_ms":600,"silence_duration_ms":1100,"create_response":false,"interrupt_response":false] : ["type":"semantic_vad","eagerness":"low","create_response":false,"interrupt_response":false]
        report["inputConfiguration"]=input
        try await wire.send(["type":"session.update","session":["type":"realtime","model":"gpt-realtime-2.1","output_modalities":["text"],"audio":["input":input]]])
        let configured=Date()
        while !ready && wireError.isEmpty && Date().timeIntervalSince(configured)<20 {try await Task.sleep(nanoseconds:20_000_000)}
        guard ready else{throw PartnerError.message(wireError.isEmpty ? "Configuration timed out" : wireError)}
        func feed(_ data:Data) async throws {
            for offset in stride(from:0,to:data.count,by:960) {
                guard wireError.isEmpty else{throw PartnerError.message(wireError)}
                var packet=data.subdata(in:offset..<min(offset+960,data.count))
                if label == "boosted" {
                    let bytes=[UInt8](packet),rms=AudioMeter.level(packet)/5
                    var peak=0.0
                    for i in stride(from:0,to:bytes.count-1,by:2) {peak=max(peak,abs(Double(Int16(bitPattern:UInt16(bytes[i])|UInt16(bytes[i+1])<<8)))/32768)}
                    let gain=min(3,max(1,0.03/max(rms,0.000001)),max(1,0.9/max(peak,0.000001)))
                    var output=Data()
                    for i in stride(from:0,to:bytes.count-1,by:2) {var sample=Int16(clamping:Int((Double(Int16(bitPattern:UInt16(bytes[i])|UInt16(bytes[i+1])<<8))*gain).rounded())).littleEndian;withUnsafeBytes(of:&sample){output.append(contentsOf:$0)}}
                    packet=output
                }
                try await wire.send(["type":"input_audio_buffer.append","audio":packet.base64EncodedString()])
                try await Task.sleep(nanoseconds:20_000_000)
            }
        }
        var rows:[[String:Any]]=[]
        for (name,data,keywords) in fixtures {
            try await wire.send(["type":"input_audio_buffer.clear"])
            current=name;transcripts=[];deltas=0;starts=0;commits=0;latencies=[];began=Date()
            try await feed(data)
            let speechEnded=Date().timeIntervalSince(began)
            try await feed(Data(repeating:0,count:48000*9))
            let normalized=VoiceTurns.normalized(transcripts.joined())
            let passed=name=="noise" ? normalized.isEmpty : keywords.allSatisfy{normalized.contains($0)}
            rows.append(["case":name,"rms":AudioMeter.level(data)/5,"speechStarts":starts,"commits":commits,"deltas":deltas,"transcripts":transcripts,"passed":passed,"finalAfterAudioSeconds":latencies.last.map{$0-speechEnded} ?? -1])
            print("\(label) \(current): \(passed), VAD=\(starts), text=\(transcripts.joined(separator:" | "))")
        }
        report["success"]=true;report["cases"]=rows
    }catch{report["success"]=false;report["error"]=error.localizedDescription;print("Soft voice check failed: \(error.localizedDescription)")}
    try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(label+".json"))
    if report["success"] as? Bool != true {exit(1)}
}
