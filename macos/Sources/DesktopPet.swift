import AppKit
import SwiftUI
import Combine

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class DesktopPetController: NSObject, ObservableObject {
    static let shared = DesktopPetController()
    private var panel: PetPanel?
    private var popover: NSPopover?
    private weak var model: AppModel?
    private var settingsObserver: AnyCancellable?
    private var canvas: PetCanvas?
    private var opener: (() -> Void)?
    @Published private(set) var behaviorCaption = "找我聊天"
    var isVisible: Bool { panel?.isVisible == true }
    func registerOpener(_ action: @escaping () -> Void) { opener = action }
    func attach(_ model: AppModel) {
        guard self.model !== model else { sync(); return }
        self.model = model
        settingsObserver = model.$settings.sink { [weak self] _ in DispatchQueue.main.async { self?.sync() } }
        sync()
    }
    func sync() {
        guard let model else { return }
        guard model.settings.desktopPetEnabled else { canvas?.animationsEnabled = false; model.voice.cancelRecording(); panel?.orderOut(nil); popover?.close(); return }
        if panel == nil { create(model) }
        canvas?.atlas = PetCatalog.atlas(model.settings.petID)
        canvas?.followsPointer = model.settings.petFollowsPointer
        canvas?.ambientEnabled = model.settings.petAmbientEnabled
        panel?.orderFrontRegardless()
        canvas?.animationsEnabled = true
    }
    private func create(_ model: AppModel) {
        let panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 210, height: 284), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "莉莉桌宠"; panel.identifier = NSUserInterfaceItemIdentifier("tinytales-desktop-pet")
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.level = .floating
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DesktopPetView(model: model, voice: model.voice, controller: self))
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var point = NSPoint(x: frame.maxX - 248, y: frame.minY + 60)
        if !CommandLine.arguments.contains("--verify-launch"), let saved = UserDefaults.standard.string(forKey: "desktopPetPosition") { point = NSPointFromString(saved) }
        point.x = min(max(point.x, frame.minX), frame.maxX - 210); point.y = min(max(point.y, frame.minY), frame.maxY - 284)
        panel.setFrameOrigin(point); self.panel = panel
    }
    func register(_ canvas: PetCanvas) {
        self.canvas = canvas
        canvas.onClick = { [weak self] in self?.showQuickChat() }
        canvas.onOpen = { [weak self] in self?.openHouse() }
        canvas.onHide = { [weak self] in self?.hide() }
        canvas.onMove = { point in if !CommandLine.arguments.contains("--verify-launch") { UserDefaults.standard.set(NSStringFromPoint(point), forKey: "desktopPetPosition") } }
        canvas.interactionBlocked = { [weak self] in self?.popover?.isShown == true }
        canvas.onCaptionChange = { [weak self] caption in self?.behaviorCaption = caption ?? "找我聊天" }
        canvas.onAmbientToggle = { [weak self] in
            guard let model = self?.model else { return }
            var settings = model.settings; settings.petAmbientEnabled.toggle(); model.updateSettings(settings)
        }
    }
    func openHouse() {
        popover?.close()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "小小故事屋" }) { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil) }
        else { opener?() }
    }
    func showQuickChat() {
        guard let model else { return }
        if popover?.isShown == true { popover?.close(); return }
        guard let canvas else { return }
        let popover = NSPopover(); popover.behavior = .transient; popover.contentSize = NSSize(width: 420, height: 350)
        popover.contentViewController = NSHostingController(rootView: PetQuickChat(model: model, voice: model.voice, openHouse: { [weak self] in self?.openHouse() }))
        self.popover = popover; popover.show(relativeTo: canvas.bounds, of: canvas, preferredEdge: .minX)
        resizeQuickChat()
        popover.contentViewController?.view.window?.makeKey()
    }
    func resizeQuickChat() {
        guard let popover, let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        popover.contentSize = NSSize(width:420,height:max(350,view.fittingSize.height))
    }
    func record() { guard let model else { return }; popover?.close(); if !model.cloudAvailable { openHouse(); model.showParent = true; return }; model.toggleCall() }
    func hide() { guard let model else { return }; var settings = model.settings; settings.desktopPetEnabled = false; model.updateSettings(settings) }
    func shutdown() { canvas?.animationsEnabled = false; model?.voice.shutdown(); popover?.close(); panel?.orderOut(nil) }
    func capture(to url: URL) -> Bool {
        guard let panel, let view = panel.contentView else { return false }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }
    var verification: [String: Any] {
        ["visible": isVisible, "floating": panel?.level == .floating, "transparent": panel?.isOpaque == false, "joinsAllSpaces": panel?.collectionBehavior.contains(.canJoinAllSpaces) == true, "width": panel?.frame.width ?? 0, "height": panel?.frame.height ?? 0, "petID": model?.settings.petID ?? "", "illustrated": canvas?.atlas?.illustrated == true, "behavior": canvas?.behaviorVerification ?? [:]]
    }
}
struct PetCanvasHost: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: NativeVoice
    let controller: DesktopPetController
    func makeNSView(context: Context) -> PetCanvas {
        let view = PetCanvas(); controller.register(view)
        view.motion = { [weak model, weak voice] in
            PetMotion.resolve(recording: voice?.recording == true || (model?.phone?.state == .listening && model?.phone?.muted != true), busy: model?.busy == true || model?.phone?.state == .thinking, speaking: voice?.speaking == true || model?.phone?.state == .speaking, preparing: voice?.preparing == true || model?.phone?.state == .connecting, error: !(model?.error.isEmpty ?? true))
        }
        view.engaged = { [weak model] in model?.inCall == true }
        view.atlas = PetCatalog.atlas(model.settings.petID); view.followsPointer = model.settings.petFollowsPointer; view.ambientEnabled = model.settings.petAmbientEnabled
        return view
    }
    func updateNSView(_ view: PetCanvas, context: Context) { view.atlas = PetCatalog.atlas(model.settings.petID); view.followsPointer = model.settings.petFollowsPointer; view.ambientEnabled = model.settings.petAmbientEnabled }
}
struct DesktopPetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: NativeVoice
    @ObservedObject var controller: DesktopPetController
    private var visualMode: CallVisualMode {
        if model.inCall { return model.callVisualMode }
        if voice.speaking { return .speaking }
        if voice.preparing || model.busy { return .thinking }
        return .idle
    }
    private var title: String {
        if model.phone?.muted == true { return "已静音" }
        if model.phone?.state == .listening { return "我在听" }
        if model.phone?.state == .speaking || voice.speaking { return "我在讲" }
        if model.busy || voice.preparing || model.phone?.state == .thinking { return "想一想…" }
        if model.phone?.state == .connecting { return "接通中…" }
        return controller.behaviorCaption
    }
    var body: some View {
        VStack(spacing: 4) {
            PetCanvasHost(model: model, voice: voice, controller: controller).frame(width: 174, height: 174).help("单击聊天，双击打开对话；轻轻来回摸摸莉莉，或右键一起玩。").background { if visualMode != .idle { Circle().fill(visualMode.color.opacity(0.09)).overlay(Circle().stroke(visualMode.color.opacity(0.22),lineWidth:2)).frame(width:155,height:155) } }
            Group {
                if model.inCall,let words=model.phone?.inputTranscript,!words.isEmpty {
                    Text("你说："+words).font(.system(size:15,weight:.medium,design:.rounded)).lineLimit(1).truncationMode(.tail).foregroundStyle(Color.ink).padding(.horizontal,8).help(words)
                } else if !model.artworkActivity.isEmpty {
                    HStack(spacing:6) { ProgressView().controlSize(.small); Text(model.artworkActivity).font(.system(size:14,weight:.medium,design:.rounded)).foregroundStyle(Color.ink) }
                } else if model.inCall && visualMode == .speaking {
                    DuplexLevels(input:model.phone?.inputLevel ?? 0,output:model.phone?.outputLevel ?? 0,muted:model.phone?.muted == true).frame(height:25)
                } else if visualMode != .idle {
                    ActivityWave(mode:visualMode,level:model.inCall ? model.callVisualLevel : 0.35).frame(width:100,height:25)
                } else {Text(title).font(.system(size:17,weight:.semibold,design:.rounded)).foregroundStyle(Color.ink).padding(.horizontal,13).padding(.vertical,5).background(Color.lilac.opacity(0.97),in:Capsule())}
            }
                .frame(width: 210,height:32)
                .overlay(alignment: .trailing) {
                    if voice.speaking || voice.preparing {
                        Button { voice.stopSpeaking() } label: { Image(systemName: "speaker.slash.fill").font(.system(size: 15)).foregroundStyle(Color.sage).frame(width: 30, height: 30).background(Color.paper, in: Circle()) }.buttonStyle(.plain).help("停一下").accessibilityLabel("停止朗读").padding(.trailing, 7)
                    }
                }
            HStack(spacing: 8) {
                Button { controller.showQuickChat() } label: { Image(systemName: "bubble.left.fill").font(.system(size: 18)).frame(width: 42, height: 40) }.help("聊天").accessibilityLabel("聊天")
                PhoneButton(model: model, compact: true).padding(2)
                Button { controller.openHouse() } label: { Image(systemName: "house.fill").font(.system(size: 18)).frame(width: 42, height: 40) }.help("打开对话").accessibilityLabel("打开对话")
            }.padding(.horizontal, 6).padding(.vertical, 2).buttonStyle(.plain).foregroundStyle(Color.sage)
                .background { Capsule().fill(Color.paper.opacity(0.97)).shadow(color: Color.ink.opacity(0.10), radius: 5, x: 0, y: 2) }
        }.frame(width: 210, height: 284).background(.clear)
    }
}
struct PetQuickChat:View {
    @ObservedObject var model:AppModel
    @ObservedObject var voice:NativeVoice
    var openHouse:()->Void
    @FocusState private var inputFocused:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:9) {UnicornPicture().frame(width:30,height:34);Text("莉莉").font(.system(size:21,weight:.semibold,design:.rounded));Spacer();Button(action:openHouse) {Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:17)).padding(7)}.buttonStyle(.plain).help("打开对话")}
            Text(model.busy ? "莉莉在想…" : model.messages.last(where:{!$0.isUser && !$0.isRetracted && $0.source != "welcome"})?.text ?? (model.entryOrigin == .voice ? "莉莉在这里。" : "你好，想聊些什么？"))
                .font(.system(size:18)).lineSpacing(5).lineLimit(4).frame(maxWidth:.infinity,minHeight:62,alignment:.topLeading)
            if let art = model.messages.last(where:{!$0.isUser})?.artwork, let image = NSImage(contentsOf:art.url) {
                Button(action:openHouse) { Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:160).clipShape(RoundedRectangle(cornerRadius:12)) }.buttonStyle(.plain).help("打开这幅画")
            }
            if model.showsOpeningOptions {OpeningOptions(model:model,compact:true)}
            if !model.error.isEmpty {Text(model.error).font(.system(size:14)).foregroundStyle(.orange).lineLimit(2)}
            HStack(spacing:10) {
                TextField("写给莉莉…",text:$model.draft,axis:.vertical).textFieldStyle(.plain).font(.system(size:17)).lineLimit(1...3).focused($inputFocused).onSubmit{model.send()}.disabled(model.busy)
                if !model.draft.isEmpty {Button {model.send()} label:{Image(systemName:"arrow.up.circle.fill").font(.system(size:29))}.buttonStyle(.plain).disabled(model.busy)}
                PhoneButton(model:model,compact:true)
            }.padding(12).toyCard(.white,.lilacEdge.opacity(0.5),radius:17)
            if model.inCall {
                HStack(spacing:12) {
                    Text(model.phone?.inputTranscript.isEmpty == false ? (model.phone!.inputPreviewIsFinal ? "你说：" : "暂时听到：")+model.phone!.inputTranscript : model.phone?.listeningHint.isEmpty == false ? model.phone!.listeningHint : model.callStatusTitle).font(.system(size:15,weight:.medium)).foregroundStyle(model.callVisualMode.color).lineLimit(2)
                    Spacer()
                    Button {model.phone?.toggleMute()} label:{Label(model.phone?.muted == true ? "开麦" : "静音",systemImage:model.phone?.muted == true ? "mic.slash" : "mic").font(.system(size:15))}.buttonStyle(.plain).disabled(model.isCorrectingVoice)
                }.padding(.horizontal,4).padding(.vertical,6)
                VoiceCallControls(model:model,compact:true)
            }
        }.padding(18).frame(width:420).frame(minHeight:330,alignment:.topLeading).background(Color.paper).foregroundStyle(Color.ink)
            .onAppear {inputFocused = !model.inCall}
            .onChange(of:model.inCall) {_,active in if active {inputFocused=false}}
            .onChange(of:model.draft) {_,text in if !text.isEmpty && !model.inCall {inputFocused=true}}
            .onChange(of:model.messages.last(where:{!$0.isUser})?.artwork?.id) {_,_ in DesktopPetController.shared.resizeQuickChat()}
            .onChange(of:model.isCorrectingVoice) {_,_ in DesktopPetController.shared.resizeQuickChat()}
            .onChange(of:model.phone?.latestVoiceInputID) {_,_ in DesktopPetController.shared.resizeQuickChat()}
    }
}
