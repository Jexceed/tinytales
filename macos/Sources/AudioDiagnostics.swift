import Foundation
import AVFoundation
import AppKit

/// Local hardware verification: microphone samples are counted and discarded;
/// only silence is played and no connection to a model is created.
@MainActor enum AudioDiagnostics {
    private static var started = false
    static func run(to url: URL) async {
        guard !started else { return }; started = true
        var permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .notDetermined && CommandLine.arguments.contains("--request-microphone") {
            _ = await MicrophoneAuthorization.shared.obtain()
            permission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        var result: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "permission": permission.rawValue, "networkUsed": false, "audioSaved": false]
        func save() {
            do {try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)}
            catch {FileHandle.standardError.write(Data("Audio diagnostic report could not be written.\n".utf8))}
        }
        result["stage"]="permission-checked";save()
        if CommandLine.arguments.contains("--permission-only") {
            result["permissionOnly"] = true; result["success"] = permission == .authorized
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            NSApplication.shared.terminate(nil); return
        }
        var cycles: [[String: Any]] = []
        if permission == .authorized {
            for cycle in 1...3 {
                let audio=NativeCallAudio()
                var inputPackets = 0, inputBytes = 0, drainedIDs:[String]=[]
                var phase="starting",inputWhilePlaying=0,inputWhilePaused=0
                audio.onMicrophone = { data in inputPackets += 1; inputBytes += data.count;if phase=="playing"{inputWhilePlaying+=1};if phase=="paused"{inputWhilePaused+=1} }
                audio.onDrained = { drainedIDs.append($0) }
                let began = Date()
                do {
                    result["stage"]="starting-cycle-\(cycle)";save()
                    try audio.start()
                    let startup = Date().timeIntervalSince(began)
                    audio.beginOutput(itemID: "local-silence-\(cycle)")
                    audio.enqueue(Data(repeating: 0, count: 24000))
                    audio.outputEnded()
                    phase="playing";result["stage"]="playing-cycle-\(cycle)";save()
                    try await Task.sleep(nanoseconds:150_000_000)
                    audio.pauseOutput();phase="paused"
                    let pausePosition=audio.playedMilliseconds
                    result["stage"]="paused-cycle-\(cycle)";save()
                    try await Task.sleep(nanoseconds:650_000_000)
                    let pausePreserved = !audio.isOutputPlaying && audio.pendingPlaybackBuffers>0 && drainedIDs.isEmpty && audio.playedMilliseconds==pausePosition
                    audio.resumeOutput();phase="playing";result["stage"]="resumed-cycle-\(cycle)";save()
                    try await Task.sleep(nanoseconds:700_000_000)
                    audio.beginOutput(itemID:"cancelled-\(cycle)")
                    audio.enqueue(Data(repeating:0,count:96000));audio.outputEnded()
                    try await Task.sleep(nanoseconds:100_000_000)
                    audio.stopOutput()
                    audio.beginOutput(itemID:"replacement-\(cycle)")
                    audio.enqueue(Data(repeating:0,count:24000));audio.outputEnded()
                    try await Task.sleep(nanoseconds:900_000_000)
                    let running = audio.isRunning, played = audio.playedMilliseconds
                    audio.stop()
                    let atStop = inputPackets
                    try await Task.sleep(nanoseconds: 150_000_000)
                    let boundariesCorrect=drainedIDs==["local-silence-\(cycle)","replacement-\(cycle)"]
                    let passed = running && inputWhilePlaying>0 && inputWhilePaused>0 && pausePreserved && boundariesCorrect && played >= 400 && !audio.isRunning && inputPackets == atStop && audio.diagnostics["voiceProcessing"] as? Bool == true
                    cycles.append(["cycle": cycle, "success": passed, "startupSeconds": startup, "microphonePackets": inputPackets, "microphoneBytes": inputBytes,"microphonePacketsDuringPlayback":inputWhilePlaying,"microphonePacketsDuringPause":inputWhilePaused,"pausePreservedBuffer":pausePreserved, "playbackDrained":boundariesCorrect,"playbackBoundaries":drainedIDs,"cancelledPlaybackIgnored":boundariesCorrect, "playedMilliseconds": played, "stopped": !audio.isRunning, "lateMicrophonePackets": inputPackets-atStop, "formats": audio.diagnostics])
                } catch {
                    audio.stop()
                    cycles.append(["cycle": cycle, "success": false, "error": error.localizedDescription, "formats": audio.diagnostics])
                    break
                }
                result["cycles"]=cycles;save()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        result["cycles"] = cycles
        result["stage"]="completed"
        result["success"] = cycles.count == 3 && cycles.allSatisfy { $0["success"] as? Bool == true }
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        NSApplication.shared.terminate(nil)
    }
}

@MainActor enum LocalVoiceDiagnostics {
    private static var started = false
    static func run(to url: URL) async {
        guard !started else { return }; started = true
        var result: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "networkUsed": false, "microphoneOpened": false]
        if let root = LocalTTSClient.discover(), let resources = Bundle.main.resourceURL {
            let client = LocalTTSClient(engineRoot: root, resources: resources)
            let began = Date()
            do {
                let data = try await client.synthesize("你好呀，我是莉莉。我们一起讲个小故事吧。")
                let audio = try AVAudioPlayer(data: data)
                result["success"] = audio.duration > 1 && data.count > 1000
                result["audioBytes"] = data.count; result["seconds"] = audio.duration
                result["runtime"] = root.path; result["elapsedSeconds"] = Date().timeIntervalSince(began)
            } catch { result["success"] = false; result["error"] = error.localizedDescription }
            client.shutdown()
        } else { result["success"] = false; result["error"] = "Managed speech runtime is missing" }
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        NSApplication.shared.terminate(nil)
    }
}

