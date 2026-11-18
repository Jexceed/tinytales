import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindow: (() -> Void)?
    static weak var launchModel: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let index=args.firstIndex(of:"--verify-teacher-voice"),args.count>index+1 {
            Task {await TeacherVoiceDiagnostics.run(to:URL(fileURLWithPath:args[index+1]))};return
        }
        if let index=args.firstIndex(of:"--verify-echo"),args.count>index+2 {
            Task {await EchoDiagnostics.run(to:URL(fileURLWithPath:args[index+1]),fixture:URL(fileURLWithPath:args[index+2]))}
            return
        }
        if let index = args.firstIndex(of: "--verify-local-tts"), args.count > index + 1 {
            Task { await LocalVoiceDiagnostics.run(to: URL(fileURLWithPath: args[index+1])) }
            return
        }
        if let index = args.firstIndex(of: "--verify-audio"), args.count > index + 1 {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            Task { await AudioDiagnostics.run(to: URL(fileURLWithPath: args[index+1])) }
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "TinyTales", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApplication.shared.applicationIconImage = icon }
        DesktopPetController.shared.registerOpener { Self.openMainWindow?() }
        if let model = Self.launchModel { DesktopPetController.shared.attach(model) }
        let forcePetOnly = args.contains("--sample-pet-only-launch")
        let shouldOpenMain = !forcePetOnly && ((args.contains("--verify-launch") || args.contains("--inspect-launch")) || (Self.launchModel?.shouldOpenMainWindowOnLaunch ?? true))
        if shouldOpenMain {
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Self.openMainWindow?() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                for window in NSApp.windows where window.title == "小小故事屋" { window.orderOut(nil) }
                if let model = Self.launchModel { LaunchVerification.run(model) }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { Self.openMainWindow?(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { DesktopPetController.shared.shutdown() }
}
@MainActor final class MainWindowController {
    static let shared = MainWindowController()
    private var window: NSWindow?
    func show(_ model: AppModel) {
        if let existing = NSApp.windows.first(where: { $0.title == "小小故事屋" }) {
            existing.deminiaturize(nil); existing.makeKeyAndOrderFront(nil); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "小小故事屋"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1000, height: 600)
        window.contentView = NSHostingView(rootView: MainView(model: model).preferredColorScheme(.light).tint(Color.sage).onAppear {
            DesktopPetController.shared.attach(model); LaunchVerification.run(model)
        })
        window.center(); self.window = window; window.makeKeyAndOrderFront(nil)
    }
}
@main struct TinyTalesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        do {
            let args = CommandLine.arguments
            if args.contains("--persist-connection-stdin") {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard data.count <= 1024, let key = String(data: data, encoding: .utf8) else { throw PartnerError.message("连接配置格式不正确。") }
                try Credentials.save(key)
                print("{\"persistentConnection\":\(Credentials.hasPersistentKey())}")
                exit(Credentials.hasPersistentKey() ? 0 : 1)
            }
            if args.contains("--connection-status") {
                print("{\"persistentConnection\":\(Credentials.hasPersistentKey()),\"connectionAvailable\":\(Credentials.load() != nil)}")
                exit(0)
            }
            let testMode = args.contains("--verify-launch") || args.contains("--verify-audio") || args.contains("--verify-local-tts") || args.contains("--verify-echo") || args.contains("--verify-teacher-voice")
            let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("tinytales-view-\(UUID().uuidString)")
            if testMode {ArtworkArchive.directory=fixtureDirectory.appendingPathComponent("artwork",isDirectory:true)}
            let store = try LocalStore(url: testMode ? fixtureDirectory.appendingPathComponent("view.sqlite") : nil)
            let previewCall:((LocalStore,String,String,StorySession)->RealtimeCall)?
            if testMode && args.contains("--sample-voice") {
                let sample=args.contains("--sample-drawing") ? "drawing" : args.contains("--sample-duplex") ? "duplex" : args.contains("--sample-voice-correction") ? "correction" : args.contains("--sample-voice-partial") ? "partial" : args.contains("--sample-voice-retry") ? "retry" : ""
                previewCall={store,_,voice,session in RealtimeCall(store:store,wire:ConversationPreviewWire(sample:sample),audio:ConversationPreviewAudio(),permission:{true},voice:"shimmer",session:session,illustrator:sample == "drawing" ? {request in request.progress?("莉莉在画画…");try await Task.sleep(nanoseconds:30_000_000_000);throw CancellationError()} : nil,inputCommitDelay:sample=="correction" ? 0 : VoiceTurns.continuationDelay)}
            } else {previewCall=nil}
            let backgroundPreview=testMode && args.contains("--sample-background-conversations") ? BackgroundConversationPreview(quick:args.contains("--sample-background-return")) : nil
            let model = testMode ? AppModel(store: store, keyProvider: { "ui-fixture-no-network" },modelFactory:{key in
                if let backgroundPreview {return backgroundPreview};return OpenAIClient(key:key)
            },callFactory:previewCall,replySpeaker:{_ in}) : AppModel(store: store)
            if testMode { model.newConversation() }
            if let _=backgroundPreview {
                var settings=try store.settings();settings.speaks=false;try store.setSettings(settings);model.refresh()
                let archive=Story(id:"background-preview-archive",title:"花园里的小猫",summary:"小猫在花园里发现一朵紫色的小花。")
                try store.saveStory(archive);model.refresh()
                model.send(OpeningPrompt.picture.text);let pictureConversation=model.selectedConversationID
                model.newConversation();model.send("月亮为什么发光")
                model.selectConversation("archive:"+archive.id)
                if args.contains("--sample-background-return") {
                    Task {try? await Task.sleep(nanoseconds:300_000_000);model.selectConversation(pictureConversation)}
                }
            }
            if testMode,args.contains("--sample-delete-stories") {
                for story in [Story(id:"delete-ui-a",title:"删除验证·同名",summary:"第一本：小兔在花园看花。",updatedAt:"2020-01-03T00:00:00Z"),Story(id:"delete-ui-b",title:"删除验证·同名",summary:"第二本：小熊在河边看鱼。",updatedAt:"2020-01-02T00:00:00Z"),Story(id:"delete-ui-c",title:"删除验证·保留",summary:"小猫在树下读书。",updatedAt:"2020-01-01T00:00:00Z")] {try store.saveStory(story)}
                model.refresh();model.selectConversation("archive:delete-ui-b")
            }
            if testMode,args.contains("--sample-sidebar-stories") {
                try store.saveStory(Story(title:"彩虹桥的小钟",summary:"彩虹桥边的小钟轻轻响起，小兔坐到软云椅上休息。"))
                try store.saveStory(Story(title:"小熊送苹果",summary:"小熊带着三个苹果和蓝色伞，走过小桥去看奶奶。"))
                model.refresh()
            }
            if testMode,args.contains("--sample-conversation-labels") {
                for story in [
                    Story(id:"label-ui-a",title:"新的小冒险",summary:"小兔坐着月亮船去找星星。",updatedAt:"2026-11-17T06:32:00Z"),
                    Story(id:"label-ui-b",title:"新的小冒险",summary:"小熊带着蓝色雨伞去送苹果。",updatedAt:"2026-11-16T08:05:00Z"),
                    Story(id:"label-ui-c",title:"新的小冒险",summary:"红色小火车唱着歌经过森林石桥。",updatedAt:"2026-11-15T07:20:00.125Z"),
                    Story(id:"label-ui-d",title:"云朵书店的彩虹书签",summary:"莉莉在云朵书店找到一枚彩虹书签。",updatedAt:"2025-11-15T07:20:00Z")
                ] {try store.saveStory(story)}
                model.refresh();model.selectConversation("archive:label-ui-a")
            }
            if testMode,args.contains("--sample-order-stories") {
                let fixtures=[
                    Story(id:"order-a",title:"小恐龙豆豆和蓝色石头",summary:"小恐龙豆豆在森林里找到一块蓝色石头。",updatedAt:"2020-01-03T00:00:00Z"),
                    Story(id:"order-b",title:"会敲门的小种子",summary:"莉莉捡到一颗发光的种子，里面传来轻轻的敲门声。",updatedAt:"2020-01-02T00:00:00Z"),
                    Story(id:"order-c",title:"豆豆和神奇种子",summary:"豆豆把种子种在花盆里，等着第一片小叶子。",updatedAt:"2020-01-01T00:00:00Z")
                ]
                for story in fixtures {try store.saveStory(story)}
                model.refresh()
            }
            if testMode,args.contains("--sample-order-middle") {model.selectConversation("archive:order-b")}
            if testMode,args.contains("--sample-order-cycle") {
                for id in ["order-b","order-c","order-a","order-b"] {model.selectConversation("archive:"+id)}
            }
            if testMode,args.contains("--sample-order-new") {
                model.newConversation();model.recordUserMessageSent("今天发现了蝴蝶")
                model.messages.append(ChatMessage(isUser:true,text:"今天发现了蝴蝶"))
            }
            if testMode,args.contains("--sample-unsent-draft") {model.chooseOpening(.story)}
            if testMode,args.contains("--sample-draft-return"),let story=model.stories.first {
                model.chooseOpening(.story);model.selectConversation("archive:"+story.id);model.newConversation()
            }
            if testMode,args.contains("--sample-sent-message") {
                model.recordUserMessageSent("今天发现了蝴蝶")
                model.messages.append(ChatMessage(isUser:true,text:"今天发现了蝴蝶"))
                model.messages.append(ChatMessage(isUser:false,text:"它停在哪里呀？我想听听你看到的样子。"))
            }
            if testMode,args.contains("--sample-selected-story"),let story=model.stories.first(where:{$0.title=="彩虹桥的小钟"}) {model.selectConversation("archive:"+story.id)}
            if testMode,args.contains("--sample-switched-story"),let story=model.stories.first(where:{$0.title=="小熊送苹果"}) {model.selectConversation("archive:"+story.id)}
            if testMode,args.contains("--sample-voice") {model.toggleCall()}
            if testMode,args.contains("--sample-drawing") { Task {try? await Task.sleep(nanoseconds:300_000_000);try? await model.phone?.sendText("画一辆红色小火车")} }
            if testMode,args.contains("--sample-voice-ended") {model.enterVoiceConversation()}
            if testMode, args.contains("--sample-story-choice") { model.openStory(ContentLibrary.books[0]) }
            if testMode, args.contains("--sample-long-chat") {
                model.recordUserMessageSent("小熊团子要给奶奶送苹果")
                model.browsing=false
                model.messages.append(ChatMessage(isUser:true,text:"小熊团子要给奶奶送苹果，它带着蓝色伞和红篮子。"))
                model.messages.append(ChatMessage(isUser:false,text:"团子把三个苹果轻轻放进红篮子，带上蓝色小伞，沿着铺满落叶的小路出发了。走到路牌前，它发现右边那条小路更平坦，便扶好篮子往右走。\n\n一阵风吹来，帽子滚进了草丛。团子先把篮子放稳，再扒开叶子，终于在一朵小白花旁找回了帽子。三个苹果还好好地躺在篮子里，一个也没少。\n\n这时，小刺猬抱着散开的花束走过来。团子蹲下来，帮它把花一朵朵捡好。小刺猬指着前方说：“那座稳稳的木桥，就通向你奶奶家！”",suggestions:["先去看看小木桥","请小刺猬一起走","给奶奶挑一朵花"]))
            }
            if testMode, args.contains("--sample-chat") {
                model.recordUserMessageSent("我想让小恐龙去月亮上种一朵花")
                model.browsing = false
                model.messages += [
                    ChatMessage(isUser: true, text: "我想让小恐龙去月亮上种一朵花。"),
                    ChatMessage(isUser: false, text: "小恐龙抱着一颗种子，坐上了云朵小船。\n月亮上没有泥土，怎么办呢？"),
                    ChatMessage(isUser: true, text: "用星星做泥土！")
                ]
            }
            if testMode, let index = args.firstIndex(of:"--sample-artwork"), args.count > index + 1 {
                model.browsing = false
                let data = try Data(contentsOf:URL(fileURLWithPath:args[index+1]))
                var art = StoryArtwork(storyID:UUID().uuidString,title:"彩虹桥尽头的小钟",storyText:"小兔和小刺猬在彩虹桥上推开圆石，蘑菇旁的小钟发出金色的光。",caption:"小兔和小刺猬一起推着彩虹桥上的圆石，蘑菇旁的小钟正发着光。")
                if let i=args.firstIndex(of:"--sample-artwork-info"),args.count>i+1,
                   let info=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[i+1]))) as? [String:Any] {
                    art.title=info["title"] as? String ?? "对话里的画";art.storyText=info["source"] as? String ?? ""
                    art.caption=info["caption"] as? String ?? "画好啦。"
                    art.fileExtension=URL(fileURLWithPath:args[index+1]).pathExtension == "jpg" ? "jpg" : "png"
                }
                model.recordUserMessageSent("画一张" + art.title)
                try ArtworkArchive.save(art,data:data)
                model.messages.append(ChatMessage(isUser:false,text:art.caption,artwork:art))
            }
            if testMode, args.contains("--sample-picture") {
                model.recordUserMessageSent("看一张雨天的画")
                model.browsing = false
                model.messages.append(ChatMessage(isUser: false, text: "小兔子把伞往小刺猬身边挪了挪。\n小刺猬会对它说什么呢？", sceneID: "rain", word: WordCard(hanzi: "雨伞", pinyin: "yǔ sǎn", english: "umbrella")))
            }
            if testMode, args.contains("--sample-pet-only-launch") {
                var settings = try store.settings(); settings.launchInPetMode = true; settings.desktopPetEnabled = true
                try store.setSettings(settings); model.refresh()
            }
            if testMode, args.contains("--sample-pending-memory") {
                try store.remember(Memory(kind: "interest", text: "喜欢发光的小恐龙", evidence: "我喜欢发光的小恐龙"))
                model.refresh()
            }
            _model = StateObject(wrappedValue: model)
            AppDelegate.launchModel = model
            AppDelegate.openMainWindow = { MainWindowController.shared.show(model) }
        } catch {
            let alert = NSAlert(); alert.messageText = "小小故事屋暂时无法打开数据"; alert.informativeText = error.localizedDescription; alert.runModal(); exit(1)
        }
    }
    var body: some SwiftUI.Scene {
        WindowGroup("小小故事屋", id: "main") { MainView(model: model).preferredColorScheme(.light).tint(Color.sage).onAppear { DesktopPetController.shared.attach(model); LaunchVerification.run(model) } }
            .defaultSize(width: 1060, height: 720)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) { Button("新的一段对话") { model.newConversation(); AppDelegate.openMainWindow?() }.keyboardShortcut("n", modifiers: .command) }
                CommandGroup(replacing: .appSettings) { Button("故事屋设置…") { model.requestParent = true }.keyboardShortcut(",", modifiers: .command) }
                CommandMenu("桌宠") {
                    Button(model.settings.desktopPetEnabled ? "隐藏桌宠" : "显示桌宠") { var s = model.settings; s.desktopPetEnabled.toggle(); model.updateSettings(s) }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("打开桌宠聊天") { DesktopPetController.shared.showQuickChat() }
                }
                CommandMenu("通话") {
                    Button(model.inCall ? "挂断电话" : "和莉莉通话") { model.toggleCall() }.keyboardShortcut("l", modifiers: [.command, .shift])
                    Button(model.phone?.muted == true ? "取消麦克风静音" : "麦克风静音") { model.phone?.toggleMute() }.disabled(!model.inCall)
                }
            }
    }
}
/// Native verification only: exercises real session navigation and bundled
/// gallery rendering while responses are delayed locally, without networking.
private final class BackgroundConversationPreview:StreamingPartnerModel {
    let quick:Bool
    init(quick:Bool) {self.quick=quick}
    func moderate(_ text:String) async throws -> Bool {true}
    func assessSafety(_ text:String,scope:SafetyReviewScope) async throws -> SafetyAssessment {SafetyAssessment(decision:.allow)}
    func respond(input:[[String:Any]],instructions:String,tools:[[String:Any]],allowTools:Bool) async throws -> ModelOutput {
        try await respondStreaming(input:input,instructions:instructions,tools:tools,allowTools:allowTools,onReply:{_ in})
    }
    func respondStreaming(input:[[String:Any]],instructions:String,tools:[[String:Any]],allowTools:Bool,onReply:@escaping @MainActor (String) async throws -> Void) async throws -> ModelOutput {
        let question=input.filter{$0["role"] as? String == "user"}.compactMap{$0["content"] as? String}.last ?? ""
        let picture=question.contains("朋友共用一把伞")
        try await Task.sleep(nanoseconds:picture && !quick ? 3_000_000_000 : 50_000_000)
        let text=picture ? "小刺猬和小兔一起躲在橙色雨伞下面。" : "月亮自己不会发光，我们看到的是它反射的太阳光。"
        try await onReply(text)
        return ModelOutput(items:[],text:String(decoding:try JSONEncoder().encode(PartnerReply(reply:text,suggestions:[])),as:UTF8.self))
    }
}

