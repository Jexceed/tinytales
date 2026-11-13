import Foundation

@MainActor func artworkPhoneLive() async {
    let directory=URL(fileURLWithPath:"artifacts/v014-artwork",isDirectory:true)
    var report:[String:Any]=["syntheticOnly":true,"microphoneOpened":false]
    do {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        guard let key=Credentials.load(),let teacher=TeacherSpeechClient.discover(resources:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("macos/Resources")) else {throw PartnerError.message("Saved connection or teacher runtime unavailable")}
        let store=try phoneFixture();defer{try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
        let client=OpenAIClient(key:key),wire=ObservedWire(key:key),audio=SilentCallAudio(),session=StorySession()
        audio.simulatePlayback=true
        var toolRequests=0,art:StoryArtwork?,replies:[String]=[]
        let began=Date()
        let call=RealtimeCall(store:store,wire:wire,audio:audio,voice:"teacher",session:session,illustrator:{request in toolRequests+=1;return try await client.illustrate(request)},teacherSpeech:teacher)
        call.onArtwork={_,value in art=value};call.onAssistantText={_,text,_,_,_ in replies.append(text)}
        defer{call.hangUp();if let art{ArtworkArchive.remove(art)}}
        try await call.connect(history:[["role":"user","content":"讲一辆红色小火车唱歌过桥的故事"],["role":"assistant","content":"红色小火车唱着歌经过森林中的小石桥，清晨的阳光照在车厢上，桥下的水像镜子。"]],microphone:false,greet:false)
        while call.state == .connecting && Date().timeIntervalSince(began)<25 {try await Task.sleep(nanoseconds:100_000_000)}
        guard call.active else{throw PartnerError.message(call.notice)}
        try await call.sendText("我说你画图吧，还是我要看一张图。")
        while art == nil && call.active && Date().timeIntervalSince(began)<120 {try await Task.sleep(nanoseconds:100_000_000)}
        guard let art else{throw PartnerError.message(call.notice.isEmpty ? "No actual phone artwork was delivered" : call.notice)}
        report["imageSeconds"]=Date().timeIntervalSince(began)
        try Data(contentsOf:art.url).write(to:directory.appendingPathComponent("phone-result."+art.fileExtension))
        let voiceWait=Date()
        while audio.received.isEmpty && call.active && Date().timeIntervalSince(voiceWait)<25 {try await Task.sleep(nanoseconds:100_000_000)}
        report.merge(["success":!audio.received.isEmpty,"toolRequests":toolRequests,"replies":replies,"source":art.storyText,"imageFile":"phone-result."+art.fileExtension,"voiceBytes":audio.received.count,"voiceStyle":"teacher","savedStoryRequired":false,"storedStories":try store.stories().count,"diagnostics":client.artworkDiagnostics]){_,new in new}
        print("Phone artwork: \(report["success"] as? Bool == true ? "PASS" : "FAIL"), \(toolRequests) generation invocation(s)")
    } catch {report["success"]=false;report["error"]=error.localizedDescription;print("Phone artwork failed: \(error.localizedDescription)")}
    try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("phone-live.json"))
    if report["success"] as? Bool != true {exit(1)}
}