// UI-only call fixture. Selected only by --verify-launch --sample-voice;
// it never requests permission, opens hardware, or sends a network request.
@MainActor final class ConversationPreviewWire:RealtimeWire {
    var onEvent:(([String:Any])->Void)?
    var onError:((String)->Void)?
    private var closed=true
    private let sample:String
    init(sample:String="") {self.sample=sample}
    func connect() {
        closed=false
        Task {@MainActor [weak self] in
            guard let self,!self.closed else{return}
            self.onEvent?(["type":"session.created"])
        }
    }
    func send(_ event:[String:Any]) async throws {
        guard !closed else {return}
        if event["type"] as? String=="response.create",sample=="drawing" {
            guard let response=event["response"] as? [String:Any],response["tool_choice"] != nil else{return}
            onEvent?(["type":"response.created","response":["id":"drawing-preview"]])
            onEvent?(["type":"response.done","response":["id":"drawing-preview","status":"completed","output":[["type":"function_call","name":"illustrate_story","call_id":"drawing-tool","arguments":"{}"]]]])
            return
        }
        if event["type"] as? String=="response.create",sample=="duplex" {
            onEvent?(["type":"response.created","response":["id":"duplex-preview"]])
            onEvent?(["type":"response.output_audio_transcript.delta","response_id":"duplex-preview","item_id":"preview-speech","delta":"小兔抱着苹果，慢慢走向奶奶的家。"])
            onEvent?(["type":"response.output_audio.delta","response_id":"duplex-preview","item_id":"preview-speech","delta":Data(repeating:0,count:960).base64EncodedString()])
            return
        }
        if event["type"] as? String == "session.update" {
            onEvent?(["type":"session.updated"])
            guard !sample.isEmpty,sample != "duplex",sample != "drawing" else{return}
            Task {@MainActor [weak self] in
                try? await Task.sleep(nanoseconds:150_000_000)
                guard let self,!self.closed else{return}
                self.onEvent?(["type":"input_audio_buffer.speech_started","item_id":"preview-user"])
                try? await Task.sleep(nanoseconds:100_000_000)
                guard !self.closed else{return}
                if self.sample=="partial" {
                    self.onEvent?(["type":"conversation.item.input_audio_transcription.delta","item_id":"preview-user","delta":"给我讲个故事"])
                } else {
                    self.onEvent?(["type":"input_audio_buffer.speech_stopped","item_id":"preview-user"])
                    self.onEvent?(["type":"input_audio_buffer.committed","item_id":"preview-user"])
                    self.onEvent?(["type":"conversation.item.input_audio_transcription.failed","item_id":"preview-user","error":["code":"preview_failed"]])
                }
            }
        }
    }
    func close() {closed=true}
}
@MainActor final class ConversationPreviewAudio:CallAudio {
    var onMicrophone:((Data)->Void)?
    var onDrained:((String)->Void)?
    var onInputLevel:((Double)->Void)?
    var onOutputLevel:((Double)->Void)?
    var muted=false
    var playedMilliseconds=0
    func start() {onInputLevel?(0.45)}
    func beginOutput(itemID:String) {}
    func enqueue(_ pcm:Data) {onOutputLevel?(0.65)}
    func outputEnded() {onDrained?("preview")}
    func pauseOutput() {}
    func resumeOutput() {}
    func stopOutput() {}
    func stop() {}
}

