import SwiftUI
import AppKit

extension Color {
    static let paper = Color(red: 1, green: 0.98, blue: 0.94)
    static let sidebarPaper = Color(red: 0.94, green: 0.90, blue: 0.99)
    static let ink = Color(red: 0.25, green: 0.18, blue: 0.35)
    static let sage = Color(red: 0.49, green: 0.32, blue: 0.73)
    static let softSage = Color(red: 0.91, green: 0.84, blue: 0.99)
    static let quiet = Color(red: 0.39, green: 0.34, blue: 0.47)
    static let lilac = Color(red: 0.92, green: 0.86, blue: 1)
    static let lilacEdge = Color(red: 0.76, green: 0.63, blue: 0.93)
    static let peach = Color(red: 1, green: 0.87, blue: 0.73)
    static let peachEdge = Color(red: 0.94, green: 0.67, blue: 0.45)
    static let sky = Color(red: 0.83, green: 0.93, blue: 1)
    static let skyEdge = Color(red: 0.55, green: 0.77, blue: 0.92)
    static let mint = Color(red: 0.85, green: 0.96, blue: 0.84)
}
struct BrandImage: View {
    var body: some View {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Brand/story-unicorn.png"), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
    }
}
struct UnicornPicture: View {
    var body: some View {
        if let image = PetCatalog.atlas("unicorn")?.frame(row: 0, column: 0) { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
        else { BrandImage() }
    }
}
struct ToyCard: ViewModifier {
    var fill: Color
    var edge: Color
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: radius).fill(LinearGradient(colors: [.white.opacity(0.30), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: edge.opacity(0.16), radius: 6, x: 0, y: 3)
        }
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(edge.opacity(0.75), lineWidth: 1.2))
    }
}
extension View { func toyCard(_ fill: Color, _ edge: Color, radius: CGFloat = 20) -> some View { modifier(ToyCard(fill: fill, edge: edge, radius: radius)) } }

struct StoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
struct StoryRainbow: View {
    var body: some View {
        Canvas { context, size in
            let colors: [Color] = [.peachEdge, .lilacEdge, .skyEdge, .mint]
            for (index, color) in colors.enumerated() {
                let inset = CGFloat(index) * 0.095
                var arc = Path()
                arc.move(to: CGPoint(x: size.width * (0.08 + inset), y: size.height * 0.86))
                arc.addCurve(to: CGPoint(x: size.width * (0.92 - inset), y: size.height * 0.86), control1: CGPoint(x: size.width * (0.08 + inset), y: size.height * (0.01 + inset)), control2: CGPoint(x: size.width * (0.92 - inset), y: size.height * (0.01 + inset)))
                context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: max(3, size.width * 0.065), lineCap: .round))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
struct StoryBooks: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.sky).frame(width: 43, height: 59).rotationEffect(.degrees(-13)).offset(x: -21, y: 4)
            RoundedRectangle(cornerRadius: 8).fill(Color.peach).frame(width: 43, height: 59).rotationEffect(.degrees(12)).offset(x: 22, y: 3)
            RoundedRectangle(cornerRadius: 8).fill(Color.sage).frame(width: 45, height: 63)
                .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.35)).frame(width: 3, height: 46).padding(.leading, 6) }
                .overlay { Image(systemName: "sparkle").font(.system(size: 22)).foregroundStyle(Color.peach) }
        }.frame(width: 100, height: 78).accessibilityHidden(true)
    }
}

