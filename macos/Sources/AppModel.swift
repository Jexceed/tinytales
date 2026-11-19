import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor private final class ConversationRuntime {
    let session=StorySession()
    var engine:CompanionEngine?
    var work:Task<Void,Never>?
    var requestID=UUID()
    var streamingID:UUID?
    var openedArchive: (storyID:String, openedAt:Date, cover:URL?)?
}

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var selectedConversationID=UUID().uuidString
    @Published private(set) var conversationTitle="莉莉"
    @Published private(set) var conversationUpdatedAt:Date?
    // A new composer is not a sidebar record until a user message is sent.
    @Published private(set) var isConversationStarted=false
    @Published private var conversationCache:[String:ConversationSnapshot]=[:]
    private var runtimeConversationIDs:[String]=[]
    // Sidebar position and view identity do not change when a bookmark is opened.
    private var sidebarOrder:[String]=[]
    private var sidebarNavigationID=""
    private var associatedStoryIDs:Set<String>=[]
    private var linkedStoryID:String?
    private var conversationRevision=0
    private var pendingNewDraft=""
    @Published var messages: [ChatMessage] = []
    @Published var isCorrectingVoice=false
    @Published var voiceCorrectionText=""
    private var voiceCorrectionWasMuted=false
    private var voiceControlWork:Task<Void,Never>?
    private var voiceConversationStates:[String:(title:String,linkedStoryID:String?,associatedStoryIDs:Set<String>)]=[:]
    @Published var stories: [Story] = []
    @Published var memories: [Memory] = []
    @Published var settings = PartnerSettings()
    @Published var draft = ""
    @Published var choosingStory = false
    @Published var browsing = false
    @Published private(set) var entryOrigin = ConversationEntry.text
    @Published private(set) var openingConsumed = false
    @Published var selectedStarter:StoryStarter?
    @Published var storyDirection = ""
    @Published var busy = false
    @Published var activity = ""
    @Published var error = ""
    @Published var showParent = false
    @Published var requestParent = false
    @Published var cloudAvailable = false
    @Published var operations = 0
    @Published private(set) var phone: RealtimeCall?
    @Published private var startingCall = false
    let voice = NativeVoice()
    private var teacherSpeech:TeacherSpeechClient?
    let store: LocalStore
    private var conversationRuntimes:[String:ConversationRuntime]=[:]
    private func runtime(for id:String) -> ConversationRuntime {
        if let existing=conversationRuntimes[id] {return existing}
        let created=ConversationRuntime();conversationRuntimes[id]=created;return created
    }
    var storySession:StorySession {runtime(for:selectedConversationID).session}
    private let keyProvider: () -> String?
    private let modelFactory: (String) -> PartnerModel
    private let callFactory: ((LocalStore,String,String,StorySession)->RealtimeCall)?
    private let now: () -> Date
    private let replySpeaker:((String)->Void)?
    private let loadArtworkIndex: @Sendable (URL) -> ArtworkThumbnailIndex
    @Published private var archiveIndex = ArtworkThumbnailIndex()
    private var archiveVersion: ArtworkThumbnailIndex.Version?
    private var archiveLoad: Task<Void,Never>?
    private var celebrations = ArtworkCelebrations()
    private var authorizedKey: String?
    private var connectionKey: String? { authorizedKey }
    private var engine:CompanionEngine? {conversationRuntimes[selectedConversationID]?.engine}
    private var callWork: Task<Void, Never>?
    private var phoneObserver: AnyCancellable?
    private var generation = UUID()
    private var priorStoryDraft = ""
    private var priorBrowsing = true
    var showsOpeningOptions:Bool {
        !openingConsumed && entryOrigin == .text && !inCall && !busy && !messages.contains { $0.source != "welcome" }
    }
    func chooseOpening(_ choice:OpeningPrompt) {
        guard showsOpeningOptions else{return}
        preparePrompt(choice.text)
    }
    func enterVoiceConversation() {
        if choosingStory {cancelStory()}
        browsing=false;entryOrigin = .voice;openingConsumed=true
        selectedStarter=nil;storyDirection=""
    }
    private func enterTextConversation() {browsing=false;entryOrigin = .text;openingConsumed=true}
    var pendingCount: Int { memories.filter { $0.status == "pending" }.count }
    var shouldOpenMainWindowOnLaunch: Bool { !settings.desktopPetEnabled || !settings.launchInPetMode || !cloudAvailable }
    var canStopOnPet: Bool { inCall ? (phone?.canStopCurrentTurn == true) : (voice.speaking || voice.preparing || busy) }
    func stopFromPet() {
        if inCall { stopVoiceTurn() }
        else if busy { cancel() }
        else { voice.stopSpeaking() }
    }
    var petCallSubtitle: (text: String, isWarning: Bool)? {
        guard inCall, let phone else { return nil }
        if phone.inputNeedsCorrection {
            return (phone.listeningHint.isEmpty ? "这句没听清，再说一次吧" : phone.listeningHint, true)
        }
        if !phone.inputTranscript.isEmpty {
            return ((phone.inputPreviewIsFinal ? "你说：" : "暂时听到：") + phone.inputTranscript, false)
        }
        if !phone.artworkStatus.isEmpty { return nil }
        if !phone.listeningHint.isEmpty, phone.state != .speaking {
            return (phone.listeningHint, false)
        }
        return nil
    }
    var latestAssistantVisualMessage: ChatMessage? {
        messages.last(where: { !$0.isUser && !$0.isRetracted && $0.source != "welcome" })
    }
    var quickChatScene: Scene? {
        guard let id = latestAssistantVisualMessage?.sceneID else { return nil }
        return Scene.all.first { $0.id == id }
    }
    var quickChatWord: WordCard? { latestAssistantVisualMessage?.word }
    var activeSuggestions: [String] {
        guard !busy, !inCall, let last = messages.last, !last.isUser, !last.isStreaming, !last.isRetracted else { return [] }
        return last.suggestions
    }
    func chooseSuggestion(_ suggestion: String) {
        let text = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !inCall else { return }
        if cloudAvailable { send(text) } else { preparePrompt(text) }
    }
    var inCall: Bool { startingCall || phone?.active == true }
    var connectingCall: Bool { startingCall || phone?.state == .connecting }
    var holdingCallDraft: Bool { connectingCall || phone?.windingDown == true }
    var callCaption: String {
        if connectingCall { return "正在接通…" }
        guard let phone, phone.active else { return "打个电话，直接聊聊" }
        if phone.muted { return "麦克风已静音" }
        switch phone.state { case .connecting: return "正在接通…"; case .listening: return "已接通，想说什么就说吧"; case .thinking: return "莉莉正在想一想…"; case .speaking: return "莉莉正在说，你也可以接话"; case .ended: return "通话已结束" }
    }
    init(store: LocalStore, keyProvider: @escaping () -> String? = Credentials.load, modelFactory: @escaping (String) -> PartnerModel = { OpenAIClient(key: $0) }, callFactory: ((LocalStore,String,String,StorySession)->RealtimeCall)? = nil, now: @escaping () -> Date = Date.init, loadArtworkIndex: @escaping @Sendable (URL) -> ArtworkThumbnailIndex = { ArtworkThumbnailIndex.load(from:$0) }, replySpeaker:((String)->Void)? = nil) {
        self.store = store; self.keyProvider = keyProvider; self.modelFactory = modelFactory; self.callFactory=callFactory
        self.now=now
        self.replySpeaker=replySpeaker
        self.loadArtworkIndex=loadArtworkIndex
        authorizedKey = keyProvider()
        cloudAvailable = connectionKey != nil
        refresh(); newConversation()
    }
    func refresh() {
        do { stories = try store.stories().filter { $0.source == "cloud" }; memories = try store.memories(); settings = try store.settings(); operations = try store.usage().operations; rememberSidebarPositions() }
        catch { self.error = error.localizedDescription }
        refreshArchivedThumbnails()
    }
    deinit { archiveLoad?.cancel() }
    private func refreshArchivedThumbnails() {
        let version = stories.isEmpty ? nil : ArtworkThumbnailIndex.Version(ArtworkArchive.directory)
        guard version != archiveVersion else { return }
        archiveLoad?.cancel()
        if archiveVersion?.directory != version?.directory { archiveIndex = ArtworkThumbnailIndex() }
        archiveVersion = version
        guard let version else { archiveLoad=nil; return }
        let load = loadArtworkIndex
        archiveLoad = Task.detached(priority:.utility) { [weak self] in
            let index = load(version.directory)
            guard !Task.isCancelled else { return }
            await self?.receiveArtworkIndex(index,version:version)
        }
    }
    private func receiveArtworkIndex(_ index:ArtworkThumbnailIndex, version:ArtworkThumbnailIndex.Version) {
        guard !Task.isCancelled, archiveVersion == version else { return }
        guard ArtworkThumbnailIndex.Version(ArtworkArchive.directory) == version else { refreshArchivedThumbnails(); return }
        archiveIndex=index
        archiveLoad=nil
    }
    /// Only a persisted archive row looks up a book-wide cover. Two live conversations can share a book.
    func thumbnailURL(for item:ConversationItem) -> URL? {
        if let storyID=item.storyID, item.id == "archive:"+storyID { return archiveIndex.cover(for:storyID) }
        let history = item.id == selectedConversationID ? messages : conversationCache[item.id]?.messages ?? []
        var gallery: URL?
        for message in history.reversed() where !message.isRetracted {
            if let url=message.artwork?.url, FileManager.default.fileExists(atPath:url.path) { return url }
            if gallery == nil, let id=message.sceneID { gallery=Scene.all.first { $0.id==id }?.url }
        }
        if let gallery { return gallery }
        guard let opened=conversationRuntimes[item.id]?.openedArchive, opened.storyID==item.storyID else { return nil }
        if let url=opened.cover, FileManager.default.fileExists(atPath:url.path) { return url }
        return archiveIndex.cover(for:opened.storyID,savedBy:opened.openedAt)
    }
    /// Big "talk to Lily" entry on a blank conversation (spec 011 UI-007).
    var showsWelcomeTalkButton:Bool { !inCall && !busy && !isConversationStarted }
    /// Word cards read aloud outside calls only, so they never compete with the call audio (UI-011).
    var canReadWords:Bool { !inCall && !busy }
    func canReadWord(in message:ChatMessage) -> Bool {
        canReadWords && !message.isUser && !message.isStreaming && !message.isRetracted && message.word != nil
    }
    func readWord(in messageID:UUID) {
        guard let message=messages.first(where:{ $0.id==messageID }), canReadWord(in:message), let word=message.word else { return }
        voice.speak(word.readAloudText)
    }
    func beginArtworkCelebration(_ art:StoryArtwork, reduceMotion:Bool) -> Date? {
        celebrations.begin(id:art.id,savedAt:ArtworkArchive.savedAt(art),now:Date(),reduceMotion:reduceMotion)
    }
    private var history: [[String: Any]] {
        let eligible = messages.compactMap { message -> [String:Any]? in
            guard message.contextApproved, message.source != "welcome", !message.isRetracted,
                  !(message.isUser && Safety.shouldProtectUserInput(message.text)) else { return nil }
            let text = message.isInterrupted ? message.heardText ?? "" : message.isStreaming ? "" : message.text
            guard !text.isEmpty, text != "…" else { return nil }
            return ["role":message.isUser ? "user" : "assistant","content":text]
        }
        return Array(eligible.suffix(12))
    }
    private func rememberSidebarPositions() {
        let archiveIDs=stories.map{"archive:"+$0.id}
        var valid=Set(archiveIDs)
        if isConversationStarted {valid.insert(sidebarNavigationID)}
        for saved in conversationCache.values where saved.hasStarted {valid.insert(saved.navigationID ?? saved.id)}
        sidebarOrder.removeAll{!valid.contains($0)}
        for id in archiveIDs where !sidebarOrder.contains(id) {sidebarOrder.append(id)}
    }
    var conversations:[ConversationItem] {
        var items=runtimeConversationIDs.compactMap {id -> ConversationItem? in
            if id == selectedConversationID {return isConversationStarted ? ConversationItem(id:id,title:conversationTitle,storyID:linkedStoryID,rowID:sidebarNavigationID,updatedAt:conversationUpdatedAt,isGenerating:busy,hasError:!error.isEmpty) : nil}
            guard let saved=conversationCache[id],saved.hasStarted else{return nil}
            return ConversationItem(id:id,title:saved.title,storyID:saved.linkedStoryID,rowID:saved.navigationID,updatedAt:saved.updatedAt,isGenerating:saved.busy,hasUnreadReply:saved.hasUnreadReply,hasError:!saved.error.isEmpty)
        }
        if isConversationStarted && !items.contains(where:{$0.id == selectedConversationID}) {items.append(ConversationItem(id:selectedConversationID,title:conversationTitle,storyID:linkedStoryID,rowID:sidebarNavigationID,updatedAt:conversationUpdatedAt,isGenerating:busy,hasError:!error.isEmpty))}
        var represented=Set(items.compactMap(\.storyID))
        if isConversationStarted {represented.formUnion(associatedStoryIDs)}
        for saved in conversationCache.values where saved.hasStarted {represented.formUnion(saved.associatedStoryIDs)}
        items += stories.filter{!represented.contains($0.id)}.map{ConversationItem(id:"archive:"+$0.id,title:$0.conversationTitle,storyID:$0.id,updatedAt:$0.conversationUpdatedAt)}
        let ranks=Dictionary(sidebarOrder.enumerated().map{($0.element,$0.offset)},uniquingKeysWith:min)
        return items.sorted {
            let left=ranks[$0.navigationID] ?? Int.max,right=ranks[$1.navigationID] ?? Int.max
            return left == right ? $0.navigationID < $1.navigationID : left < right
        }
    }
    private func currentSnapshot() -> ConversationSnapshot {
        ConversationSnapshot(id:selectedConversationID,title:conversationTitle,messages:messages,draft:draft,entry:entryOrigin,openingConsumed:openingConsumed,story:storySession.current,pictureID:storySession.currentPictureID,linkedStoryID:linkedStoryID,hasStarted:isConversationStarted,navigationID:sidebarNavigationID,associatedStoryIDs:associatedStoryIDs,updatedAt:conversationUpdatedAt,busy:busy,activity:activity,error:error)
    }
    private func cacheCurrentConversation() {
        guard isConversationStarted else {
            pendingNewDraft=Safety.shouldProtectUserInput(draft) ? "" : draft
            conversationCache.removeValue(forKey:selectedConversationID);conversationRuntimes.removeValue(forKey:selectedConversationID);runtimeConversationIDs.removeAll{$0 == selectedConversationID};return
        }
        var snapshot=currentSnapshot()
        snapshot.messages.removeAll{$0.isUser && Safety.shouldProtectUserInput($0.text)}
        if Safety.shouldProtectUserInput(snapshot.draft) {snapshot.draft=""}
        conversationCache[selectedConversationID]=snapshot
    }
    /// Apply events to their owning conversation, irrespective of the visible row.
    private func updateConversation(_ id:String,_ change:(inout ConversationSnapshot)->Void) {
        if id == selectedConversationID {
            var snapshot=currentSnapshot();change(&snapshot)
            conversationTitle=snapshot.title;conversationUpdatedAt=snapshot.updatedAt
            linkedStoryID=snapshot.linkedStoryID;associatedStoryIDs=snapshot.associatedStoryIDs
            messages=snapshot.messages;draft=snapshot.draft;busy=snapshot.busy;activity=snapshot.activity;error=snapshot.error
        } else if var snapshot=conversationCache[id] {
            change(&snapshot);conversationCache[id]=snapshot
        }
    }
    private func configureEngine() {
        let context=runtime(for:selectedConversationID)
        guard context.engine == nil,let key=connectionKey else{return}
        let story=context.session.current,picture=context.session.currentPictureID
        context.engine=CompanionEngine(store:store,model:modelFactory(key),session:context.session)
        context.session.current=story;context.session.currentPictureID=picture
        context.engine?.seedHistory(history)
    }
    private func nameConversation(from text:String) {
        let clean=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard ConversationLabels.isPlaceholder(conversationTitle), !clean.isEmpty, !Safety.isPrivate(clean), !Safety.isRisk(clean), !Safety.shouldProtectUserInput(clean) else{return}
        conversationTitle=OpeningPrompt.allCases.first{$0.text == clean}?.title ?? String(clean.components(separatedBy:.newlines).first!.prefix(20))
    }
    func recordUserMessageSent(_ text:String,isVoice:Bool=false) {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        if !isConversationStarted {
            isConversationStarted=true;pendingNewDraft=""
            conversationTitle=isVoice ? "语音对话" : "新对话"
            if !runtimeConversationIDs.contains(selectedConversationID) {runtimeConversationIDs.insert(selectedConversationID,at:0)}
            if !sidebarOrder.contains(sidebarNavigationID) {sidebarOrder.insert(sidebarNavigationID,at:0)}
        }
        conversationUpdatedAt=now()
        nameConversation(from:text)
    }
    private func syncConversationStory() {
        guard isConversationStarted else{return}
        if let story=storySession.current {
            linkedStoryID=story.id;associatedStoryIDs.insert(story.id);conversationTitle=story.conversationTitle
            if let saved=story.conversationUpdatedAt {conversationUpdatedAt=max(conversationUpdatedAt ?? saved,saved)}
        }
    }
    func selectConversation(_ id:String) {
        guard !inCall else{return}
        if conversationRevision != store.revision {newConversation(forgettingHistory:true);refresh()}
        guard id != selectedConversationID else{return}
        if id.hasPrefix("archive:"),let existing=conversations.first(where:{$0.id != id && ($0.storyID == String(id.dropFirst(8)) || $0.navigationID == id)}) {selectConversation(existing.id);return}
        let target:ConversationSnapshot
        if let cached=conversationCache[id] {target=cached}
        else if let story=stories.first(where:{"archive:"+$0.id == id}) {
            target=ConversationSnapshot(id:UUID().uuidString,title:story.conversationTitle,messages:[ChatMessage(isUser:false,text:story.resumeText,source:"archive")],draft:"",entry:.text,openingConsumed:true,story:story,pictureID:nil,linkedStoryID:story.id,hasStarted:true,navigationID:id,associatedStoryIDs:[story.id],updatedAt:story.conversationUpdatedAt)
        } else {return}
        stopVoiceForNavigation();cacheCurrentConversation()
        selectedConversationID=target.id;conversationTitle=target.title;linkedStoryID=target.linkedStoryID;isConversationStarted=target.hasStarted
        conversationUpdatedAt=target.updatedAt
        sidebarNavigationID=target.navigationID ?? target.id;associatedStoryIDs=target.associatedStoryIDs
        if !runtimeConversationIDs.contains(target.id) {runtimeConversationIDs.append(target.id)}
        messages=target.messages;draft=target.draft;entryOrigin=target.entry;openingConsumed=target.openingConsumed
        browsing=false;choosingStory=false;selectedStarter=nil;storyDirection=""
        busy=target.busy;activity=target.activity;error=target.error
        if conversationRuntimes[target.id] == nil {
            let context=runtime(for:target.id)
            context.session.current=target.story;context.session.currentPictureID=target.pictureID
            if let storyID=target.linkedStoryID, id == "archive:"+storyID {
                context.openedArchive=(storyID,Date(),archiveIndex.cover(for:storyID))
            }
        }
        conversationCache[target.id]?.hasUnreadReply=false
        configureVoice();configureEngine()
        rememberSidebarPositions()
    }
    func deleteConversation(_ id:String) {
        guard let target=conversations.first(where:{$0.id == id || $0.navigationID == id}) else { return }
        let selected=target.id == selectedConversationID
        let cached=conversationCache[target.id]
        var storyIDs=selected ? associatedStoryIDs : cached?.associatedStoryIDs ?? []
        if let storyID=target.storyID {storyIDs.insert(storyID)}
        if let storyID=(selected ? storySession.current : cached?.story)?.id {storyIDs.insert(storyID)}
        if let storyID=conversationRuntimes[target.id]?.session.current?.id {storyIDs.insert(storyID)}
        let targetMessages=selected ? messages : cached?.messages ?? []
        var otherStoryIDs:Set<String>=[],otherArtworkIDs:Set<String>=[]
        for saved in conversationCache.values where saved.id != target.id && saved.id != selectedConversationID {
            otherStoryIDs.formUnion(saved.associatedStoryIDs)
            if let storyID=saved.linkedStoryID {otherStoryIDs.insert(storyID)}
            if let storyID=saved.story?.id {otherStoryIDs.insert(storyID)}
            otherArtworkIDs.formUnion(saved.messages.compactMap{$0.artwork?.id})
        }
        if !selected && isConversationStarted {
            otherStoryIDs.formUnion(associatedStoryIDs)
            if let linkedStoryID {otherStoryIDs.insert(linkedStoryID)}
            if let storyID=storySession.current?.id {otherStoryIDs.insert(storyID)}
            otherArtworkIDs.formUnion(messages.compactMap{$0.artwork?.id})
        }
        do {
            let removedStoryIDs=storyIDs.subtracting(otherStoryIDs)
            try store.deleteConversationStories(removedStoryIDs,preservingArtworkIDs:otherArtworkIDs)
            cancelRequest(in:target.id)
            for art in targetMessages.compactMap(\.artwork) where !otherArtworkIDs.contains(art.id) {ArtworkArchive.remove(art)}
            conversationCache.removeValue(forKey:target.id)
            conversationRuntimes.removeValue(forKey:target.id)
            runtimeConversationIDs.removeAll{$0 == target.id}
            sidebarOrder.removeAll{$0 == target.navigationID || ($0.hasPrefix("archive:") && removedStoryIDs.contains(String($0.dropFirst("archive:".count))))}
            if selected {
                // Mark it unstarted before cancellation callbacks can checkpoint it.
                isConversationStarted=false;draft=pendingNewDraft
                newConversation()
            }
            refresh()
        } catch { self.error=error.localizedDescription }
    }
    func newConversation(forgettingHistory:Bool=false) {
        stopVoiceForNavigation()
        if forgettingHistory || conversationRevision != store.revision {
            for context in conversationRuntimes.values {context.requestID=UUID();context.work?.cancel();context.engine?.interrupt()}
            conversationRuntimes.removeAll();conversationCache.removeAll();runtimeConversationIDs.removeAll();pendingNewDraft=""
        }
        else {cacheCurrentConversation()}
        conversationRevision=store.revision
        selectedConversationID=UUID().uuidString;sidebarNavigationID=selectedConversationID;associatedStoryIDs=[];conversationTitle="莉莉";linkedStoryID=nil;isConversationStarted=false
        conversationUpdatedAt=nil
        choosingStory=false;browsing=false;entryOrigin = .text;openingConsumed = !pendingNewDraft.isEmpty;selectedStarter=nil;storyDirection="";generation=UUID();error="";draft=pendingNewDraft;busy=false;activity=""
        messages=[ChatMessage(isUser:false,text:"你好，我是莉莉。想聊些什么？",source:"welcome")]
        configureVoice();cloudAvailable=connectionKey != nil;configureEngine();rememberSidebarPositions()
    }
    private func configureVoice() {
        if VoiceStyle.speaker(settings.voiceStyle) != nil,teacherSpeech==nil {teacherSpeech=TeacherSpeechClient.discover()}
        voice.teacherSpeech=teacherSpeech
        if let key = connectionKey {
            let client = OpenAIClient(key: key), style = VoiceStyle.cloudVoice(settings.voiceStyle)
            voice.cloudSpeech = { [weak self] text in
                guard let self else { throw CancellationError() }
                try self.store.recordCloudOperation()
                let narrator = RealtimeNarrator(wire:OpenAIRealtimeWire(key:key))
                let bytes: Data
                do { bytes = try await narrator.speak(text,voice:style) }
                catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation(); try self.store.recordCloudOperation(); bytes = try await client.speech(text,voice:style) }
                self.refresh(); return bytes
            }
        } else { voice.cloudSpeech = nil }
        voice.configure(backend: settings.voiceBackend, warm: false,style:settings.voiceStyle)
    }
    private func updateDraftReply(_ text:String,in id:String,context:ConversationRuntime) {
        updateConversation(id) { snapshot in
            if text.isEmpty {
                if let streamingID=context.streamingID {snapshot.messages.removeAll{$0.id == streamingID}}
                context.streamingID=nil
            } else if let streamingID=context.streamingID,let index=snapshot.messages.firstIndex(where:{$0.id == streamingID}) {
                snapshot.messages[index].text=text
            } else {
                var message=ChatMessage(isUser:false,text:text);message.isStreaming=true
                context.streamingID=message.id;snapshot.messages.append(message)
            }
        }
    }
    func beginStory() {
        if !choosingStory { priorStoryDraft = draft; priorBrowsing = browsing; draft = ""; selectedStarter = nil; storyDirection = "" }
        voice.stopSpeaking(); choosingStory = true; browsing = false; openingConsumed=true
    }
    func chooseStory(_ choice: StoryStarter) { selectedStarter = choice; storyDirection = ""; draft = choice.title }
    func openStory(_ choice:StoryStarter) { beginStory(); chooseStory(choice) }
    func chooseDirection(_ direction:String) { guard let selectedStarter else{return};storyDirection=direction;draft=selectedStarter.title + " · " + direction }
    func preparePrompt(_ text:String) { voice.stopSpeaking(); enterTextConversation(); draft=text }
    func cancelStory() { choosingStory = false; draft = priorStoryDraft; browsing = priorBrowsing; selectedStarter = nil; storyDirection = "" }

    private func stopVoiceForNavigation() {
        startingCall = false
        voiceControlWork?.cancel();voiceControlWork=nil;isCorrectingVoice=false;voiceCorrectionText=""
        voiceConversationStates=[:]
        voice.cancelRecording();voice.stopSpeaking()
        callWork?.cancel(); callWork = nil; phone?.hangUp()
        phoneObserver=nil;phone=nil;generation=UUID()
    }
    private func cancelRequest(in id:String) {
        guard let context=conversationRuntimes[id] else{return}
        context.requestID=UUID();context.work?.cancel();context.work=nil;context.engine?.interrupt()
        updateDraftReply("",in:id,context:context)
        updateConversation(id) {$0.busy=false;$0.activity=""}
    }
    func cancel() {
        cancelRequest(in:selectedConversationID)
        stopVoiceForNavigation()
    }
    func send(_ given: String? = nil) {
        let text = (given ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return }
        guard text.count <= 600 else { error = "这一段有点长，请分成几句慢慢说。"; return }
        if holdingCallDraft {
            if draft.isEmpty { draft = text }
            return
        }
        let startingStory = choosingStory
        let request:String
        if startingStory, let selectedStarter, text == selectedStarter.title || text == selectedStarter.title + " · " + storyDirection {
            request = selectedStarter.prompt + (storyDirection.isEmpty ? "" : "小朋友选择的方向是：" + storyDirection + "。请沿着这个选择展开。")
        } else { request = text }
        if startingStory && !inCall { newConversation() }
        if startingStory && inCall { self.engine?.reset() }
        enterTextConversation()
        configureEngine()
        guard cloudAvailable, let engine else { error = "先连接故事伙伴，连接完成后就能直接聊。"; showParent = true; return }
        if inCall, let phone {
            let id=selectedConversationID
            choosingStory=false; draft=""; error=""
            Task { [weak self] in
                do {
                    try await phone.sendText(request,newStory:startingStory) { [weak self] accepted in
                        guard let self, self.selectedConversationID==id, self.phone === phone else {return}
                        self.recordUserMessageSent(text)
                        self.messages.append(ChatMessage(isUser:true,text:text,contextApproved:accepted))
                    }
                } catch {
                    guard let self, self.phone === phone, self.selectedConversationID==id, !(error is CancellationError) else { return }
                    self.error = error.localizedDescription
                    if self.draft.isEmpty { self.draft=text }
                }
            }
            return
        }
        recordUserMessageSent(text)
        voice.stopSpeaking(); error = ""; draft = ""; busy = true; activity = "莉莉在认真听"
        choosingStory = false
        let message=ChatMessage(isUser:true,text:text,contextApproved:false),id=selectedConversationID,context=runtime(for:selectedConversationID)
        let requestID=UUID(),revision=store.revision
        context.requestID=requestID
        messages.append(message)
        engine.onActivity = { [weak self,weak context] value in
            guard let self,let context,self.conversationRuntimes[id] === context,context.requestID == requestID,self.store.revision == revision else{return}
            self.updateConversation(id) {$0.activity=value}
        }
        engine.onDraft = { [weak self,weak context] value in
            guard let self,let context,self.conversationRuntimes[id] === context,context.requestID == requestID,self.store.revision == revision else{return}
            self.updateDraftReply(value,in:id,context:context)
        }
        context.work = Task { [weak self,weak context] in
            do {
                let result = try await engine.turn(request, newStory: startingStory)
                try Task.checkCancellation()
                guard let self,let context,self.conversationRuntimes[id] === context,context.requestID == requestID else{return}
                guard self.store.revision == revision else {self.newConversation(forgettingHistory:true);self.refresh();return}
                self.updateConversation(id) { snapshot in
                    if let index = snapshot.messages.firstIndex(where:{ $0.id == message.id }) {
                        snapshot.messages[index].contextApproved = result.source != "safety"
                    }
                    if let streamingID=context.streamingID,let index=snapshot.messages.firstIndex(where:{$0.id == streamingID}) {
                        snapshot.messages[index].text=result.reply.reply;snapshot.messages[index].activities=result.activities
                        snapshot.messages[index].sceneID=result.sceneID;snapshot.messages[index].word=result.word;snapshot.messages[index].artwork=result.artwork
                        snapshot.messages[index].suggestions=result.reply.suggestions;snapshot.messages[index].source=result.source;snapshot.messages[index].isStreaming=false
                    } else {snapshot.messages.append(ChatMessage(isUser:false,text:result.reply.reply,activities:result.activities,sceneID:result.sceneID,word:result.word,source:result.source,artwork:result.artwork,suggestions:result.reply.suggestions))}
                    snapshot.story=context.session.current;snapshot.pictureID=context.session.currentPictureID
                    if let story=context.session.current {
                        snapshot.linkedStoryID=story.id;snapshot.associatedStoryIDs.insert(story.id);snapshot.title=story.conversationTitle
                        if let saved=story.conversationUpdatedAt {snapshot.updatedAt=max(snapshot.updatedAt ?? saved,saved)}
                    }
                    snapshot.busy=false;snapshot.activity="";snapshot.error="";snapshot.hasUnreadReply=self.selectedConversationID != id
                }
                context.streamingID=nil;context.work=nil;self.refresh()
                if self.selectedConversationID == id && !self.inCall && self.settings.speaks {
                    if let speaker=self.replySpeaker {speaker(result.reply.reply)} else {self.voice.speak(result.reply.reply)}
                }
            } catch {
                guard let self,let context,self.conversationRuntimes[id] === context,context.requestID == requestID else{return}
                guard self.store.revision == revision else {self.newConversation(forgettingHistory:true);self.refresh();return}
                self.updateDraftReply("",in:id,context:context);context.work=nil
                self.updateConversation(id) { snapshot in
                    snapshot.busy=false;snapshot.activity=""
                    if !(error is CancellationError) {
                        snapshot.error=error.localizedDescription
                        if snapshot.draft.isEmpty && (self.selectedConversationID == id || !Safety.shouldProtectUserInput(text)) {snapshot.draft=text}
                    }
                }
            }
        }
    }
    func toggleCall() {
        if inCall { startingCall = false; callWork?.cancel(); phone?.hangUp(); return }
        voiceConversationStates=[:]
        enterVoiceConversation()
        guard let key = connectionKey else { error = "先连接故事伙伴，之后点一次电话就能持续交流。"; showParent = true; return }
        cancelRequest(in:selectedConversationID);configureEngine();voice.shutdown();error=""
        let intentClient=OpenAIClient(key:key)
        intentClient.onVoiceIntentRequest={ [store] in try await MainActor.run{try store.recordCloudOperation()} }
        intentClient.onTranscriptionRequest={ [store] in try await MainActor.run{try store.recordCloudOperation()} }
        let call = callFactory?(store,key,settings.voiceStyle,storySession) ?? RealtimeCall(store: store, wire: OpenAIRealtimeWire(key: key,model:"gpt-realtime-2.1"), audio: NativeCallAudio(), voice: settings.voiceStyle, session: storySession, illustrator: { [store] story in
            let client = OpenAIClient(key:key)
            client.onArtworkRequest = { try await MainActor.run { try store.recordCloudOperation() } }
            return try await client.illustrate(story)
        },teacherSpeech:teacherSpeech,intentJudge:intentClient,finalRecognizer:intentClient,safetyJudge:intentClient)
        phone = call
        phoneObserver = call.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
        call.onStoryCheckpointAdjusted = { [weak self] in
            guard let self else { return }
            self.syncConversationStory(); self.refresh()
        }
        call.onUserText = { [weak self] item, text in
            guard let self else { return }
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
            if !self.messages.contains(where:{$0.externalID==item}) {
                self.voiceConversationStates[item]=(self.conversationTitle,self.linkedStoryID,self.associatedStoryIDs)
            }
            self.recordUserMessageSent(text,isVoice:true)
            if let index = self.messages.firstIndex(where: { $0.externalID == item }) { self.messages[index].text = text }
            else { self.messages.append(ChatMessage(isUser: true, text: text, externalID: item)) }
        }
        call.onAssistantDraft = { [weak self] item, text in
            guard let self else { return }
            if let index = self.messages.firstIndex(where: { $0.externalID == item }) { self.messages[index].text = text }
            else { var message = ChatMessage(isUser: false, text: text, externalID: item); message.isStreaming = true; self.messages.append(message) }
        }
        call.onAssistantInterrupted = { [weak self] item in
            guard let self, let index = self.messages.firstIndex(where: { $0.externalID == item }) else { return }; self.messages[index].isStreaming = false;self.messages[index].isInterrupted=true
        }
        call.onAssistantHeard = { [weak self] item,text in
            guard let self, let index = self.messages.firstIndex(where:{ $0.externalID == item }) else { return }
            self.messages[index].heardText = text
        }
        call.onVoiceInputRetracted = { [weak self] input,related in
            guard let self else{return}
            for index in self.messages.indices where self.messages[index].externalID==input || self.messages[index].externalID.map({related.contains($0)}) == true {
                self.messages[index].isRetracted=true;self.messages[index].isStreaming=false
            }
            if let prior=self.voiceConversationStates.removeValue(forKey:input) {
                self.conversationTitle=prior.title=="莉莉" ? "语音对话" : prior.title
                self.linkedStoryID=prior.linkedStoryID;self.associatedStoryIDs=prior.associatedStoryIDs
            }
            self.syncConversationStory();self.refresh()
        }
        call.onAssistantText = { [weak self] item, text, scene, word, actions in
            guard let self else { return }
            if let index = self.messages.firstIndex(where: { $0.externalID == item }) {
                self.messages[index].text = text; self.messages[index].activities = actions
                self.messages[index].sceneID = scene; self.messages[index].word = word; self.messages[index].isStreaming = false
            } else { self.messages.append(ChatMessage(isUser: false, text: text, activities: actions, sceneID: scene, word: word, externalID: item)) }
            self.syncConversationStory();self.refresh()
        }
        call.onArtwork = { [weak self] item, artwork in
            guard let self, let index = self.messages.firstIndex(where: { $0.externalID == item }) else { return }
            self.messages[index].artwork = artwork
        }
        call.onEnd = { [weak self, weak call] in
            guard let self else { return }
            for index in self.messages.indices {
                if self.messages[index].isStreaming {self.messages[index].isInterrupted=true}
                self.messages[index].isStreaming = false
            }
            if self.isCorrectingVoice {
                if self.draft.isEmpty {self.draft=self.voiceCorrectionText}
                self.isCorrectingVoice=false;self.voiceCorrectionText=""
            }
            self.engine?.seedHistory(self.history);self.syncConversationStory();self.refresh()
            if let notice = call?.notice, !notice.isEmpty { self.error = notice }
        }
        let prior = history
        startingCall = true
        callWork = Task {
            guard !Task.isCancelled, self.phone === call else { return }
            defer { if self.phone === call { self.startingCall = false } }
            do { try await call.connect(history:prior) }
            catch {
                guard self.phone === call, !(error is CancellationError) else { return }
                self.error = error.localizedDescription; call.hangUp()
            }
        }
    }
    func stopVoiceTurn() {
        guard let phone,inCall else{voice.stopSpeaking();return}
        voiceControlWork?.cancel()
        voiceControlWork=Task {await phone.stopCurrentTurn()}
    }
    func cancelVoiceInput() {
        guard let phone,inCall else{return}
        voiceControlWork?.cancel()
        voiceControlWork=Task {await phone.cancelPendingInput()}
    }
    func canCorrectVoice(_ message:ChatMessage)->Bool {
        inCall && message.isUser && !message.isRetracted && message.externalID != nil && message.externalID==phone?.latestVoiceInputID
    }
    func retryVoiceInput(_ messageID:String?=nil) {
        guard let phone,inCall else{return}
        let latest=messageID != nil && messageID==phone.latestVoiceInputID
        voiceControlWork?.cancel()
        voiceControlWork=Task {
            if latest {await phone.retractLatestVoiceInput()}
            else {await phone.cancelPendingInput()}
        }
    }
    func editVoiceInput(_ messageID:String?=nil) {
        guard let phone,inCall else{return}
        let latest=messageID != nil && messageID==phone.latestVoiceInputID
        let text=latest ? phone.latestVoiceInputText ?? "" : phone.inputTranscript
        let captured=generation
        voiceCorrectionWasMuted=phone.muted
        if !phone.muted {phone.toggleMute()}
        voiceControlWork?.cancel()
        voiceControlWork=Task {[weak self] in
            if latest {
                let retracted=await phone.retractLatestVoiceInput()
                guard retracted != nil else {
                    if !Task.isCancelled,let self,self.generation==captured,self.phone === phone {
                        self.error=phone.notice; self.cancelVoiceCorrection()
                    }
                    return
                }
            } else {await phone.stopCurrentTurn()}
            guard !Task.isCancelled,let self,self.generation==captured,self.phone === phone,phone.active else{return}
            self.voiceCorrectionText=text;self.isCorrectingVoice=true
        }
    }
    func cancelVoiceCorrection() {
        isCorrectingVoice=false;voiceCorrectionText=""
        if !voiceCorrectionWasMuted,phone?.muted==true {phone?.toggleMute()}
    }
    func sendVoiceCorrection() {
        let text=voiceCorrectionText.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.count<=600,inCall else{return}
        let savedDraft=draft
        cancelVoiceCorrection()
        if holdingCallDraft { draft=text; return }
        send(text);draft=savedDraft
    }
    func updateSettings(_ value: PartnerSettings) {
        do {
            let reset = settings.memoryEnabled != value.memoryEnabled || settings.english != value.english
            let voiceChanged = settings.voiceBackend != value.voiceBackend || settings.speaks != value.speaks || settings.voiceStyle != value.voiceStyle
            try store.setSettings(value); settings = value
            if reset { newConversation(forgettingHistory:true) }
            else if voiceChanged { voice.stopSpeaking(); configureVoice() }
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func updateMemory(_ memory: Memory) {
        do {
            let prior = memories.first { $0.id == memory.id }
            let isSimpleApproval = prior?.status == "pending" && memory.status == "approved" && prior?.text == memory.text && prior?.kind == memory.kind
            try store.editMemory(memory)
            if !isSimpleApproval { newConversation(forgettingHistory:true) }
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func removeMemory(_ memory: Memory) { do { try store.delete("memories", id: memory.id); newConversation(forgettingHistory:true); refresh() } catch { self.error = error.localizedDescription } }
    func deleteStory(_ story: Story) { do { try store.delete("stories", id: story.id); newConversation(forgettingHistory:true); refresh() } catch { self.error = error.localizedDescription } }
    func clearData() { do { try store.clear(); newConversation(forgettingHistory:true); refresh() } catch { self.error = error.localizedDescription } }
    func saveKey(_ key: String) throws { try Credentials.save(key); authorizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines); cloudAvailable = true; newConversation(forgettingHistory:true) }
    func reconnectSavedKey() { if let key = Credentials.authorizeSavedKey() { authorizedKey = key; newConversation(forgettingHistory:true); showParent = false } else { error = "还没有找到可用的连接配置，请填写后保存。" } }
    func forgetKey() throws { try Credentials.delete(); authorizedKey = keyProvider(); cloudAvailable = connectionKey != nil; newConversation(forgettingHistory:true) }
    func exportData() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "小小故事屋-本机数据.json"
        if panel.runModal() == .OK, let url = panel.url { do { try store.export().write(to: url, options: .atomic) } catch { self.error = error.localizedDescription } }
    }
}