/// Brief local speaker-loopback check. Only aggregate levels are retained.
@MainActor enum EchoDiagnostics {
    static func run(to url:URL,fixture:URL) async {
        let audio=NativeCallAudio();var levels:[Double]=[],baseline:[Double]=[],packets=0,phase=0,drained=false
        var result:[String:Any]=["networkUsed":false,"microphoneAudioSaved":false,"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? ""]
        defer{audio.stop();try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:url);NSApplication.shared.terminate(nil)}
        do {
            guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else{throw PartnerError.message("Existing microphone authorization is unavailable")}
            let file=try AVAudioFile(forReading:fixture)
            let input=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!;try file.read(into:input)
            let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:24000,channels:1,interleaved:true)!
            let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(Double(file.length)*24000/file.processingFormat.sampleRate)+128)!
            let converter=AVAudioConverter(from:file.processingFormat,to:format)!;var supplied=false;var error:NSError?
            converter.convert(to:output,error:&error){_,status in if supplied{status.pointee = .endOfStream;return nil};supplied=true;status.pointee = .haveData;return input}
            if let error{throw error}
            let pcm=Data(bytes:output.int16ChannelData![0],count:Int(output.frameLength)*2)
            audio.onMicrophone={packet in packets+=1;let rms=AudioMeter.level(packet)/5;if phase==0 {baseline.append(rms)}else{levels.append(rms)}}
            audio.onDrained={_ in drained=true}
            try audio.start()
            try await Task.sleep(nanoseconds:800_000_000)
            phase=1;audio.beginOutput(itemID:"synthetic-echo-probe");audio.enqueue(pcm);audio.outputEnded()
            let deadline=Date().addingTimeInterval(Double(pcm.count)/48000+4)
            while !drained && Date()<deadline {try await Task.sleep(nanoseconds:50_000_000)}
            try await Task.sleep(nanoseconds:600_000_000)
            result["success"]=drained && packets>0
            result["packets"]=packets;result["playbackDrained"]=drained;result["baselineRMS"]=baseline.reduce(0,+)/Double(max(1,baseline.count));result["playbackInputRMS"]=levels.reduce(0,+)/Double(max(1,levels.count));result["peakInputRMS"]=levels.max() ?? 0;result["generatedOutputRMS"]=AudioMeter.level(pcm)/5;result["formats"]=audio.diagnostics
        }catch{result["success"]=false;result["error"]=error.localizedDescription}
    }
}

/// Checks the installed bundle's offline worker without opening or playing audio.
@MainActor enum TeacherVoiceDiagnostics {
    static func run(to url:URL) async {
        var result:[String:Any]=["version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "","microphoneOpened":false,"networkUsed":false,"audioPlayed":false]
        defer{try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:url);NSApplication.shared.terminate(nil)}
        do {
            guard let teacher=TeacherSpeechClient.discover() else{throw PartnerError.message("The installed Mandarin runtime was not found")}
            let before=Date();try await teacher.prepare();result["loadSeconds"]=Date().timeIntervalSince(before)
            let start=Date();var pcm=Data(),chunks=0,first:Double?
            try await teacher.speak("你好呀，我是莉莉。你可以慢慢说，我会认真听。",speaker:"Serena"){bytes in
                if first==nil{first=Date().timeIntervalSince(start)};pcm.append(bytes);chunks+=1
            }
            let audio=try AVAudioPlayer(data:RealtimeNarrator.wave(pcm))
            result["success"]=audio.duration>2 && chunks>1
            result["firstChunkSeconds"]=first;result["audioSeconds"]=audio.duration;result["chunks"]=chunks
        }catch{result["success"]=false;result["error"]=error.localizedDescription}
    }
}