struct MainView:View {
    @ObservedObject var model:AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var deletionCandidate:ConversationItem?
    private var conversation:[ChatMessage] {model.messages.filter{$0.source != "welcome"}}
    var body:some View {
        HStack(spacing:0) {
            sidebar
            Divider().overlay(Color.lilacEdge.opacity(0.15))
            conversationPane
        }.foregroundStyle(Color.ink).background(Color.paper).frame(minWidth:1000,minHeight:600)
            .sheet(isPresented:$model.showParent) {ParentView(model:model)}
            .alert("删除这段对话？",isPresented:Binding(get:{deletionCandidate != nil},set:{if !$0 {deletionCandidate=nil}}),presenting:deletionCandidate) {item in
                Button("取消",role:.cancel) {deletionCandidate=nil}
                Button("删除",role:.destructive) {model.deleteConversation(item.id);deletionCandidate=nil}
            } message: {item in
                Text("“\(item.title)”及其中的故事和配图将被删除，无法恢复。" + (model.selectedConversationID == item.id && (model.busy || model.inCall) ? "正在进行的通话或生成也会停止。" : ""))
            }
            .onChange(of:model.requestParent) {_,requested in if requested {model.requestParent=false;model.showParent=true}}
            .onAppear {DesktopPetController.shared.registerOpener {openWindow(id:"main")}}
    }
    private var conversationPane:some View {
        VStack(spacing:0) {
            header
            Divider().overlay(Color.lilacEdge.opacity(0.15))
            ScrollViewReader {proxy in
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        if conversation.isEmpty {
                            ConversationWelcome(model:model).frame(maxWidth:.infinity).padding(.top,44).padding(.bottom,24)
                        }
                        ForEach(conversation) {message in
                            MessageView(message:message,onRead:message.isStreaming || model.inCall || message.isRetracted ? nil : {model.voice.speak(message.text)},onEdit:model.canCorrectVoice(message) ? {model.editVoiceInput(message.externalID)} : nil,onRetry:model.canCorrectVoice(message) ? {model.retryVoiceInput(message.externalID)} : nil)
                                .id(message.id)
                        }
                        if (model.busy && !conversation.contains(where:{$0.isStreaming})) || !model.artworkActivity.isEmpty {
                            HStack(spacing:10) {ProgressView().controlSize(.small);Text(!model.artworkActivity.isEmpty ? model.artworkActivity : model.activity.isEmpty ? "莉莉在想…" : model.activity).font(.system(size:16)).foregroundStyle(Color.quiet)}.padding(.vertical,12)
                        }
                        Color.clear.frame(height:1).id("end")
                    }.padding(.horizontal,28).padding(.vertical,20).frame(maxWidth:820).frame(maxWidth:.infinity)
                }
                .onChange(of:model.selectedConversationID) {_,_ in proxy.scrollTo("end",anchor:.bottom)}
                .onChange(of:model.messages.count) {_,_ in withAnimation {proxy.scrollTo("end",anchor:.bottom)}}
                .onChange(of:model.messages.last?.text) {_,_ in proxy.scrollTo("end",anchor:.bottom)}
                .onChange(of:model.messages.last?.artwork?.id) {_,_ in proxy.scrollTo("end",anchor:.bottom)}
            }
            composer.frame(maxWidth:820).frame(maxWidth:.infinity)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:8) {
                UnicornPicture().frame(width:28,height:34)
                Text("小小故事屋").font(.system(size:18,weight:.semibold,design:.rounded))
            }.padding(.top,2).padding(.bottom,4)
            Button {model.newConversation()} label:{
                Label("新对话",systemImage:"square.and.pencil").font(.system(size:16,weight:.semibold,design:.rounded))
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,12)
                    .background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:12))
                    .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.lilacEdge.opacity(0.3)))
            }.buttonStyle(StoryButtonStyle()).disabled(model.inCall).opacity(model.inCall ? 0.5 : 1)
            VStack(alignment:.leading,spacing:9) {
                Text("会话").font(.system(size:15,weight:.semibold)).foregroundStyle(Color.quiet).padding(.horizontal,4)
                ScrollView {
                    VStack(spacing:4) {
                        ForEach(model.conversations,id:\.navigationID) {item in
                            let selected=model.selectedConversationID == item.id
                            HStack(spacing:0) {
                                Button {model.selectConversation(item.id)} label:{
                                  HStack(alignment:.top,spacing:9) {
                                    Group {
                                        if item.isGenerating {ProgressView().controlSize(.small)}
                                        else if item.hasError {Image(systemName:"exclamationmark.circle").foregroundStyle(Color(red:0.72,green:0.35,blue:0.14))}
                                        else {Image(systemName:item.storyID == nil ? (selected ? "bubble.left.fill" : "bubble.left") : (selected ? "book.closed.fill" : "book.closed"))}
                                    }.font(.system(size:14)).frame(width:17).padding(.top,2)
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(item.title).font(.system(size:15,weight:selected ? .semibold : .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(ConversationLabels.timestamp(item.updatedAt)).font(.system(size:11)).monospacedDigit().foregroundStyle(Color.quiet)
                                            .lineLimit(1).minimumScaleFactor(0.9)
                                    }
                                    Spacer(minLength:0)
                                  }.padding(.leading,11).padding(.trailing,3).padding(.vertical,11).frame(maxWidth:.infinity,alignment:.leading)
                                    .contentShape(RoundedRectangle(cornerRadius:10))
                                }.buttonStyle(StoryButtonStyle()).disabled(model.inCall && !selected).opacity(model.inCall && !selected ? 0.5 : 1)
                                .accessibilityAddTraits(selected ? [.isSelected] : [])
                                .accessibilityLabel(item.title+"，"+ConversationLabels.timestamp(item.updatedAt,full:true))
                                .accessibilityValue(item.statusLabel)
                                .help(item.title+"\n"+ConversationLabels.timestamp(item.updatedAt,full:true)+(item.statusLabel.isEmpty ? "" : "\n"+item.statusLabel))
                                if item.hasUnreadReply && !selected {
                                    Circle().fill(Color.sage).frame(width:6,height:6).padding(.trailing,4).accessibilityLabel("有新回复")
                                }
                                Menu {
                                    Button(role:.destructive) {deletionCandidate=item} label:{Label("删除对话…",systemImage:"trash")}
                                } label:{Image(systemName:"ellipsis").font(.system(size:14,weight:.semibold)).frame(width:25,height:30).contentShape(Rectangle())}
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing,3)
                                    .accessibilityLabel("更多操作，"+item.title).help("更多操作")
                            }.foregroundStyle(selected ? Color.sage : Color.ink)
                                .background(selected ? Color.sage.opacity(0.13) : .clear,in:RoundedRectangle(cornerRadius:10))
                                .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(selected ? Color.sage.opacity(0.28) : .clear))
                                .overlay(alignment:.leading) {if selected {Capsule().fill(Color.sage).frame(width:3,height:24).padding(.leading,1)}}
                                .contextMenu {Button(role:.destructive) {deletionCandidate=item} label:{Label("删除对话…",systemImage:"trash")}}
                        }
                    }
                }
            }.frame(maxHeight:.infinity,alignment:.top)
            Button {model.showParent=true} label:{Label("设置",systemImage:"gearshape").font(.system(size:15,weight:.medium)).foregroundStyle(Color.quiet).frame(maxWidth:.infinity,alignment:.leading).padding(10)}.buttonStyle(.plain)
        }.padding(16).frame(width:236).frame(maxHeight:.infinity,alignment:.top).background(Color.sidebarPaper.opacity(0.28))
    }
    private var header:some View {
        HStack(spacing:10) {
            UnicornPicture().frame(width:36,height:40)
            if model.isConversationStarted {
                VStack(alignment:.leading,spacing:3) {
                    Text(model.conversationTitle).font(.system(size:20,weight:.semibold,design:.rounded)).lineLimit(1)
                    Text("莉莉 · AI伙伴").font(.system(size:12,weight:.medium)).foregroundStyle(Color.quiet)
                }
            } else {
                Text("莉莉").font(.system(size:22,weight:.semibold,design:.rounded))
                Text("AI伙伴").font(.system(size:12,weight:.medium)).foregroundStyle(Color.quiet).padding(.horizontal,8).padding(.vertical,4).background(Color.lilac.opacity(0.35),in:Capsule())
            }
            Spacer()
            if !model.cloudAvailable {Button("连接莉莉"){model.showParent=true}.buttonStyle(.borderedProminent).tint(Color.sage)}
        }.padding(.horizontal,24).padding(.vertical,14)
    }
    private var composer:some View {
        VStack(spacing:12) {
            if !model.error.isEmpty {
                HStack(alignment:.top,spacing:10) {Image(systemName:"exclamationmark.circle");Text(model.error).lineSpacing(4);Spacer();Button {model.error=""} label:{Image(systemName:"xmark")}.buttonStyle(.plain)}.font(.system(size:15)).padding(13).background(Color.peach.opacity(0.4),in:RoundedRectangle(cornerRadius:14))
            }
            NativeComposer(model:model,voice:model.voice)
        }.padding(.horizontal,28).padding(.top,12).padding(.bottom,22)
    }
}
struct OpeningOptions:View {
    @ObservedObject var model:AppModel
    var compact=false
    var body:some View {
        LazyVGrid(columns:[GridItem(.flexible(),spacing:10),GridItem(.flexible(),spacing:10)],spacing:10) {
            ForEach(OpeningPrompt.allCases) {choice in
                Button {model.chooseOpening(choice)} label:{
                    HStack(spacing:10) {Image(systemName:choice.icon).font(.system(size:17));Text(choice.title).font(.system(size:compact ? 15 : 17,weight:.medium,design:.rounded));Spacer(minLength:0)}
                        .foregroundStyle(Color.ink).padding(.horizontal,14).frame(height:compact ? 40 : 48)
                        .background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:13))
                        .overlay(RoundedRectangle(cornerRadius:13).stroke(Color.lilacEdge.opacity(0.3)))
                }.buttonStyle(StoryButtonStyle())
            }
        }.accessibilityElement(children:.contain).accessibilityLabel("开场建议")
    }
}
struct ConversationWelcome:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(spacing:18) {
            UnicornPicture().frame(width:model.entryOrigin == .voice ? 110 : 80,height:model.entryOrigin == .voice ? 118 : 86)
            Text(model.entryOrigin == .voice ? "莉莉在这里" : "你好，我是莉莉。").font(.system(size:25,weight:.semibold,design:.rounded))
            if model.entryOrigin == .text {Text("想聊些什么？").font(.system(size:18)).foregroundStyle(Color.quiet)}
            if model.showsOpeningOptions {OpeningOptions(model:model).frame(maxWidth:410).padding(.top,9)}
        }.frame(maxWidth:500)
    }
}
struct PhoneButton: View {
    @ObservedObject var model: AppModel
    var compact = false
    var body: some View {
        Button { model.toggleCall() } label: {
            if compact {
                CallActivityOrb(mode:model.callVisualMode,level:model.callVisualLevel,size:48,hangupBadge:model.inCall)
            } else {
                HStack(spacing:9) {
                    Image(systemName:model.inCall ? "phone.down.fill" : "phone.fill").font(.system(size:19,weight:.semibold))
                    Text(model.inCall ? "挂断" : "打电话").font(.system(size:19,weight:.bold,design:.rounded))
                }.foregroundStyle(.white).frame(height:48).padding(.horizontal,16).background(model.inCall ? Color(red:0.81,green:0.28,blue:0.35) : Color.sage,in:RoundedRectangle(cornerRadius:16))
            }
        }.buttonStyle(.plain).help(model.inCall ? "挂断电话" : "给莉莉打电话")
            .accessibilityLabel(model.inCall ? "挂断电话" : "开始通话")
    }
}
struct NativeComposer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: NativeVoice
    @FocusState private var inputFocused:Bool
    private var status: String {
        if model.phone?.muted == true { return "已静音" }
        switch model.phone?.state { case .connecting: return "正在接通…"; case .listening: return "莉莉在听"; case .thinking: return "莉莉在想…"; case .speaking: return "莉莉在说"; default: return "通话中" }
    }
    var body: some View {
        VStack(spacing: 12) {
            if model.inCall {
                CallActivityPanel(model: model)
            }
            HStack(spacing: 13) {
                if !model.inCall {
                    Menu {
                        Button("编一个新故事"){model.preparePrompt("我们编一个全新的故事吧，你先讲一个有趣的开头，我来接着编。")}
                        if model.storySession.current != nil {Button("把这个故事画出来"){model.preparePrompt("把我们刚刚讲的这个故事画出来吧。")}}
                    } label:{Image(systemName:"plus").font(.system(size:18)).foregroundStyle(Color.quiet).frame(width:28,height:32)}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多对话动作")
                }
                TextField("写给莉莉…", text: $model.draft, axis: .vertical).textFieldStyle(.plain).font(.system(size: 18, design: .rounded)).lineLimit(1...3).focused($inputFocused).onSubmit { model.send() }.disabled(model.busy)
                if voice.speaking || voice.preparing { Button { voice.stopSpeaking() } label: { Label("停一下", systemImage: "speaker.slash.fill").font(.system(size: 17, weight: .medium)) }.buttonStyle(.plain) }
                if model.busy { Button("停一下") { model.cancel() }.font(.system(size: 18, weight: .semibold)).buttonStyle(.bordered) }
                else if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button { model.send() } label: { Image(systemName: "arrow.up").font(.system(size: 22, weight: .bold)).foregroundStyle(.white).frame(width: 48, height: 48).background(Color.sage, in: Circle()) }.buttonStyle(.plain).disabled(model.connectingCall).help(model.connectingCall ? "接通后发送" : "发送") }
                PhoneButton(model: model)
            }.padding(12).toyCard(.white, .lilacEdge.opacity(0.5), radius: 19)
        }.onAppear {inputFocused = !model.inCall}
            .onChange(of:model.inCall) {_,active in if active {inputFocused=false}}
            .onChange(of:model.draft) {_,text in if !text.isEmpty && !model.inCall {inputFocused=true}}
    }
}
struct MessageView: View {
    var message: ChatMessage
    var onRead: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    private var preferredWidth: CGFloat {
        if message.artwork != nil || message.sceneID != nil || message.word != nil { return 600 }
        let font = NSFont.systemFont(ofSize: 18, weight: .medium)
        let lineWidth = message.text.components(separatedBy: .newlines).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(message.isUser ? 490 : 700, max(message.isUser ? (onEdit != nil || message.isRetracted ? 220 : 145) : 300, ceil(lineWidth) + 38))
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    if message.isUser { Image(systemName: "face.smiling.fill").font(.system(size: 22)).foregroundStyle(Color(red: 0.72, green: 0.35, blue: 0.14)) }
                    else { UnicornPicture().frame(width: 28, height: 28).background(.white.opacity(0.6), in: Circle()) }
                    Text(message.isUser ? "我说" : message.source == "archive" ? "上次讲到" : "莉莉说").font(.system(size: 14, weight: .bold, design: .rounded))
                    Spacer()
                    if message.isRetracted {Text("已撤回").font(.system(size:13)).foregroundStyle(Color.quiet)}
                    else if message.isInterrupted {Text("已停止").font(.system(size:13)).foregroundStyle(Color.quiet)}
                    if !message.isUser, !message.isStreaming, let onRead { Button(action: onRead) { Label("再听", systemImage: "speaker.wave.2.fill").font(.system(size: 16, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.7), in: Capsule()) }.buttonStyle(.plain) }
                }
                if let artwork = message.artwork, let image = NSImage(contentsOf:artwork.url) {
                    VStack(alignment:.leading,spacing:12) {
                        Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:520).clipShape(RoundedRectangle(cornerRadius:18))
                        Text("《\(artwork.title)》的配图").font(.system(size:23,weight:.bold,design:.rounded))
                    }
                }
                if let id = message.sceneID, let scene = Scene.all.first(where: { $0.id == id }), let url = scene.url, let image = NSImage(contentsOf: url) {
                    VStack(alignment: .leading, spacing: 12) { Image(nsImage: image).resizable().scaledToFit().frame(width: min(420, 240 * image.size.width / max(1, image.size.height))).clipShape(RoundedRectangle(cornerRadius: 18)); Text("看图素材 · " + scene.title).font(.system(size: 23, weight: .bold, design: .rounded)) }
                }
                Text(message.text).strikethrough(message.isRetracted).foregroundStyle(message.isRetracted ? Color.quiet : Color.ink).font(.system(size: 18, weight: .regular, design: .rounded)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if onEdit != nil || onRetry != nil {
                    HStack(spacing:16) {
                        if let onRetry {Button(action:onRetry) {Label("重说",systemImage:"arrow.counterclockwise")} }
                        if let onEdit {Button(action:onEdit) {Label("改文字",systemImage:"pencil")} }
                    }.font(.system(size:14,weight:.medium)).buttonStyle(.plain).foregroundStyle(Color.sage).frame(maxWidth:.infinity,alignment:.trailing)
                }
                if message.isStreaming { HStack(spacing:5) { ForEach(0..<3) { _ in Circle().fill(Color.sage.opacity(0.5)).frame(width:4,height:4) } }.accessibilityLabel("正在生成") }
                if let word = message.word {
                    HStack(spacing: 22) { VStack(alignment: .leading, spacing: 7) { Text(word.pinyin).font(.system(size: 18)); Text(word.hanzi).font(.system(size: 34, weight: .bold, design: .rounded)).tracking(4) }; Spacer(); Text(word.english).font(.system(size: 23, weight: .medium, design: .rounded)) }.padding(19).toyCard(.mint, Color.sage.opacity(0.3), radius: 18)
                }
            }.padding(.horizontal, 18).padding(.vertical, 15).frame(maxWidth: preferredWidth, alignment: .leading).toyCard(message.isUser ? .peach.opacity(0.6) : .white, message.isUser ? .peachEdge : .lilacEdge.opacity(0.65), radius: 20)
            if !message.isUser { Spacer(minLength: 40) }
        }.frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}