@MainActor enum LaunchVerification {
    private static var scheduled = false
    static func run(_ model: AppModel) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--verify-local-tts"), args.count > index + 1 {
            Task { await LocalVoiceDiagnostics.run(to: URL(fileURLWithPath: args[index+1])) }
            return
        }
        if let index = args.firstIndex(of: "--verify-audio"), args.count > index + 1 {
            Task { await AudioDiagnostics.run(to: URL(fileURLWithPath: args[index+1])) }
            return
        }
        guard !scheduled, let index = args.firstIndex(of: "--verify-launch") ?? args.firstIndex(of: "--inspect-launch"), args.count > index + 1 else { return }
        scheduled = true
        // Let SwiftUI settle at the target width before capturing the window.
        if args.contains("--minimum-window") { NSApp.windows.first(where: { $0.title == "小小故事屋" })?.setContentSize(NSSize(width: 1000, height: 600)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if args.contains("--verify-reopen") {
                NSApp.windows.first(where: { $0.title == "小小故事屋" })?.performClose(nil)
                AppDelegate.openMainWindow?()
            }
            let windows = NSApplication.shared.windows.filter { $0.isVisible && $0.title == "小小故事屋" }
            if let offsetIndex=args.firstIndex(of:"--scroll-offset"),args.count>offsetIndex+1,let amount=Double(args[offsetIndex+1]),let content=windows.first?.contentView {
                func allViews(_ view:NSView)->[NSView] {[view] + view.subviews.flatMap{allViews($0)}}
                if let scroll=allViews(content).compactMap({$0 as? NSScrollView}).first(where:{$0.bounds.width>500 && $0.bounds.height>200 && ($0.documentView?.frame.height ?? 0)>$0.contentView.bounds.height+100}) {
                    let maximum=max(0,(scroll.documentView?.frame.height ?? 0)-scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to:NSPoint(x:0,y:min(amount,maximum)));scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            var captured = false
            if let captureIndex = args.firstIndex(of: "--capture"), args.count > captureIndex + 1, let view = windows.first?.contentView {
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) { do { try png.write(to: URL(fileURLWithPath: args[captureIndex + 1])); captured = true } catch {} }
                }
            }
            if let gallery = args.firstIndex(of: "--capture-activities"), args.count > gallery + 1 {
                let view = NSHostingView(rootView: ActivityGallery().preferredColorScheme(.light))
                view.frame = NSRect(x:0,y:0,width:760,height:260); view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:args[gallery+1]))
                }
            }
            if let index=args.firstIndex(of:"--capture-voice-settings"),args.count>index+1 {
                let view=NSHostingView(rootView:ParentView(model:model,initialTab:1).preferredColorScheme(.light))
                view.frame=NSRect(x:0,y:0,width:780,height:650);view.layoutSubtreeIfNeeded()
                if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    if let png=bitmap.representation(using:.png,properties:[:]) {try? png.write(to:URL(fileURLWithPath:args[index+1]))}
                }
            }
            var quickChatCaptured=false
            if let captureIndex=args.firstIndex(of:"--capture-quick-chat"),args.count>captureIndex+1 {
                let view=NSHostingView(rootView:PetQuickChat(model:model,voice:model.voice,openHouse:{}).preferredColorScheme(.light))
                view.frame=NSRect(x:0,y:0,width:420,height:410);view.layoutSubtreeIfNeeded()
                let fitted=view.fittingSize;view.setFrameSize(NSSize(width:420,height:max(330,fitted.height)));view.layoutSubtreeIfNeeded()
                if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    if let png=bitmap.representation(using:.png,properties:[:]) {do {try png.write(to:URL(fileURLWithPath:args[captureIndex+1]));quickChatCaptured=true}catch{}}
                }
            }
            var petCaptured = false
            if let captureIndex = args.firstIndex(of: "--capture-pet"), args.count > captureIndex + 1 { petCaptured = DesktopPetController.shared.capture(to: URL(fileURLWithPath: args[captureIndex + 1])) }
            if args.contains("--verify-launch"), let galleryIndex = args.firstIndex(of: "--capture-pet-behaviors"), args.count > galleryIndex + 1 {
                let directory = URL(fileURLWithPath: args[galleryIndex + 1], isDirectory: true)
                do {
                    let report = try PetDiagnostics.capture(to: directory)
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
                } catch { fputs("Pet diagnostics: \(error.localizedDescription)\n", stderr) }
            }
            let petOnlySample = args.contains("--sample-pet-only-launch")
            let result: [String: Any] = ["success": (petOnlySample ? windows.isEmpty : !windows.isEmpty) && (!model.settings.desktopPetEnabled || DesktopPetController.shared.isVisible),"petOnlyLaunch":petOnlySample,"shouldOpenMainOnLaunch":model.shouldOpenMainWindowOnLaunch,"pendingMemoryCount":model.pendingCount,"activeSuggestionCount":model.activeSuggestions.count,"desktopPetEnabled":model.settings.desktopPetEnabled, "bundleID": Bundle.main.bundleIdentifier ?? "", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "connectionAvailable": model.cloudAvailable, "fixture": args.contains("--verify-launch"),"fixtureStore":args.contains("--verify-launch") ? model.store.url.path : "", "voiceStyle":model.settings.voiceStyle, "storyArtworkCount":model.messages.filter { $0.artwork != nil }.count,"artworkInProgress":!(model.phone?.artworkStatus.isEmpty ?? true),"entryOrigin":model.entryOrigin == .voice ? "voice" : "text","openingOptions":model.showsOpeningOptions ? OpeningPrompt.allCases.count : 0,"callActive":model.inCall,"callState":model.phone?.state.rawValue ?? "ended","inputTranscriptPresent":!(model.phone?.inputTranscript.isEmpty ?? true),"listeningHintPresent":!(model.phone?.listeningHint.isEmpty ?? true),"placeholderUserMessages":model.messages.filter{$0.isUser && ($0.text=="…" || $0.text=="...")}.count,"quickChatSnapshotSaved":quickChatCaptured,"contentLobbyVisible":false,"sidebarVisible":true,"sidebarStoryCount":model.stories.count,"sidebarGeneratingCount":model.conversations.filter{$0.isGenerating}.count,"sidebarUnreadCount":model.conversations.filter{$0.hasUnreadReply}.count,"visibleSceneCount":model.messages.filter{$0.sceneID != nil}.count,"sidebarStatusOrder":args.contains("--verify-launch") ? model.conversations.map(\.statusLabel) : [],"sidebarConversationCount":model.conversations.count,"sidebarOrder":model.conversations.map(\.navigationID),"sidebarTitleOrder":args.contains("--verify-launch") ? model.conversations.map(\.title) : [],"sidebarTimestampOrder":args.contains("--verify-launch") ? model.conversations.map{ConversationLabels.timestamp($0.updatedAt)} : [],"conversationStarted":model.isConversationStarted,"draftPresent":!model.draft.isEmpty,"selectedConversationID":model.isConversationStarted ? model.selectedConversationID : "","selectedConversationTitle":model.isConversationStarted ? model.conversationTitle : "","headerTitle":model.isConversationStarted ? model.conversationTitle : "莉莉","selectedRowCount":model.conversations.filter{$0.id == model.selectedConversationID}.count, "reopened": args.contains("--verify-reopen"), "snapshotSaved": captured, "petSnapshotSaved": petCaptured, "desktopPet": DesktopPetController.shared.verification, "windows": windows.map { ["title": $0.title, "width": $0.frame.width, "height": $0.frame.height] }]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: args[index + 1]))
            if args.contains("--verify-launch"),!args.contains("--keep-preview-open") { for message in model.messages { if let art = message.artwork { ArtworkArchive.remove(art) } }; NSApplication.shared.terminate(nil) }
        }
    }
}
