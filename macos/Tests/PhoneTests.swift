import Foundation
import AVFoundation
import AppKit

@MainActor final class TestWire: RealtimeWire {
    var onEvent: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    var sent: [[String: Any]] = []
    var closed = false
    var connections = 0
    var delayToolOutput = false
    var delayedTypes=Set<String>()
    var audioSends=0,maxAudioSends=0
    var deliveredAudio:[Data]=[]
    func connect() { closed = false; connections += 1 }
    func send(_ event: [String: Any]) async throws {
        sent.append(event)
        let type=event["type"] as? String ?? ""
        if type == "input_audio_buffer.append" {audioSends+=1;maxAudioSends=max(maxAudioSends,audioSends)}
        defer{if type == "input_audio_buffer.append" {audioSends-=1}}
        if delayedTypes.contains(type) {try await Task.sleep(nanoseconds:70_000_000)}
        if delayToolOutput, (event["item"] as? [String: Any])?["type"] as? String == "function_call_output" { try await Task.sleep(nanoseconds: 70_000_000) }
        if type == "input_audio_buffer.append",let encoded=event["audio"] as? String,let bytes=Data(base64Encoded:encoded) {deliveredAudio.append(bytes)}
    }
    func close() { closed = true }
    func emit(_ event: [String: Any]) { onEvent?(event) }
    func finishInput(_ id:String,_ text:String) async {
        emit(["type":"input_audio_buffer.speech_stopped","item_id":id]);await settle()
        emit(["type":"input_audio_buffer.committed","item_id":id]);await settle()
        emit(["type":"conversation.item.input_audio_transcription.completed","item_id":id,"transcript":text]);await settle()
    }
}
@MainActor final class SilentCallAudio: CallAudio {
    var onMicrophone: ((Data) -> Void)?
    var onDrained: ((String) -> Void)?
    var onInputLevel: ((Double) -> Void)?
    var onOutputLevel: ((Double) -> Void)?
    var muted = false
    var simulatePlayback=false
    var manualDrain=false
    var playbackID:String {outputItem}
    func drainOutput() {if !paused{onDrained?(outputItem)}}
    private var playbackStart=Date()
    private var outputItem=""
    private var outputFrames=0
    var paused=false
    var pauses=0,resumes=0
    private var pausedAt:Date?
    private var ended=false
    private var drain:Task<Void,Never>?
    var playedMilliseconds:Int {simulatePlayback ? min(outputFrames*1000/24000,Int((pausedAt ?? Date()).timeIntervalSince(playbackStart)*1000)) : 1200}
    var starts = 0, stops = 0, outputStops = 0
    var received = Data()
    var startError: Error?
    func start() throws { starts += 1; if let startError { throw startError } }
    func beginOutput(itemID: String) {if outputItem != itemID {drain?.cancel();outputItem=itemID;outputFrames=0;playbackStart=Date();paused=false;pausedAt=nil;ended=false}}
    func enqueue(_ pcm: Data) {received.append(pcm);outputFrames+=pcm.count/2}
    func outputEnded() {
        ended=true
        if manualDrain || paused{return}
        guard simulatePlayback else{onDrained?(outputItem);return}
        let item=outputItem
        let remaining=max(0,Double(outputFrames)/24000-Date().timeIntervalSince(playbackStart))
        drain?.cancel();drain=Task {try? await Task.sleep(nanoseconds:UInt64(remaining*1e9));if !Task.isCancelled {self.onDrained?(item)}}
    }
    func pauseOutput() {guard !paused else{return};pauses+=1;paused=true;pausedAt=Date();drain?.cancel();drain=nil}
    func resumeOutput() {guard paused else{return};resumes+=1;paused=false;if let pausedAt{playbackStart=playbackStart.addingTimeInterval(Date().timeIntervalSince(pausedAt))};pausedAt=nil;if ended{outputEnded()}}
    func stopOutput() { outputStops += 1;drain?.cancel();drain=nil;outputItem="";outputFrames=0;paused=false;pausedAt=nil;ended=false }
    func stop() { stops += 1;drain?.cancel();drain=nil;outputItem="";outputFrames=0;paused=false;pausedAt=nil;ended=false }
}
@MainActor final class ObservedWire: RealtimeWire {
    var onEvent: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    var sentTypes: [String] = []
    var observe: (([String:Any])->Void)?
    let wire: OpenAIRealtimeWire
    init(key: String) { wire = OpenAIRealtimeWire(key: key,model:"gpt-realtime-2.1"); wire.onEvent = { [weak self] in self?.observe?($0);self?.onEvent?($0) }; wire.onError = { [weak self] in self?.onError?($0) } }
    func connect() { wire.connect() }
    func send(_ event: [String: Any]) async throws { sentTypes.append(event["type"] as? String ?? ""); try await wire.send(event) }
    func close() { wire.close() }
}
func require(_ value: @autoclosure () throws -> Bool, _ reason: String) throws { if try !value() { throw PartnerError.message("TEST: \(reason)") } }
@MainActor func settle() async { for _ in 0..<15 { await Task.yield() } }
@MainActor func phoneFixture() throws -> LocalStore {
    let store=try LocalStore(url:FileManager.default.temporaryDirectory.appendingPathComponent("tinytales-phone-\(UUID().uuidString)/test.sqlite"))
    var settings=PartnerSettings();settings.voiceStyle="shimmer";try store.setSettings(settings);return store
}
@MainActor func waitFor(_ condition: () -> Bool, seconds: Double = 35) async throws {
    let until = Date().addingTimeInterval(seconds)
    while !condition() { if Date() >= until { throw PartnerError.message("等待实时语音返回超时。") }; try await Task.sleep(nanoseconds: 50_000_000) }
}
func wav(_ pcm: Data) -> Data {
    var data = Data()
    func string(_ s: String) { data.append(Data(s.utf8)) }
    func u16(_ v: UInt16) { var n=v.littleEndian; withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
    func u32(_ v: UInt32) { var n=v.littleEndian; withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
    string("RIFF"); u32(UInt32(pcm.count+36)); string("WAVEfmt "); u32(16); u16(1); u16(1); u32(24000); u32(48000); u16(2); u16(16); string("data"); u32(UInt32(pcm.count)); data.append(pcm); return data
}
@main struct PhoneTests {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--artwork-live") {await artworkPhoneLive();return}
        if CommandLine.arguments.contains("--voice-intent-live") {await voiceIntentLive();return}
        if CommandLine.arguments.contains("--duplex-live") || CommandLine.arguments.contains("--turns-live") {await duplexLive();return}
        if CommandLine.arguments.contains("--voice-eval") {await voiceRecognitionEvaluation();return}
        if CommandLine.arguments.contains("--recognition-live") {await recognitionLive();return}
        if CommandLine.arguments.contains("--content-live") {await contentLive();return}
        if CommandLine.arguments.contains("--live") { await live(); return }
        var passed = 0
        func ready(microphone: Bool = false) async throws -> (LocalStore, TestWire, SilentCallAudio, RealtimeCall) {
            let store = try phoneFixture(), wire = TestWire(), audio = SilentCallAudio()
            let call = RealtimeCall(store: store, wire: wire, audio: audio, permission: { true },inputCommitDelay:0)
            try await call.connect(history: [], microphone: microphone, greet: false)
            wire.emit(["type":"session.created"]); await settle()
            wire.emit(["type":"session.updated"]); await settle()
            return (store,wire,audio,call)
        }
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("restoring a voice conversation never reconnects or reopens the microphone", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio();var creations=0
                let app=AppModel(store:store,keyProvider:{"fixture"},callFactory:{store,_,voice,session in creations+=1;return RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},voice:voice,session:session,inputCommitDelay:0)})
                defer{app.cancel()}
                app.draft="这句话留到下次再问";let previous=app.selectedConversationID
                app.toggleCall();await settle();wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                wire.emit(["type":"input_audio_buffer.committed","item_id":"spoken-draft"]);await settle()
                wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"spoken-draft","transcript":"今天看到了小熊" ]);await settle()
                app.toggleCall();await settle();app.newConversation();app.selectConversation(previous);await settle()
                try require(app.entryOrigin == .voice && !app.showsOpeningOptions && !app.inCall,"restored voice conversation showed text openings or reconnected")
                try require(creations == 1 && audio.starts == 1 && wire.connections == 1 && app.draft == "这句话留到下次再问","selection opened audio/network or lost the voice draft")
            }),
            ("connecting and assistant greetings do not create a conversation before the user speaks", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio()
                let app=AppModel(store:store,keyProvider:{"fixture"},callFactory:{store,_,voice,session in RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},voice:voice,session:session,inputCommitDelay:0)})
                defer{app.cancel()}
                app.toggleCall();await settle();wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                wire.emit(["type":"response.created","response":["id":"greeting-r"]]);await settle()
                wire.emit(["type":"response.done","response":["id":"greeting-r","status":"completed","output":[["type":"message","id":"greeting-a","content":[["text":"我在呢，想说什么就说吧。"]]]]]]);await settle()
                try require(app.conversations.isEmpty && !app.isConversationStarted && !app.showsOpeningOptions,"connecting or greeting created a phantom conversation")
                wire.emit(["type":"input_audio_buffer.committed","item_id":"voice-first"]);await settle()
                let id=app.selectedConversationID
                try require(!app.isConversationStarted && app.conversations.isEmpty,"unrecognized input created a conversation")
                wire.emit(["type":"conversation.item.input_audio_transcription.completed","item_id":"voice-first","transcript":"今天看到了蝴蝶"]);await settle()
                try require(app.selectedConversationID == id && app.conversations.count == 1 && app.conversationTitle.contains("蝴蝶"),"transcription created a duplicate or failed to name the conversation")
            }),
            ("LP-002 actual call entry sends Lily's shared persona and keeps unsent drafts private", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio()
                let app=AppModel(store:store,keyProvider:{"fixture"},callFactory:{store,_,voice,session in RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},voice:voice,session:session)})
                defer{app.cancel()}
                app.draft="这句话还没有发送"
                app.toggleCall();await settle()
                try require(app.inCall && !app.showsOpeningOptions && app.entryOrigin == .voice,"calling first showed a text menu")
                wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                try require(wire.connections == 1 && audio.starts == 1,"mock call did not reach ready state")
                let session = wire.sent.first { $0["type"] as? String == "session.update" }?["session"] as? [String:Any]
                let instructions = session?["instructions"] as? String ?? ""
                try require(instructions.hasPrefix(LilyPersona.description), "phone entry did not send the shared persona")
                try require(!instructions.contains("栗栗") && !instructions.contains("旧称"), "phone persona included name migration notes")
                try require(instructions.contains(VoiceStyle.delivery), "phone persona replaced the established voice delivery")
                try require(!wire.sent.contains{$0["type"] as? String == "conversation.item.create"},"unsent draft was submitted to the call")
                app.toggleCall();await settle()
                try require(!app.inCall && !app.showsOpeningOptions && app.draft == "这句话还没有发送","hanging up reopened the first-entry menu or lost a draft")
            }),
            ("a failed voice connection keeps the voice entry free of opening choices", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio()
                let app=AppModel(store:store,keyProvider:{"fixture"},callFactory:{store,_,voice,session in RealtimeCall(store:store,wire:wire,audio:audio,permission:{false},voice:voice,session:session)})
                defer{app.cancel()}
                app.toggleCall();await settle()
                try require(!app.inCall && !app.showsOpeningOptions && app.entryOrigin == .voice,"failed voice entry fell back to a topic lobby")
                try require(audio.starts == 0 && wire.connections == 0,"denied call opened audio or a paid connection")
            }),
            ("narration uses youthful output-only realtime and verifies the spoken words", {
                let wire=TestWire()
                let reader=RealtimeNarrator(wire:wire)
                let task=Task{try await reader.speak("彩虹桥的小钟，响啦！",voice:"shimmer")}
                await settle();wire.emit(["type":"session.created"]);await settle()
                let session=wire.sent.first{$0["type"] as? String == "session.update"}!["session"] as! [String:Any]
                let audio=session["audio"] as! [String:Any]
                try require((audio["input"] as! [String:Any])["turn_detection"] is NSNull,"narrator enabled microphone VAD")
                try require((audio["output"] as! [String:Any])["voice"] as? String == "shimmer","narrator used mature voice")
                wire.emit(["type":"session.updated"]);await settle()
                wire.emit(["type":"response.output_audio.delta","delta":Data(repeating:0,count:1000).base64EncodedString()]);await settle()
                wire.emit(["type":"response.output_audio_transcript.done","transcript":"彩虹桥的小钟响啦。"]);await settle()
                wire.emit(["type":"response.done","response":["status":"completed"]]);await settle()
                let data=try await task.value
                try require(data.count == 1044 && wire.closed,"narrator failed to finish and close")
                try require(!wire.sent.contains{$0["type"] as? String == "input_audio_buffer.append"},"narrator sent microphone input")
            }),
            ("narration rejects changed words and cancellation closes its socket", {
                let wire=TestWire(),reader=RealtimeNarrator(wire:wire)
                let task=Task{try await reader.speak("彩虹桥的小钟响啦。",voice:"shimmer")}
                await settle();wire.emit(["type":"response.output_audio.delta","delta":Data(repeating:0,count:1000).base64EncodedString()]);await settle()
                wire.emit(["type":"response.output_audio_transcript.done","transcript":"下雨的小兔撑着伞。"]);await settle()
                wire.emit(["type":"response.done","response":["status":"completed"]]);await settle()
                do{_=try await task.value;throw PartnerError.message("TEST: altered narration accepted")}catch{try require(!error.localizedDescription.contains("TEST:"),"narrator accepted wrong words")}
                try require(wire.closed,"failed narration left connection open")
                let other=TestWire(),cancelReader=RealtimeNarrator(wire:other)
                let cancelled=Task{try await cancelReader.speak("你好",voice:"shimmer")};await settle();cancelled.cancel();await settle()
                do{_=try await cancelled.value;throw PartnerError.message("TEST: cancelled narration accepted")}catch{try require(error is CancellationError,"cancellation not surfaced")}
                try require(other.closed,"cancelled socket left open")
            }),
            ("AI-002 phone drawing uses actual recent dialogue without a saved narrative", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio(),session=StorySession()
                let image=NSImage(size:NSSize(width:16,height:16));image.lockFocus();NSColor.orange.setFill();NSRect(x:0,y:0,width:16,height:16).fill();image.unlockFocus()
                let png=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
                var captured:IllustrationRequest?,art:StoryArtwork?,published=0
                let call=RealtimeCall(store:store,wire:wire,audio:audio,session:session,illustrator:{request in
                    captured=request
                    return GeneratedArtwork(data:png,caption:"红色小火车走过小桥。",source:Story(title:"小火车",summary:"红色小火车走过小桥。"))
                },inputCommitDelay:0)
                call.onArtwork={_,value in art=value};call.onAssistantText={_,_,_,_,_ in published+=1}
                defer{call.hangUp();if let art{ArtworkArchive.remove(art)}}
                try await call.connect(history:[],microphone:false,greet:false)
                wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                try await call.sendText("会唱歌的小火车")
                wire.emit(["type":"response.created","response":["id":"train-r"]]);await settle()
                wire.emit(["type":"response.done","response":["id":"train-r","status":"completed","output":[["type":"message","id":"train-a","content":[["text":"小火车唱着歌过桥，水像镜子一样。"]]]]]]);await settle()
                try require(session.current == nil,"fixture unexpectedly had a saved story")
                wire.emit(["type":"input_audio_buffer.speech_started","item_id":"draw-input"]);await settle()
                await wire.finishInput("draw-input","我说你画图吧，还是我要看一张图。")
                let response=wire.sent.last?["response"] as? [String:Any]
                try require((response?["tool_choice"] as? [String:String])?["name"] == "illustrate_story","drawing tool not required")
                wire.emit(["type":"response.created","response":["id":"draw-r"]]);await settle()
                wire.emit(["type":"response.done","response":["id":"draw-r","status":"completed","output":[["type":"function_call","name":"illustrate_story","call_id":"draw-t","arguments":"{}"]]]]);await settle()
                try require(captured?.dialogue.contains{$0["text"]?.contains("水像镜子") == true} == true,"lost conversational source")
                try require(art != nil && published == 2,"image waited for an unnecessary second model answer")
                try require(try store.stories().isEmpty,"drawing invented an archive")
            }),
            ("AI-004 AI-007 slow phone artwork shows progress keeps capture active and cancels on hangup", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio()
                var started=false,cancelled=false,published=false
                let call=RealtimeCall(store:store,wire:wire,audio:audio,illustrator:{request in
                    request.progress?("莉莉在画画…");started=true
                    do {try await Task.sleep(nanoseconds:2_000_000_000)} catch {cancelled=true;throw error}
                    throw PartnerError.message("must be cancelled")
                })
                call.onArtwork={_,_ in published=true};defer{call.hangUp()}
                try await call.connect(history:[],microphone:false,greet:false)
                wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                try await call.sendText("画一辆小火车")
                wire.emit(["type":"response.created","response":["id":"slow-r"]]);await settle()
                wire.emit(["type":"response.done","response":["id":"slow-r","status":"completed","output":[["type":"function_call","name":"illustrate_story","call_id":"slow-t","arguments":"{}"]]]]);await settle()
                try require(started && !call.artworkStatus.isEmpty,"missing drawing progress")
                audio.onMicrophone?(Data(repeating:1,count:1920));await settle()
                try require(!wire.deliveredAudio.isEmpty,"generation blocked microphone upload")
                call.hangUp();await settle()
                try require(cancelled && !published && call.artworkStatus.isEmpty,"hangup left a render running or published late")
            }),
            ("phone illustration returns the picture tied to the current story", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio(),session=StorySession()
                let story=Story(title:"彩虹小钟",summary:"彩虹桥尽头的小钟发着光。")
                session.current=story;try store.saveStory(story)
                let image=NSImage(size:NSSize(width:16,height:16));image.lockFocus();NSColor.yellow.setFill();NSRect(x:0,y:0,width:16,height:16).fill();image.unlockFocus()
                let png=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
                var source:Story?,art:StoryArtwork?
                let call=RealtimeCall(store:store,wire:wire,audio:audio,session:session,illustrator:{ input in source=input.story;return GeneratedArtwork(data:png,caption:"彩虹桥尽头的小钟正在发光。") })
                call.onArtwork={_,value in art=value}
                defer{call.hangUp();if let art{ArtworkArchive.remove(art)}}
                try await call.connect(history:[],microphone:false,greet:false)
                wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                try await call.sendText("把刚刚的故事画出来")
                wire.emit(["type":"response.created","response":["id":"art-r1"]]);await settle()
                wire.emit(["type":"response.done","response":["id":"art-r1","status":"completed","output":[["type":"function_call","name":"illustrate_story","call_id":"art-tool","arguments":"{}"]]]]);await settle()
                try require(source == story,"phone illustrator used the wrong narrative")
                wire.emit(["type":"response.created","response":["id":"art-r2"]]);await settle()
                wire.emit(["type":"response.done","response":["id":"art-r2","status":"completed","output":[["type":"message","id":"art-a","content":[["text":"彩虹桥尽头的小钟正在发光。"]]]]]]);await settle()
                try require(art?.storyID == story.id && art?.storyText == story.summary,"phone did not attach grounded picture")
                try require(session.current == story,"image commentary changed the stored narrative")
            }),
            ("phone narration shares the accepted story with typed dialogue", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio(),session=StorySession()
                let initial=Story(title:"彩虹桥的小钟",summary:"彩虹桥的尽头有一只发光的小钟。")
                session.current=initial;try store.saveStory(initial)
                let call=RealtimeCall(store:store,wire:wire,audio:audio,session:session);defer{call.hangUp()}
                try await call.connect(history:[],microphone:false,greet:false)
                wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
                let config=try jsonString(wire.sent)
                try require(config.contains("发光的小钟"),"phone did not receive typed story")
                try await call.sendText("继续给我讲这个故事。")
                wire.emit(["type":"response.created","response":["id":"story-r"]]);await settle()
                wire.emit(["type":"response.done","response":["id":"story-r","status":"completed","output":[["type":"message","id":"story-a","content":[["text":"小钟叮当一响，桥上的云朵跳了起来。"]]]]]]);await settle()
                let typed=try PartnerTools(store:store,text:"画出这个故事",session:session)
                try require(typed.selectedNarrative?.summary.contains("发光的小钟") == true && typed.selectedNarrative?.summary.contains("云朵") == true,"phone did not update shared narrative")
                try require(typed.selectedStory == initial.id && (try store.stories()).count == 1,"phone lost story identity")
            }),
            ("transcript deltas arrive before completion and late interrupted deltas are ignored", {
                let (_,wire,_,call)=try await ready();defer{call.hangUp()}
                var drafts:[String]=[],final="",interrupted=""
                call.onAssistantDraft={_,text in drafts.append(text)};call.onAssistantText={_,text,_,_,_ in final=text};call.onAssistantInterrupted={interrupted=$0}
                try await call.sendText("你好")
                wire.emit(["type":"response.created","response":["id":"stream-r"]]);await settle()
                wire.emit(["type":"response.output_audio_transcript.delta","response_id":"stream-r","item_id":"stream-a","delta":"你好，"]);await settle()
                wire.emit(["type":"response.output_audio_transcript.delta","response_id":"stream-r","item_id":"stream-a","delta":"我是莉莉。"]);await settle()
                try require(drafts == ["你好，","你好，我是莉莉。"] && final.isEmpty,"transcript waited for final response")
                wire.emit(["type":"input_audio_buffer.speech_started","item_id":"new-spoken"]);await settle()
                wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"new-spoken","delta":"听我说，"]);await settle()
                await wire.finishInput("new-spoken","听我说")
                wire.emit(["type":"response.output_audio_transcript.delta","response_id":"stream-r","item_id":"stream-a","delta":"迟到的文字"]);await settle()
                try require(drafts.count == 2 && interrupted == "stream-a","interrupted transcript kept streaming")
            }),
            ("voice choice is applied to a new session", {
                let store=try phoneFixture(),wire=TestWire(),audio=SilentCallAudio()
                let call=RealtimeCall(store:store,wire:wire,audio:audio,permission:{true},voice:"coral");defer{call.hangUp()}
                try await call.connect(history:[],microphone:false,greet:false)
                wire.emit(["type":"session.created"]);await settle()
                let session=wire.sent.first{$0["type"] as? String == "session.update"}!["session"] as! [String:Any]
                let output=(session["audio"] as! [String:Any])["output"] as! [String:Any]
                try require(output["voice"] as? String == "coral","new friendly voice not configured")
            }),
            ("audio meter distinguishes silence and active speech without recording", {
                try require(AudioMeter.level(Data(repeating:0,count:100)) == 0,"silence appeared active")
                try require(AudioMeter.level(Data(repeating:64,count:100)) > 0.5,"speech level did not drive activity")
            }),
            ("existing microphone decisions never trigger a new permission request", {
                var requests = 0
                for state in [AVAuthorizationStatus.authorized, .denied, .restricted] {
                    let authorization = MicrophoneAuthorization(status: { state }, request: { requests += 1; return true })
                    let allowed = await authorization.obtain()
                    try require(allowed == (state == .authorized), "system permission state was ignored")
                }
                try require(requests == 0, "an existing permission decision prompted again")
            }),
            ("simultaneous first microphone requests share one system prompt", {
                var requests = 0
                let authorization = MicrophoneAuthorization(status: { .notDetermined }, request: { requests += 1; try? await Task.sleep(nanoseconds: 30_000_000); return true })
                async let first = authorization.obtain()
                async let second = authorization.obtain()
                let results = await (first, second)
                try require(results.0 && results.1 && requests == 1, "first-use permission was requested more than once")
            }),
            ("voice connection and replies continue beyond sixty cloud operations", {
                let store = try phoneFixture(), wire = TestWire(), audio = SilentCallAudio()
                for _ in 0..<65 { try store.recordCloudOperation() }
                let call = RealtimeCall(store: store, wire: wire, audio: audio); defer { call.hangUp() }
                var reply = ""; call.onAssistantText = { _, text, _, _, _ in reply = text }
                try await call.connect(history: [], microphone: false, greet: false)
                wire.emit(["type":"session.created"]); await settle(); wire.emit(["type":"session.updated"]); await settle()
                try await call.sendText("继续讲故事")
                wire.emit(["type":"response.created", "response":["id":"beyond-sixty"]]); await settle()
                wire.emit(["type":"response.done", "response":["id":"beyond-sixty", "status":"completed", "output":[["id":"answer", "type":"message", "content":[["transcript":"我们继续讲故事吧。"]]]]]]); await settle()
                try require(call.active && reply == "我们继续讲故事吧。", "daily count blocked voice reply")
                try require(try store.usage().operations == 67, "connection and reply were not counted")
            }),
            ("failed audio startup closes locally before any paid connection and can retry", {
                let store = try phoneFixture(), wire = TestWire(), audio = SilentCallAudio()
                audio.startError = PartnerError.message("audio-device-unavailable")
                let call = RealtimeCall(store: store, wire: wire, audio: audio, permission: { true }); defer { call.hangUp() }
                do { try await call.connect(history: [], greet: false); throw PartnerError.message("TEST: audio failure was ignored") }
                catch { try require(error.localizedDescription == "audio-device-unavailable", "startup error was lost") }
                try require(!call.active && wire.connections == 0 && wire.closed, "failed audio opened a remote session")
                try require(try store.usage().operations == 0, "failed local audio recorded a cloud operation")
                audio.startError = nil
                try await call.connect(history: [], greet: false)
                wire.emit(["type":"session.created"]); await settle(); wire.emit(["type":"session.updated"]); await settle()
                try require(call.state == .listening && audio.starts == 2 && wire.connections == 1, "retry did not start exactly one audio graph")
            }),
            ("permission denial leaves neither audio capture nor a pending call", {
                let store = try phoneFixture(), wire = TestWire(), audio = SilentCallAudio()
                let call = RealtimeCall(store: store, wire: wire, audio: audio, permission: { false })
                do { try await call.connect(history: []); throw PartnerError.message("TEST: permission denial ignored") }
                catch { try require(error.localizedDescription.contains("允许"), "wrong permission error") }
                try require(!call.active && audio.starts == 0 && wire.connections == 0, "denied call started resources")
            }),
            ("hanging up during permission cannot start a late microphone or connection", {
                let store = try phoneFixture(), wire = TestWire(), audio = SilentCallAudio()
                var permissionReply: CheckedContinuation<Bool, Never>?
                let call = RealtimeCall(store: store, wire: wire, audio: audio, permission: { await withCheckedContinuation { permissionReply = $0 } })
                let connecting = Task { try await call.connect(history: []) }
                await settle(); call.hangUp(); permissionReply?.resume(returning: true)
                do { try await connecting.value; throw PartnerError.message("TEST: ended call resumed") }
                catch { try require(error is CancellationError, "ended connection was not cancelled") }
                try require(!call.active && audio.starts == 0 && wire.connections == 0, "late permission started recording")
            }),
            ("microphone packets stay local until realtime is ready", {
                let store = try phoneFixture(), wire = TestWire(), audio = SilentCallAudio()
                let call = RealtimeCall(store: store, wire: wire, audio: audio, permission: { true }); defer { call.hangUp() }
                try await call.connect(history: [], greet: false)
                try require(audio.starts == 1, "local audio was not checked first")
                audio.onMicrophone?(Data(repeating:0,count:960)); await settle()
                try require(!wire.sent.contains { $0["type"] as? String == "input_audio_buffer.append" }, "connecting audio was uploaded")
                wire.emit(["type":"session.created"]); await settle(); wire.emit(["type":"session.updated"]); await settle()
                audio.onMicrophone?(Data(repeating:0,count:960)); await settle()
                try require(wire.sent.contains { $0["type"] as? String == "input_audio_buffer.append" }, "ready microphone did not send")
            }),
            ("one connection segments speech while the client controls interruptions", {
                let (_,wire,_,call) = try await ready(); defer { call.hangUp() }
                let session = wire.sent.first { $0["type"] as? String == "session.update" }!["session"] as! [String:Any]
                let input = (session["audio"] as! [String:Any])["input"] as! [String:Any]
                let vad = input["turn_detection"] as! [String:Any]
                try require(vad["type"] as? String == "semantic_vad" && vad["create_response"] as? Bool == false && vad["interrupt_response"] as? Bool == false, "speech is not segmented automatically with response gating")
                try require(call.state == .listening, "not listening after connection")
            }),
            ("microphone stays running across assistant turns", {
                let (_,wire,audio,call) = try await ready(microphone:true); defer { call.hangUp() }
                let stops=audio.stops
                try await call.sendText("讲个故事")
                wire.emit(["type":"response.created","response":["id":"r1"]]); await settle()
                wire.emit(["type":"response.output_audio.delta","response_id":"r1","item_id":"a1","delta":Data([0,0,1,0]).base64EncodedString()]); await settle()
                wire.emit(["type":"response.done","response":["id":"r1","status":"completed","output":[]]]); await settle()
                try require(audio.starts == 1 && audio.stops == stops, "microphone was stopped for every reply")
                try require(call.active && call.state == .listening, "next turn was not ready automatically")
            }),
            ("barge-in stops playback and truncates to actually heard audio", {
                let (_,wire,audio,call)=try await ready(); defer {call.hangUp()}
                try await call.sendText("讲个故事")
                wire.emit(["type":"response.created","response":["id":"r2"]]); await settle()
                wire.emit(["type":"response.output_audio.delta","response_id":"r2","item_id":"a2","delta":Data(repeating:0,count:96000).base64EncodedString()]); await settle()
                wire.emit(["type":"input_audio_buffer.speech_started","item_id":"barge-user"]); await settle()
                wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"barge-user","delta":"听我说，"]);await settle()
                await wire.finishInput("barge-user","听我说")
                let truncate=wire.sent.last { $0["type"] as? String == "conversation.item.truncate" }
                try require(truncate?["item_id"] as? String == "a2" && truncate?["audio_end_ms"] as? Int == 1200, "wrong interruption position")
                try require(audio.outputStops > 0 && call.state == .listening, "playback was not interrupted")
                let heard=audio.received.count
                wire.emit(["type":"response.output_audio.delta","response_id":"r2","item_id":"a2","delta":Data([0,0,1,0]).base64EncodedString()]);await settle()
                try require(audio.received.count == heard,"late interrupted audio restarted playback")
            }),
            ("mute suppresses microphone packets and can be reversed", {
                let (_,wire,audio,call)=try await ready(); defer {call.hangUp()}
                call.toggleMute(); audio.onMicrophone?(Data(repeating:1,count:960)); await settle()
                try require(!wire.sent.contains { $0["type"] as? String == "input_audio_buffer.append" }, "muted microphone still uploaded")
                call.toggleMute(); audio.onMicrophone?(Data(repeating:1,count:960)); await settle()
                try require(wire.sent.contains { $0["type"] as? String == "input_audio_buffer.append" }, "unmute did not resume")
            }),
            ("hangup stops capture and discards late output", {
                let (_,wire,audio,call)=try await ready();call.hangUp();let bytes=audio.received.count
                wire.emit(["type":"response.output_audio.delta","item_id":"late","delta":Data([0,0]).base64EncodedString()]); await settle()
                try require(!call.active && wire.closed && audio.received.count == bytes, "late audio survived hangup")
            }),
            ("voice identity answer is delivered instead of an adult handoff", {
                let (_,wire,_,call)=try await ready(); defer {call.hangUp()}
                var reply="";call.onAssistantText={_,text,_,_,_ in reply=text}
                try await call.sendText("你叫什么名字")
                wire.emit(["type":"response.created","response":["id":"r3"]]); await settle()
                wire.emit(["type":"response.output_audio_transcript.done","response_id":"r3","item_id":"a3","transcript":"你好呀，我叫莉莉。"]); await settle()
                wire.emit(["type":"response.done","response":["id":"r3","status":"completed","output":[["id":"a3","type":"message","content":[]]]]]); await settle()
                try require(reply == "你好呀，我叫莉莉。", "assistant identity was blocked")
            }),
            ("tool writes are dropped when a call ends before the final reply", {
                let (store,wire,_,call)=try await ready(); defer {call.hangUp()}
                try await call.sendText("讲一个小故事")
                wire.emit(["type":"response.created","response":["id":"r4"]]); await settle()
                let arguments=try jsonString(["id":NSNull(),"title":"星星门","summary":"小兔子找到星星门。","fictional":true])
                wire.emit(["type":"response.done","response":["id":"r4","status":"completed","output":[["type":"function_call","name":"save_story","call_id":"c4","arguments":arguments]]]]); await settle()
                call.hangUp();try require(try store.stories().isEmpty,"unfinished call committed story")
            }),
            ("interrupted tool results cannot create a late response in a new turn", {
                let (_,wire,_,call)=try await ready(); defer {call.hangUp()};wire.delayToolOutput=true
                try await call.sendText("你记得我喜欢什么吗")
                let before=wire.sent.filter{$0["type"] as? String == "response.create"}.count
                wire.emit(["type":"response.created","response":["id":"old-response"]]);await settle()
                wire.emit(["type":"response.done","response":["id":"old-response","status":"completed","output":[["type":"function_call","name":"recall_memories","call_id":"old-tool","arguments":"{}"]]]]);await settle()
                wire.emit(["type":"input_audio_buffer.speech_started","item_id":"new-user"]);await settle()
                wire.emit(["type":"conversation.item.input_audio_transcription.delta","item_id":"new-user","delta":"听我说，"]);await settle()
                await wire.finishInput("new-user","听我说")
                try await Task.sleep(nanoseconds:100_000_000)
                try require(wire.sent.filter{$0["type"] as? String == "response.create"}.count == before,"old tool resumed in the new turn")
            })
        ] + voiceTurnTestCases() + teacherSpeechTestCases() + naturalTurnTestCases()
        for (name,test) in cases { do {try await test();passed += 1;print("PASS phone \(name)")}catch{print("FAIL phone \(name): \(error.localizedDescription)")} }
        print("Phone tests: \(passed)/\(cases.count) passed");if passed != cases.count {exit(1)}
    }
    @MainActor static func recognitionLive() async {
        guard let key=Credentials.load() else{exit(1)}
        let args=CommandLine.arguments
        let label=args.firstIndex(of:"--label").flatMap{args.count>$0+1 ? args[$0+1] : nil} ?? "probe"
        var events:[[String:Any]]=[],users:[String:String]=[:],replies:[String]=[]
        do {
            let store=try phoneFixture();defer{try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
            let wire=ObservedWire(key:key),audio=SilentCallAudio(),call=RealtimeCall(store:store,wire:wire,audio:audio)
            defer{call.hangUp()}
            let phrase="给我讲个故事。"
            let voiceURL=URL(fileURLWithPath:"artifacts/voice-story-request.wav")
            if !FileManager.default.fileExists(atPath:voiceURL.path) {try await OpenAIClient(key:key).speech(phrase,voice:"marin").write(to:voiceURL)}
            let file=try AVAudioFile(forReading:voiceURL)
            let input=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!;try file.read(into:input)
            let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:24000,channels:1,interleaved:true)!
            let converter=AVAudioConverter(from:file.processingFormat,to:format)!
            let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(Double(file.length)*24000/file.processingFormat.sampleRate)+128)!
            var delivered=false;var conversionError:NSError?
            converter.convert(to:output,error:&conversionError){_,state in if delivered {state.pointee = .endOfStream;return nil};delivered=true;state.pointee = .haveData;return input}
            if let conversionError{throw conversionError}
            let pcm=Data(bytes:output.int16ChannelData![0],count:Int(output.frameLength)*2)
            wire.observe={event in
                let type=event["type"] as? String ?? "";var record:[String:Any]=["type":type]
                for key in ["item_id","response_id","transcript","delta","audio_start_ms","audio_end_ms"] {
                    if key == "delta",type.contains("audio.delta") {continue}
                    if let value=event[key]{record[key]=value}
                }
                if let error=event["error"] as? [String:Any] {record["errorCode"]=error["code"] ?? "";record["errorType"]=error["type"] ?? "";record["errorParam"]=error["param"] ?? ""}
                if type == "session.updated",let session=event["session"] as? [String:Any] {record["audioConfig"]=session["audio"]}
                if !type.contains("output_audio.delta") {events.append(record)}
            }
            call.onUserText={id,text in users[id]=text}
            call.onAssistantText={_,text,_,_,_ in replies.append(text)}
            try await call.connect(history:[],microphone:false,greet:false)
            try await waitFor({call.state == .listening || !call.active},seconds:25)
            try require(call.active,"session did not open")
            for _ in 0..<15 {try await call.sendSyntheticAudio(Data(repeating:0,count:960));try await Task.sleep(nanoseconds:20_000_000)}
            for offset in stride(from:0,to:pcm.count,by:960) {try await call.sendSyntheticAudio(pcm.subdata(in:offset..<min(offset+960,pcm.count)));try await Task.sleep(nanoseconds:20_000_000)}
            for _ in 0..<150 {if !call.active{break};try await call.sendSyntheticAudio(Data(repeating:0,count:960));try await Task.sleep(nanoseconds:20_000_000)}
            try? await waitFor({!replies.isEmpty || !call.active},seconds:35)
            let repliesAtEnd=replies.count
            for _ in 0..<150 {if !call.active{break};try await call.sendSyntheticAudio(Data(repeating:0,count:960));try await Task.sleep(nanoseconds:20_000_000)}
            let normalized=users.values.map{RealtimeNarrator.normalized($0)}
            let success=normalized.contains(where:{$0.contains("给我讲个故事")}) && replies.count == repliesAtEnd && repliesAtEnd>=1
            let report:[String:Any]=["success":success,"syntheticOnly":true,"microphoneOpened":false,"input":phrase,"inputSeconds":Double(pcm.count)/48000,"users":users,"replies":replies,"responsesDuringFinalSilence":replies.count-repliesAtEnd,"notice":call.notice,"events":events]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"artifacts/voice-recognition-\(label).json"))
            print("Recognition probe: \(success), user transcripts: \(users.values.joined(separator:" | ")), replies: \(replies.count), errors: \(events.filter{($0["type"] as? String ?? "").contains("failed") || $0["errorCode"] != nil})")
            if !success {exit(1)}
        }catch{print("Recognition probe failed: \(error.localizedDescription)");exit(1)}
    }
    @MainActor static func contentLive() async {
        guard let key=Credentials.load() else{exit(1)}
        do {
            let store=try phoneFixture(),wire=ObservedWire(key:key),audio=SilentCallAudio(),session=StorySession()
            defer{try? FileManager.default.removeItem(at:store.url.deletingLastPathComponent())}
            let call=RealtimeCall(store:store,wire:wire,audio:audio,session:session);defer{call.hangUp()}
            var replies:[String]=[],transcript:[String]=[],deltas=0
            call.onAssistantDraft={_,_ in deltas+=1}
            call.onAssistantText={_,text,_,_,_ in replies.append(text)}
            try await call.connect(history:[],microphone:false,greet:false)
            try await waitFor({call.state == .listening || !call.active},seconds:25)
            let turns=["我们编一个小兔团团和乌龟慢慢去野餐的故事。慢慢背着蓝色包，带了苹果。", "慢慢不是乌龟，是小刺猬，蓝色包和苹果还在。请接着讲到它们到了河边。", "现在我想知道真的知识：月亮为什么会发光？不要编故事。", "先停下吧，我不想听了。"]
            for (index,text) in turns.enumerated() {
                transcript.append("孩子："+text);try await call.sendText(text)
                try await waitFor({replies.count>index || !call.active},seconds:55)
                try require(replies.count>index,"phone did not answer: \(call.notice)")
                transcript.append("莉莉："+replies[index]);print("Phone content \(index+1): \(replies[index])");fflush(stdout)
            }
            let state=session.current?.summary ?? ""
            try require(state.contains("刺猬") && !state.contains("乌龟"),"phone retained obsolete species")
            try require(state.contains("蓝色") && state.contains("苹果"),"phone lost established objects")
            try require(!state.contains("月亮"),"knowledge answer replaced the fictional story")
            try require(replies[2].contains("太阳") && (replies[2].contains("反射") || replies[2].contains("照")),"moon explanation inaccurate")
            try require(!replies.last!.contains("？") && replies.last!.count <= 25,"phone kept speaking after stop")
            try require(replies[0].count >= 80 && replies[1].count >= 80,"phone only echoed the premise")
            try require(deltas>8,"phone lost transcript streaming")
            let report:[String:Any]=["success":true,"syntheticOnly":true,"microphoneOpened":false,"transcript":transcript,"storyState":state,"archivedStories":try store.stories().count,"transcriptDeltas":deltas,"voice":"shimmer","model":"gpt-realtime-2.1"]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"artifacts/v08-phone-content-live.json"))
            print("PASS real phone story correction, retained objects, factual explanation, stop and streaming")
        }catch{print("Phone content failed: \(error.localizedDescription)");exit(1)}
    }
    @MainActor static func live() async {
        guard let key=Credentials.load() else {print("No saved connection is available.");exit(1)}
        var diagnostics: [String] = []
        do {
            let store=try phoneFixture(),wire=ObservedWire(key:key),audio=SilentCallAudio()
            let call=RealtimeCall(store:store,wire:wire,audio:audio);defer{call.hangUp()}
            var events:[String]=[],replies:[String]=[],records:[[String:Any]]=[],drafts=0
            call.onAssistantDraft={_,_ in drafts += 1}
            var firstAudio:Date?,started=Date()
            call.onProtocolEvent={type in events.append(type); diagnostics.append(type); if type.hasPrefix("protocol_error:") || type.hasPrefix("response_status:"){print(type)}}
            call.onAudio={_ in if firstAudio == nil {firstAudio=Date()}}
            call.onAssistantText={_,text,_,_,_ in replies.append(text);print("Realtime reply: \(text)")}
            try await call.connect(history:[],microphone:false,greet:false)
            try await waitFor({call.state == .listening || !call.notice.isEmpty},seconds:25)
            try require(call.active,"Realtime session did not open: \(call.notice)")
            for (index,text) in ["你好呀，你叫什么名字？","我们接着聊，你喜欢讲什么故事？"].enumerated(){
                started=Date();firstAudio=nil
                try await call.sendText(text)
                try await waitFor({replies.count > index || !call.active},seconds:40)
                try require(replies.count > index,"No voice reply: \(call.notice)")
                try require(!replies[index].contains("找大人") && !replies[index].contains("爸爸妈妈"),"ordinary call handed off")
                records.append(["input":text,"reply":replies[index],"firstAudioSeconds":firstAudio?.timeIntervalSince(started) ?? -1])
            }
            let createCount=wire.sentTypes.filter{$0 == "response.create"}.count
            let fixture=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("macos/Resources/TTS/reference.wav")
            let wave=try Data(contentsOf:fixture)
            // The bundled synthetic reference is PCM16 mono 24 kHz. Locate RIFF data rather than assuming a 44-byte header.
            guard let dataMarker=wave.range(of:Data("data".utf8)),dataMarker.lowerBound+8<wave.count else{throw PartnerError.message("WAV fixture has no data")}
            let pcm=wave.subdata(in:(dataMarker.lowerBound+8)..<wave.count)
            started=Date();firstAudio=nil
            for offset in stride(from:0,to:pcm.count,by:4800){try await call.sendSyntheticAudio(pcm.subdata(in:offset..<min(offset+4800,pcm.count)));try await Task.sleep(nanoseconds:100_000_000)}
            let speechInputEnded = Date()
            for _ in 0..<25{try await call.sendSyntheticAudio(Data(repeating:0,count:4800));try await Task.sleep(nanoseconds:100_000_000)}
            try await waitFor({replies.count >= 3 || !call.active},seconds:45)
            try require(replies.count >= 3,"VAD did not automatically answer: \(call.notice)")
            try require(events.contains("input_audio_buffer.speech_started") && events.contains("input_audio_buffer.speech_stopped"),"server VAD did not recognize speech")
            try require(!wire.sentTypes.contains("input_audio_buffer.commit"),"manual commit was required")
            records.append(["test":"synthetic audio automatic VAD","reply":replies.last!,"seconds":Date().timeIntervalSince(started),"firstAudioAfterSpeechEnd":firstAudio?.timeIntervalSince(speechInputEnded) ?? -1,"clientResponseCreatesBefore":createCount,"clientManualCommits":0])
            try require(drafts > 3,"real voice transcript was not streamed")
            try FileManager.default.createDirectory(atPath:"artifacts",withIntermediateDirectories:true)
            try wav(audio.received).write(to:URL(fileURLWithPath:"artifacts/v07-realtime-call-sample.wav"))
            let result:[String:Any] = ["success":true,"syntheticOnly":true,"microphoneOpened":false,"model":"gpt-realtime-2.1-mini","voice":"shimmer","results":records,"streamedTranscriptDeltas":drafts,"vadSpeechStarts":events.filter{$0 == "input_audio_buffer.speech_started"}.count,"vadSpeechStops":events.filter{$0 == "input_audio_buffer.speech_stopped"}.count]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"artifacts/v07-phone-live.json"))
            print("PASS native realtime continuous conversation and automatic VAD; no physical microphone used.")
        } catch { print("Phone live check failed: \(error.localizedDescription)"); print("Recent events: \(diagnostics.suffix(25).joined(separator: ", "))"); exit(1) }
    }
}
