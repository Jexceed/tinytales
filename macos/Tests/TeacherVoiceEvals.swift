import Foundation
import AVFoundation

@MainActor func teacherVoiceLive() async {
    do {
        let resources=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("macos/Resources")
        guard let teacher=TeacherSpeechClient.discover(resources:resources),let key=Credentials.load() else{throw PartnerError.message("Missing teacher runtime or saved connection")}
        let directory=URL(fileURLWithPath:"artifacts/teacher-voice");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let client=OpenAIClient(key:key),start=Date();try await teacher.prepare();let load=Date().timeIntervalSince(start)
        var samples:[[String:Any]]=[]
        for speaker in ["Serena","Vivian"] {
            let started=Date();var pcm=Data(),first:Double?,chunks=0
            try await teacher.speak(VoiceStyle.sample,speaker:speaker){bytes in
                if first==nil {first=Date().timeIntervalSince(started)}
                pcm.append(bytes);chunks+=1
            }
            let elapsed=Date().timeIntervalSince(started),wave=RealtimeNarrator.wave(pcm)
            let transcript=try await client.transcribe(wave)
            func canonical(_ text:String)->String {RealtimeNarrator.normalized(text).replacingOccurrences(of:"丽丽",with:"莉莉").replacingOccurrences(of:"莉丽",with:"莉莉")}
            let match=canonical(transcript)==canonical(VoiceStyle.sample)
            try wave.write(to:directory.appendingPathComponent("runtime-\(speaker.lowercased()).wav"))
            let report:[String:Any]=["speaker":speaker,"text":VoiceStyle.sample,"transcript":transcript,"spokenWordsMatch":match,"firstChunkSeconds":first ?? -1,"generationSeconds":elapsed,"audioSeconds":Double(pcm.count)/48000,"chunks":chunks]
            samples.append(report);print("Teacher \(speaker): \(chunks) chunks, first \(first ?? -1)s, transcript: \(transcript)")
        }
        var cancelChunks=0
        let pending=Task {try await teacher.speak(String(repeating:"小兔子抱着红苹果，走到奶奶家的门前。",count:8),speaker:"Serena"){_ in cancelChunks+=1}}
        let deadline=Date().addingTimeInterval(30)
        while cancelChunks==0 && Date()<deadline {try await Task.sleep(nanoseconds:20_000_000)}
        guard cancelChunks>0 else{pending.cancel();throw PartnerError.message("No first chunk for interruption test")}
        pending.cancel();var cancelled=false
        do {try await pending.value}catch is CancellationError {cancelled=true}
        let afterCancel=cancelChunks;try await Task.sleep(nanoseconds:800_000_000)
        var restarted=Data()
        try await teacher.speak("先停一下，听你说。",speaker:"Serena"){restarted.append($0)}
        let restartTranscript=try await client.transcribe(RealtimeNarrator.wave(restarted))
        let success=samples.allSatisfy{$0["spokenWordsMatch"] as? Bool==true} && cancelled && cancelChunks==afterCancel && !restarted.isEmpty
        let report:[String:Any]=["success":success,"syntheticOnly":true,"microphoneOpened":false,"workerOffline":true,"loadSeconds":load,"samples":samples,"cancellationReturned":cancelled,"lateChunksAfterCancellation":cancelChunks-afterCancel,"nextUtteranceTranscript":restartTranscript]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("native-worker-check.json"))
        print("Teacher native worker: \(success), cancelled: \(cancelled), late chunks: \(cancelChunks-afterCancel)")
        if !success{exit(1)}
    }catch{print("Teacher voice check failed: \(error.localizedDescription)");exit(1)}
}
