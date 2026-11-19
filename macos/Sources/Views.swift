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
                .overlay(RoundedRectangle(cornerRadius: radius).fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paneHeight:CGFloat = 600
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
                        if conversation.isEmpty || model.showsWelcomeTalkButton {
                            ConversationWelcome(model:model,compact:paneHeight < PlayfulLayout.compactWelcomeHeight).frame(maxWidth:.infinity).padding(.top,paneHeight < PlayfulLayout.compactWelcomeHeight ? 12 : 44).padding(.bottom,24).id("welcome")
                        }
                        ForEach(conversation) {message in
                            let isLatestAssistant = !message.isUser && message.id == conversation.last?.id
                            MessageView(
                                message:message,
                                onRead:message.isStreaming || model.inCall || message.isRetracted ? nil : { model.voice.speak(message.text) },
                                onEdit:model.canCorrectVoice(message) ? { model.editVoiceInput(message.externalID) } : nil,
                                onRetry:model.canCorrectVoice(message) ? { model.retryVoiceInput(message.externalID) } : nil,
                                onSelectSuggestion:isLatestAssistant && !model.busy && !model.inCall && !message.isStreaming && !message.isRetracted ? { model.chooseSuggestion($0) } : nil,
                                onReadWord:model.canReadWord(in:message) ? { model.readWord(in:message.id) } : nil,
                                beginArtworkCelebration:model.beginArtworkCelebration
                            )
                                .modifier(BubbleEntrance(isUser:message.isUser,createdAt:message.createdAt,reduceMotion:reduceMotion))
                                .id(message.id)
                        }
                        if (model.busy && !conversation.contains(where:{$0.isStreaming})) || !model.artworkActivity.isEmpty {
                            let waitText = !model.artworkActivity.isEmpty ? model.artworkActivity : model.activity.isEmpty ? "莉莉在想…" : model.activity
                            if !model.artworkActivity.isEmpty || PaintingStatus.isDrawing(model.activity) {PaintingBubble(text:waitText)}
                            else {ThinkingBubble(text:waitText)}
                        }
                        Color.clear.frame(height:1).id("end")
                    }.padding(.horizontal,28).padding(.vertical,20).frame(maxWidth:820).frame(maxWidth:.infinity)
                }
                .background(GeometryReader {geometry in Color.clear.onAppear {paneHeight=geometry.size.height}.onChange(of:geometry.size.height) {_,height in paneHeight=height}})
                .onChange(of:model.showsWelcomeTalkButton) { _,visible in
                    if visible { proxy.scrollTo("welcome",anchor:.top) }
                }
                .onChange(of:model.selectedConversationID) {_,_ in
                    if model.showsWelcomeTalkButton { proxy.scrollTo("welcome",anchor:.top) }
                    else { proxy.scrollTo("end",anchor:.bottom) }
                }
                .onChange(of:model.messages.count) {_,_ in if !model.showsWelcomeTalkButton { withAnimation {proxy.scrollTo("end",anchor:.bottom)} }}
                .onChange(of:model.messages.last?.text) {_,_ in if !model.showsWelcomeTalkButton { proxy.scrollTo("end",anchor:.bottom) }}
                .onChange(of:model.messages.last?.artwork?.id) {_,_ in if !model.showsWelcomeTalkButton { proxy.scrollTo("end",anchor:.bottom) }}
            }
            composer.frame(maxWidth:820).frame(maxWidth:.infinity)
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(StorySkyBackdrop())
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:9) {
                LilyAvatar(size:38)
                Text("小小故事屋").font(.system(size:19,weight:.bold,design:.rounded))
                    .foregroundStyle(LinearGradient(colors:[Color.sage,Color.lilyPink],startPoint:.leading,endPoint:.trailing))
            }.padding(.top,2).padding(.bottom,2)
            Button {model.newConversation()} label:{
                HStack(spacing:9) {
                    Image(systemName:"plus").font(.system(size:14,weight:.heavy)).frame(width:26,height:26).background(.white.opacity(0.28),in:Circle())
                    Text("新对话").font(.system(size:17,weight:.bold,design:.rounded))
                    Spacer(minLength:0)
                    Image(systemName:"sparkles").font(.system(size:14,weight:.semibold)).opacity(0.85)
                }.foregroundStyle(.white)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,11)
                    .background(lilyGradient,in:RoundedRectangle(cornerRadius:16))
                    .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(.white.opacity(0.35)))
                    .shadow(color:Color.sage.opacity(0.28),radius:7,x:0,y:4)
            }.buttonStyle(StoryButtonStyle()).hoverLift().disabled(model.inCall).opacity(model.inCall ? 0.5 : 1)
            VStack(alignment:.leading,spacing:9) {
                Text("会话").font(.system(size:15,weight:.semibold)).foregroundStyle(Color.quiet).padding(.horizontal,4)
                ScrollView {
                    VStack(spacing:4) {
                        ForEach(model.conversations,id:\.navigationID) {item in
                            let selected=model.selectedConversationID == item.id
                            let tint=PlayfulTint.badge(for:item.navigationID)
                            HStack(spacing:0) {
                                Button {model.selectConversation(item.id)} label:{
                                  HStack(alignment:.top,spacing:10) {
                                    let thumbnail=item.isGenerating || item.hasError ? nil : model.thumbnailURL(for:item).flatMap{ArtworkThumbnails.image(at:$0)}
                                    Group {
                                        if item.isGenerating {ProgressView().controlSize(.small)}
                                        else if item.hasError {Image(systemName:"exclamationmark").foregroundStyle(Color(red:0.72,green:0.35,blue:0.14))}
                                        else if let thumbnail {Image(nsImage:thumbnail).resizable().scaledToFill().frame(width:34,height:34).clipShape(Circle()).accessibilityHidden(true)}
                                        else {Image(systemName:item.storyID == nil ? "bubble.left.fill" : "book.closed.fill").foregroundStyle(tint.edge)}
                                    }.font(.system(size:13,weight:.bold)).frame(width:34,height:34)
                                        .background(Circle().fill(item.hasError ? Color.peach : tint.fill.opacity(selected ? 1 : 0.8)))
                                        .overlay(Circle().strokeBorder(thumbnail == nil ? Color.white.opacity(0.9) : tint.edge.opacity(0.8),lineWidth:thumbnail == nil ? 1.5 : 2))
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(item.title).font(.system(size:15,weight:selected ? .semibold : .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(ConversationLabels.timestamp(item.updatedAt)).font(.system(size:11)).monospacedDigit().foregroundStyle(Color.quiet)
                                            .lineLimit(1).minimumScaleFactor(0.9)
                                    }.padding(.top,1)
                                    Spacer(minLength:0)
                                  }.padding(.leading,9).padding(.trailing,3).padding(.vertical,9).frame(maxWidth:.infinity,alignment:.leading)
                                    .contentShape(RoundedRectangle(cornerRadius:14))
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
                                .background(selected ? Color.card : .clear,in:RoundedRectangle(cornerRadius:14))
                                .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(selected ? Color.sage.opacity(0.35) : .clear,lineWidth:1.2))
                                .shadow(color:selected ? Color.sage.opacity(0.14) : .clear,radius:6,x:0,y:3)
                                .overlay(alignment:.leading) {if selected {Capsule().fill(lilyGradient).frame(width:4,height:26).padding(.leading,1)}}
                                .contextMenu {Button(role:.destructive) {deletionCandidate=item} label:{Label("删除对话…",systemImage:"trash")}}
                        }
                    }
                }
            }.frame(maxHeight:.infinity,alignment:.top)
            Button {model.showParent=true} label:{
                HStack(spacing:8) {
                    Label("设置",systemImage:"gearshape").font(.system(size:15,weight:.medium)).foregroundStyle(Color.quiet)
                    if model.pendingCount > 0 {
                        Text("\(model.pendingCount)").font(.system(size:12,weight:.bold,design:.rounded)).foregroundStyle(.white).padding(.horizontal,6).padding(.vertical,2).background(Color.sage,in:Capsule())
                    }
                    Spacer(minLength:0)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(10)
            }.buttonStyle(.plain).accessibilityValue(model.pendingCount > 0 ? "\(model.pendingCount)条待确认记忆" : "")
        }.padding(16).frame(width:236).frame(maxHeight:.infinity,alignment:.top)
            .background(LinearGradient(colors:[Color(PlayfulSurfaces.sidebarTop),Color(PlayfulSurfaces.sidebarMiddle),Color(PlayfulSurfaces.sidebarBottom)],startPoint:.top,endPoint:.bottom))
    }
    private var header:some View {
        HStack(spacing:12) {
            LilyAvatar(size:44)
            if model.isConversationStarted {
                VStack(alignment:.leading,spacing:3) {
                    Text(model.conversationTitle).font(.system(size:20,weight:.semibold,design:.rounded)).lineLimit(1)
                    Text("莉莉 · AI伙伴").font(.system(size:12,weight:.medium)).foregroundStyle(Color.quiet)
                }
            } else {
                Text("莉莉").font(.system(size:22,weight:.semibold,design:.rounded))
                Text("AI伙伴").font(.system(size:12,weight:.semibold)).foregroundStyle(Color.sage).padding(.horizontal,9).padding(.vertical,4).background(Color.lilac.opacity(0.7),in:Capsule())
            }
            Spacer()
            if !model.cloudAvailable {Button("连接莉莉"){model.showParent=true}.buttonStyle(.borderedProminent).tint(Color.sage)}
        }.padding(.horizontal,24).padding(.vertical,12).background(Color(PlayfulSurfaces.header).opacity(0.85))
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
        LazyVGrid(columns:[GridItem(.flexible(),spacing:compact ? 10 : 14),GridItem(.flexible(),spacing:compact ? 10 : 14)],spacing:compact ? 10 : 14) {
            ForEach(OpeningPrompt.allCases) {choice in
                let tint=choice.tint
                Button {model.chooseOpening(choice)} label:{
                    HStack(spacing:compact ? 9 : 12) {
                        Image(systemName:choice.playfulIcon).font(.system(size:compact ? 14 : 19,weight:.bold)).foregroundStyle(.white)
                            .frame(width:compact ? 28 : 42,height:compact ? 28 : 42)
                            .background(Circle().fill(LinearGradient(colors:[tint.edge.opacity(0.8),tint.edge],startPoint:.top,endPoint:.bottom)))
                            .shadow(color:tint.edge.opacity(0.35),radius:3,x:0,y:2)
                        Text(choice.title).font(.system(size:compact ? 15 : 18,weight:.semibold,design:.rounded))
                        Spacer(minLength:0)
                    }
                        .foregroundStyle(Color.ink).padding(.horizontal,compact ? 10 : 13).frame(height:compact ? 44 : 64)
                        .background(RoundedRectangle(cornerRadius:compact ? 14 : 20).fill(LinearGradient(colors:[Color.card,tint.fill.opacity(0.75)],startPoint:.topLeading,endPoint:.bottomTrailing)))
                        .overlay(RoundedRectangle(cornerRadius:compact ? 14 : 20).strokeBorder(tint.edge.opacity(0.45),lineWidth:1.3))
                        .contentShape(RoundedRectangle(cornerRadius:compact ? 14 : 20))
                }.buttonStyle(StoryButtonStyle()).hoverLift()
            }
        }.accessibilityElement(children:.contain).accessibilityLabel("开场建议")
    }
}
struct ConversationWelcome:View {
    @ObservedObject var model:AppModel
    /// Short windows shrink the stage so the big talk button always stays above the fold.
    var compact=false
    var body:some View {
        let voice=model.entryOrigin == .voice
        let mode=model.callVisualMode
        VStack(spacing:compact ? 10 : 16) {
            LilyStageView(activity:model.inCall ? mode.stageActivity : .idle,level:model.inCall ? model.callVisualLevel : 0,halo:model.inCall ? mode.color : .lilacEdge,size:PlayfulLayout.stageSize(voice:voice,compact:compact),cheerOnAppear:CommandLine.arguments.contains("--verify-launch") && CommandLine.arguments.contains("--sample-lily-cheer"))
            GreetingBubble(title:PlayfulGreeting.title(hour:Calendar.current.component(.hour,from:Date()),voice:voice),subtitle:PlayfulGreeting.subtitle(voice:voice))
            if model.showsWelcomeTalkButton {WelcomeTalkButton(model:model).padding(.top,compact ? 2 : 8)}
            if model.showsOpeningOptions {OpeningOptions(model:model).frame(maxWidth:470).padding(.top,12)}
        }.frame(maxWidth:540)
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
                let hangup=Color(red:0.81,green:0.28,blue:0.35)
                HStack(spacing:9) {
                    Image(systemName:model.inCall ? "phone.down.fill" : "phone.fill").font(.system(size:19,weight:.semibold))
                    Text(model.inCall ? "挂断" : "打电话").font(.system(size:19,weight:.bold,design:.rounded))
                }.foregroundStyle(.white).frame(height:48).padding(.horizontal,18)
                    .background(model.inCall ? AnyShapeStyle(LinearGradient(colors:[Color(red:0.90,green:0.40,blue:0.45),hangup],startPoint:.top,endPoint:.bottom)) : AnyShapeStyle(lilyGradient),in:RoundedRectangle(cornerRadius:18))
                    .overlay(RoundedRectangle(cornerRadius:18).strokeBorder(.white.opacity(0.3)))
                    .shadow(color:(model.inCall ? hangup : Color.sage).opacity(0.32),radius:7,x:0,y:4)
            }
        }.buttonStyle(StoryButtonStyle()).help(model.inCall ? "挂断电话" : "给莉莉打电话")
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
                    } label:{Image(systemName:"plus").font(.system(size:17,weight:.bold)).foregroundStyle(Color.sage).frame(width:36,height:36)}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width:36,height:36).background(Circle().fill(Color.lilac.opacity(0.8))).help("更多对话动作")
                }
                TextField("写给莉莉…", text: $model.draft, axis: .vertical).textFieldStyle(.plain).font(.system(size: 18, design: .rounded)).lineLimit(1...3).focused($inputFocused).onSubmit { model.send() }.disabled(model.busy)
                if voice.speaking || voice.preparing { Button { voice.stopSpeaking() } label: { Label("停一下", systemImage: "speaker.slash.fill").font(.system(size: 17, weight: .medium)) }.buttonStyle(.plain) }
                if model.busy { Button("停一下") { model.cancel() }.font(.system(size: 18, weight: .semibold)).buttonStyle(.bordered) }
                else if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button { model.send() } label: { Image(systemName: "arrow.up").font(.system(size: 22, weight: .bold)).foregroundStyle(.white).frame(width: 48, height: 48).background(lilyGradient, in: Circle()).shadow(color: Color.sage.opacity(0.32), radius: 6, x: 0, y: 3) }.buttonStyle(StoryButtonStyle()).disabled(model.holdingCallDraft).help(model.phone?.windingDown == true ? "通话结束后可发送" : model.connectingCall ? "接通后发送" : "发送") }
                PhoneButton(model: model)
            }.padding(12).toyCard(.card, .lilacEdge.opacity(0.6), radius: 24)
                .shadow(color: Color.lilacEdge.opacity(0.18), radius: 12, x: 0, y: 5)
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
    var onSelectSuggestion: ((String) -> Void)? = nil
    var onReadWord: (() -> Void)? = nil
    var beginArtworkCelebration: ((StoryArtwork,Bool) -> Date?)? = nil
    @State private var celebrationStart: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var preferredWidth: CGFloat {
        if message.artwork != nil || message.sceneID != nil || message.word != nil || (onSelectSuggestion != nil && !message.suggestions.isEmpty) { return 600 }
        let font = NSFont.systemFont(ofSize: 18, weight: .medium)
        let lineWidth = message.text.components(separatedBy: .newlines).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(message.isUser ? 490 : 700, max(message.isUser ? (message.isRetracted ? 220 : 145) : 300, ceil(lineWidth) + 46))
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser { Spacer(minLength: 48) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    if message.isUser { ChildAvatar(size: 34) }
                    else { LilyAvatar(size: 34) }
                    Text(message.isUser ? "我说" : message.source == "archive" ? "上次讲到" : "莉莉说").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(message.isUser ? Color(red: 0.70, green: 0.38, blue: 0.16) : Color.sage)
                    Spacer()
                    if message.isRetracted {Text("已撤回").font(.system(size:13)).foregroundStyle(Color.quiet)}
                    else if message.isInterrupted {Text("已停止").font(.system(size:13)).foregroundStyle(Color.quiet)}
                    if !message.isUser, !message.isStreaming, let onRead { Button(action: onRead) { Label("再听", systemImage: "speaker.wave.2.fill").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Color.sage).padding(.horizontal, 12).padding(.vertical, 6).background(Color.lilac.opacity(0.75), in: Capsule()).overlay(Capsule().strokeBorder(Color.lilacEdge.opacity(0.5))) }.buttonStyle(StoryButtonStyle()).hoverLift() }
                }
                if let artwork = message.artwork, let image = NSImage(contentsOf:artwork.url) {
                    VStack(alignment:.leading,spacing:12) {
                        Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:520).clipShape(RoundedRectangle(cornerRadius:14))
                            .padding(8).background(Color.card,in:RoundedRectangle(cornerRadius:20))
                            .shadow(color:Color.ink.opacity(0.14),radius:10,x:0,y:5)
                            .overlay { if !reduceMotion, let celebrationStart { CelebrationBurst(start:celebrationStart) } }
                            .task(id:artwork.id) { celebrationStart=beginArtworkCelebration?(artwork,reduceMotion) }
                        Label("《\(artwork.title)》的配图",systemImage:"sparkles").font(.system(size:23,weight:.bold,design:.rounded)).labelStyle(PlayfulTitleLabel())
                    }
                }
                if let id = message.sceneID, let scene = Scene.all.first(where: { $0.id == id }), let url = scene.url, let image = NSImage(contentsOf: url) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: min(420, 240 * image.size.width / max(1, image.size.height))).clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(8).background(Color.card, in: RoundedRectangle(cornerRadius: 20))
                            .shadow(color: Color.ink.opacity(0.14), radius: 10, x: 0, y: 5)
                        Label("看图素材 · " + scene.title, systemImage: "photo.fill").font(.system(size: 23, weight: .bold, design: .rounded)).labelStyle(PlayfulTitleLabel())
                    }
                }
                Text(message.text).strikethrough(message.isRetracted).foregroundStyle(message.isRetracted ? Color.quiet : Color.ink).font(.system(size: 18, weight: .regular, design: .rounded)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if message.isStreaming { BouncingDots(color: .sage, size: 6).accessibilityElement().accessibilityLabel("正在生成") }
                if let word = message.word {
                    let card = HStack(spacing: 22) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(word.pinyin).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(Color.mintEdge)
                            Text(word.hanzi).font(.system(size: 40, weight: .heavy, design: .rounded)).tracking(5).foregroundStyle(Color.ink)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 10) {
                            if onReadWord != nil {
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 40, height: 40).background(Circle().fill(Color.mintEdge))
                            }
                            Text(word.english).font(.system(size: 23, weight: .semibold, design: .rounded)).foregroundStyle(Color.skyDeep)
                        }
                    }.padding(19)
                        .background(RoundedRectangle(cornerRadius: 20).fill(LinearGradient(colors: [Color.mint, Color.sky.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.mintEdge.opacity(0.45), lineWidth: 1.3))
                        .contentShape(RoundedRectangle(cornerRadius: 20))
                    if let onReadWord {
                        Button(action:onReadWord) { card }.buttonStyle(StoryButtonStyle()).hoverLift()
                            .help("读一读").accessibilityLabel("读一读，\(word.hanzi)")
                    } else { card }
                }
                if let onSelectSuggestion, !message.suggestions.isEmpty {
                    let chips = ForEach(Array(message.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        let tint = PlayfulTint.suggestions[index % PlayfulTint.suggestions.count]
                        Button { onSelectSuggestion(suggestion) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").font(.system(size: 13, weight: .bold)).foregroundStyle(tint.edge)
                                Text(suggestion).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Color.ink).lineLimit(1)
                            }.padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(LinearGradient(colors: [Color.card, tint.fill], startPoint: .top, endPoint: .bottom)))
                                .overlay(Capsule().strokeBorder(tint.edge.opacity(0.5), lineWidth: 1.2))
                        }.buttonStyle(StoryButtonStyle()).hoverLift().accessibilityLabel("后续建议，\(suggestion)")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { chips }
                        VStack(alignment: .leading, spacing: 8) { chips }
                    }.padding(.top, 2)
                }
            }.padding(.horizontal, 18).padding(.vertical, 15).frame(maxWidth: preferredWidth, alignment: .leading)
                .toyCard(message.isUser ? Color(PlayfulSurfaces.childBubble) : .card, message.isUser ? .peachEdge : .lilacEdge.opacity(0.65), radius: 22)
            // Voice corrections sit under the child's bubble as tidy chips instead of floating inside it.
            if onEdit != nil || onRetry != nil {
                HStack(spacing: 5) {
                    if let onRetry { VoiceFixChip(title: VoiceFixLabels.retry, symbol: "arrow.counterclockwise", emphasis: .primary, action: onRetry) }
                    if let onEdit { VoiceFixChip(title: VoiceFixLabels.edit, symbol: "pencil", emphasis: .secondary, action: onEdit) }
                }.padding(.trailing, 4)
            }
            }
            if !message.isUser { Spacer(minLength: 40) }
        }.frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}
struct PlayfulTitleLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.icon.foregroundStyle(Color.lemonEdge).font(.system(size: 19, weight: .bold)); configuration.title }
    }
}
