import Foundation

struct PartnerToolResult {
    var output: Any
    var image: Data?
}

/// Shared domain tools for typed dialogue and a continuous voice call.
@MainActor final class PartnerTools {
    let store: LocalStore
    let settings: PartnerSettings
    let image: (String) throws -> Data?
    var text: String
    var stagedMemories: [Memory] = []
    var stagedStories: [Story] = []
    var selectedScene: String?
    var selectedWord: WordCard?
    var activities: [String] = []
    var selectedStory: String?
    let session: StorySession
    let illustrator: ((IllustrationRequest) async throws -> GeneratedArtwork)?
    let recentDialogue: [[String: String]]
    var onActivity: ((String) -> Void)?
    var selectedNarrative: Story?
    var selectedArtwork: StoryArtwork?
    var artworkCaption: String?
    private var artworkData: Data?
    private var pendingNarrative: Story?
    var preparedNarrative:Story? {pendingNarrative}
    init(store: LocalStore, text: String, activeStory: String? = nil, session: StorySession? = nil, history: [[String: Any]] = [], illustrator: ((IllustrationRequest) async throws -> GeneratedArtwork)? = nil, image: @escaping (String) throws -> Data? = { id in
        guard let scene = Scene.all.first(where: { $0.id == id }), let url = scene.visionURL else { return nil }
        return try Data(contentsOf: url)
    }) throws {
        self.store = store; settings = try store.settings(); self.text = text; self.image = image
        self.session = session ?? StorySession(); self.illustrator = illustrator
        recentDialogue = IllustrationRequest.dialogue(from: history)
        selectedStory = self.session.current?.id ?? activeStory; selectedNarrative = self.session.current
    }
    func execute(name: String, args: [String: Any]) throws -> PartnerToolResult {
        var result: Any = ["error": "unknown_tool"]
        var outputImage: Data?
        switch name {
        case "recall_memories":
            result = settings.memoryEnabled ? try store.memories().filter { $0.status == "approved" }.map { ["kind": $0.kind, "text": $0.text] } : []
            activities.append("翻了翻记忆小花园")
        case "find_stories":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let all = try store.stories().filter { $0.source == "cloud" }
            let found = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
            result = Array(found.prefix(5)).map { ["id": $0.id, "title": $0.title, "summary": $0.summary] }
            activities.append("找了找我们没讲完的故事")
        case "read_story":
            let id = args["id"] as? String ?? ""
            if let story = (stagedStories + (try store.stories())).first(where: { $0.id == id && $0.source == "cloud" }) {
                let exact = session.current?.id == story.id ? session.current! : story
                result = ["id": exact.id, "title": exact.title, "summary": exact.summary]; selectedStory = exact.id; selectedNarrative = exact
            } else { result = ["error": "story_not_found"] }
            activities.append("打开了故事本")
        case "show_picture":
            if let wanted=Scene.requested(in:text),args["id"] as? String != wanted.id {return PartnerToolResult(output:["error":"wrong_named_picture","requested_id":wanted.id,"requested_title":wanted.title],image:nil)}
            if let selectedScene, args["id"] as? String != selectedScene {return PartnerToolResult(output:["error":"picture_already_shown","shown":selectedScene],image:nil)}
            guard !StoryIntent.illustration(text), selectedNarrative == nil || StoryIntent.explicitGallery(text) || args["id"] as? String == session.currentPictureID || args["id"] as? String == Scene.requested(in:text)?.id else {
                return PartnerToolResult(output:["error":"use_illustrate_story", "reason":"这是固定图库，不能冒充当前故事的配图。请调用illustrate_story。"],image:nil)
            }
            if let id = args["id"] as? String, let scene = Scene.all.first(where: { $0.id == id }) {
                outputImage = try image(id)
                guard let outputImage, !outputImage.isEmpty else { throw PartnerError.message("这幅画还没有找到，请稍后再试。") }
                result = ["shown": id, "title": scene.title, "description": scene.description]; selectedScene = id
                if session.currentPictureID != id {selectedNarrative=nil;selectedStory=nil}
                activities.append("找来了一幅适合的小画")
            } else { throw PartnerError.message("莉莉只能打开小屋里准备好的图片。") }
        case "save_story":
            guard let title = args["title"] as? String, let summary = args["summary"] as? String, let fictional = args["fictional"] as? Bool, fictional else { throw PartnerError.message("只有虚构的故事情节可以收进故事本。") }
            let givenID = args["id"] as? String
            if let id = givenID, !(try store.stories()).contains(where: { $0.id == id && $0.source == "cloud" }) && !stagedStories.contains(where: { $0.id == id }) { throw PartnerError.message("这个故事本已经不在这里了。") }
            guard !title.isEmpty, title.count <= 35, !summary.isEmpty, summary.count <= 5000, !Safety.isPrivate(title + summary), !Safety.isRisk(title + summary) else { throw PartnerError.message("故事里有些内容暂时不适合保存。") }
            let story = Story(id: givenID ?? UUID().uuidString, title: title, summary: summary)
            stagedStories.removeAll { $0.id == story.id }; stagedStories.append(story)
            result = ["id": story.id, "saved_after_reply_review": true]; activities.append("给故事夹上了一张小书签")
        case "propose_memory":
            guard let kind = args["kind"] as? String, ["interest", "word", "english"].contains(kind), let fact = args["text"] as? String, let evidence = args["evidence"] as? String, Safety.mayRemember(fact), Safety.mayRemember(evidence) else { throw PartnerError.message("这条记忆里有不适合保存的信息。") }
            if settings.memoryEnabled {
                // Evidence must be from the current user utterance, not model invention.
                guard text.contains(evidence) else { throw PartnerError.message("这条记忆还没有足够的原话依据，先不保存。") }
                stagedMemories.append(Memory(kind: kind, text: fact, evidence: evidence))
            }
            result = ["status": settings.memoryEnabled ? "pending_parent_confirmation" : "memory_disabled"]; activities.append("留下一条记忆，等大人确认")
        case "show_word":
            guard let hanzi = args["hanzi"] as? String, let pinyin = args["pinyin"] as? String, let english = args["english"] as? String, hanzi.count <= 10, pinyin.count <= 80, english.count <= 80, !Safety.isPrivate(hanzi + english), !Safety.isRisk(hanzi + english) else { throw PartnerError.message("这个小词还没有准备好。") }
            selectedWord = WordCard(hanzi: hanzi, pinyin: pinyin, english: english); result = ["shown": true]; activities.append("写下一个故事里的小词")
        default: throw PartnerError.message("这个工具不属于莉莉的故事屋。")
        }
        return PartnerToolResult(output: result, image: outputImage)
    }
    func perform(name: String, args: [String:Any]) async throws -> PartnerToolResult {
        guard name == "illustrate_story" else { return try execute(name:name,args:args) }
        guard !StoryIntent.excludesDrawing(text) else {return PartnerToolResult(output:["error":"no_illustration_requested","reason":"用户没有要求实际生成图片。请回应本轮聊天或故事请求。"],image:nil)}
        if let art = selectedArtwork, let data = artworkData { return PartnerToolResult(output:["title":art.title,"caption":artworkCaption ?? ""],image:data) }
        guard let illustrator else { throw PartnerError.message("画画暂时没有连上，请稍后再试。") }
        let request = IllustrationRequest(text: text, story: selectedNarrative ?? session.current, dialogue: recentDialogue, progress: { [weak self] value in self?.onActivity?(value) })
        onActivity?("莉莉在选画面…")
        let generated = try await illustrator(request)
        try Task.checkCancellation()
        guard let story = generated.source ?? request.story else { throw PartnerError.message("你想画什么呀？告诉莉莉一个主角就可以。") }
        selectedArtwork = StoryArtwork(storyID:story.id,title:story.title,storyText:story.summary,caption:generated.caption,fileExtension:generated.fileExtension)
        artworkData = generated.data; artworkCaption = generated.caption
        activities.append("画出了《\(story.title)》")
        return PartnerToolResult(output:["title":story.title,"source_story":story.summary,"verified_caption":generated.caption,"story_id":story.id],image:generated.data)
    }
    func prepareCheckpoint(_ reply: PartnerReply) {
        guard selectedArtwork == nil, selectedScene == nil || (reply.classificationPresent && reply.narrative), !StoryIntent.illustration(text),
              reply.narrative || (!reply.classificationPresent && (!stagedStories.isEmpty || StoryIntent.narrative(text))),
              !Safety.isPrivate(reply.reply), !Safety.isRisk(reply.reply) else { return }
        let title = String((!reply.storyTitle.isEmpty ? reply.storyTitle : stagedStories.last?.title ?? selectedNarrative?.title ?? "新的小冒险").prefix(35))
        let id = stagedStories.last?.id ?? selectedNarrative?.id ?? UUID().uuidString
        let startsAnother = stagedStories.last.map { $0.id != selectedNarrative?.id } ?? false
        let previous = startsAnother ? "" : (selectedNarrative?.summary ?? "")
        let combined = previous.isEmpty || previous.contains(reply.reply) ? (previous.isEmpty ? reply.reply : previous) : previous + "\n" + reply.reply
        let canonical = reply.storyState.trimmingCharacters(in:.whitespacesAndNewlines)
        // Structured state replaces the old draft, so corrections do not coexist with obsolete facts.
        let narrative = !canonical.isEmpty && canonical.count <= 3000 && !Safety.isPrivate(canonical) && !Safety.isRisk(canonical) ? (canonical.contains(reply.reply) ? canonical : canonical + "\n刚刚讲到：" + reply.reply) : String(combined.suffix(4500))
        pendingNarrative = Story(id:id,title:title,summary:narrative)
        stagedStories.removeAll { $0.id == id }; stagedStories.append(pendingNarrative!)
    }
    func commit(expectedRevision: Int) throws {
        try Task.checkCancellation()
        guard store.revision == expectedRevision else { throw PartnerError.message("本机记忆已更新，请继续新的对话。") }
        do {
            if let art = selectedArtwork, let data = artworkData { try ArtworkArchive.save(art,data:data) }
            try store.transaction {
                if settings.memoryEnabled { for memory in stagedMemories { try store.remember(memory) } }
                for story in stagedStories { try store.saveStory(story) }
            }
        } catch { if let art = selectedArtwork { ArtworkArchive.remove(art) }; throw error }
        if let selectedScene {session.currentPictureID=selectedScene;if pendingNarrative == nil {session.current=nil}}
        if let narrative = pendingNarrative { session.current = narrative }
        else if let selectedNarrative, selectedArtwork == nil, selectedScene == nil { session.current = selectedNarrative }
    }
}
