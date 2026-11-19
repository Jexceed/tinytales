import Foundation
import CryptoKit
import ImageIO
import os

struct GeneratedArtwork { var data: Data; var caption: String; var source: Story? = nil; var fileExtension = "png" }
struct IllustrationRequest {
    var text: String
    var story: Story?
    var dialogue: [[String: String]] = []
    var progress: (@MainActor (String) -> Void)?
    var referenceData: [String: Any] {
        ["request": text, "currentStory": story.map { ["title": $0.title, "summary": $0.summary] } ?? [:], "recentDialogue": dialogue]
    }
    static func dialogue(from history: [[String: Any]]) -> [[String: String]] {
        Array(history.suffix(12)).compactMap { row in
            guard let role = row["role"] as? String, ["user", "assistant"].contains(role), let text = row["content"] as? String else { return nil }
            return ["role": role, "text": String(text.suffix(2500))]
        }
    }
}
struct StoryArtwork: Codable, Equatable {
    var id = UUID().uuidString
    var storyID: String
    var title: String
    var storyText: String
    var caption: String = ""
    var fileExtension = "png"
    var storyHash: String { SHA256.hash(data:Data(storyText.utf8)).map { String(format:"%02x",$0) }.joined() }
    func url(in directory: URL) -> URL { directory.appendingPathComponent(id + (fileExtension == "jpg" ? ".jpg" : ".png")) }
    var url: URL { url(in:ArtworkArchive.directory) }
}
extension StoryArtwork {
    enum CodingKeys: String, CodingKey { case id, storyID, title, storyText, caption, fileExtension }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); storyID = try c.decode(String.self, forKey: .storyID)
        title = try c.decode(String.self, forKey: .title); storyText = try c.decode(String.self, forKey: .storyText)
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension) ?? "png"
    }
}
enum ArtworkArchive {
    // Production keeps its managed directory. Test executables and isolated
    // launch fixtures replace this before constructing any model or store.
    static var directory: URL = AppResources.supportDirectory.appendingPathComponent("artwork",isDirectory:true)
    private static let writes = OSAllocatedUnfairLock(initialState:UInt64(0))
    static var revision: UInt64 { writes.withLock { $0 } }
    static func savedAt(_ art: StoryArtwork) -> Date? {
        try? art.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    static func save(_ artwork: StoryArtwork, data: Data) throws {
        guard UUID(uuidString:artwork.id) != nil else { throw PartnerError.message("配图记录不可用。") }
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil), image.width > 0, image.height > 0, image.width <= 4096, image.height <= 4096 else { throw PartnerError.message("这张画没有生成完整，请再试一次。") }
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw PartnerError.message("故事配图目录不可用。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:artwork.url,options:.atomic)
        try JSONEncoder().encode(artwork).write(to:directory.appendingPathComponent(artwork.id+".json"),options:.atomic)
        writes.withLock { $0 &+= 1 }
    }
    static func remove(_ artwork: StoryArtwork) {
        guard UUID(uuidString:artwork.id) != nil else { return }
        let removedImage = (try? FileManager.default.removeItem(at:artwork.url)) != nil
        let removedRecord = (try? FileManager.default.removeItem(at:directory.appendingPathComponent(artwork.id+".json"))) != nil
        if removedImage || removedRecord { writes.withLock { $0 &+= 1 } }
    }
    static func clear(storyID: String? = nil, keepingIDs: Set<String> = []) {
        guard directory.path == directory.resolvingSymlinksInPath().path else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension == "json" {
            guard let data=try? Data(contentsOf:file),let art=try? JSONDecoder().decode(StoryArtwork.self,from:data),!keepingIDs.contains(art.id),storyID == nil || art.storyID == storyID else {continue}
            remove(art)
        }
    }
}

/// A read-only index of archived image files. Live conversations own their pictures through their messages.
struct ArtworkThumbnailIndex: Sendable {
    struct Version: Equatable, Sendable {
        let directory: URL
        let modified: Date
        let fileNumber: UInt64?
        let appRevision: UInt64

        init?(_ directory: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath:directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.directory = directory
            self.modified = modified
            self.fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            self.appRevision = ArtworkArchive.revision
        }
    }
    private struct Entry: Sendable {
        let url: URL
        let modified: Date
    }
    private var entries: [String:[Entry]] = [:]

    static func load(from directory: URL) -> Self {
        var index = Self()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard directory.path == directory.resolvingSymlinksInPath().path,
              let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(keys)) else { return index }
        for file in files where file.pathExtension == "json" {
            if Task.isCancelled { return Self() }
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString:id) != nil, let metadata = try? file.resourceValues(forKeys:keys),
                  metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let data = try? Data(contentsOf:file), let art = try? JSONDecoder().decode(StoryArtwork.self,from:data),
                  art.id == id else { continue }
            let url = art.url(in:directory)
            guard let image = try? url.resourceValues(forKeys:keys), image.isRegularFile == true,
                  image.isSymbolicLink != true, let date = image.contentModificationDate else { continue }
            index.entries[art.storyID,default:[]].append(Entry(url:url, modified:date))
        }
        for id in index.entries.keys {
            index.entries[id]?.sort { $0.modified == $1.modified ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified > $1.modified }
        }
        return index
    }
    func cover(for storyID:String, savedBy cutoff:Date = .distantFuture) -> URL? {
        entries[storyID]?.first { $0.modified <= cutoff && FileManager.default.fileExists(atPath:$0.url.path) }?.url
    }
}
enum PictureRequest: Equatable {
    case unspecified, discussion, storytelling, drawing, gallery(Scene?)

    var allowsDrawing: Bool { self == .drawing || self == .unspecified }
    var allowsGallery: Bool { self != .drawing && self != .discussion }

    init(_ text: String) {
        let story = Safety.matches(text, "故事的起点|我们一起编|[讲编].{0,12}故事|接着讲|接着编")
        let observation = Safety.matches(text, "(?:图|画)(?:片|面)?[里中上]|这[幅张]画里")
        self = story ? .storytelling : .unspecified
        // Work from left to right so an explicit correction supersedes its rejected subject.
        for part in text.components(separatedBy:CharacterSet(charactersIn:"，,。！？!?；;\n")) {
            let clause = part.trimmingCharacters(in:.whitespaces)
            guard !clause.isEmpty else { continue }
            let discussing = Safety.matches(clause, "(?:这个词|这句话)(?:是)?(?:什么意思|怎么读|怎么说)|你(?:会不会|会|能不能|能|喜欢)画(?:画|图)?(?:吗|么|嘛|$)|(?:画画|画图|插画)(?:是什么|是什么意思|好玩吗)|什么是(?:画画|画图|插画)|我(?:喜欢|学|正在|在)画画|教我.{0,5}画|我(?:在|正在|喜欢)看.{0,8}(?:插画|图画)书")
            let declining = Safety.matches(clause, "(?:不要|不用|别|不想|不需要|不愿意|不看|不画).{0,24}(?:画|绘|图|素材)|(?:图|画).{0,12}(?:不想看|不要看|不看了)|不(?:看|画)(?:《|了|$)")
            if discussing || declining { self = .discussion; continue }

            let scene = Scene.named(in:clause) ?? (observation ? Scene.observationScene(in:clause) : nil)
            let choosing = Safety.matches(clause, "看|打开|展示|换成|换一|改成|给我.{0,4}找")
            let library = Safety.matches(clause, "图库|图片库|素材")
            let redrawing = Safety.matches(clause, "重新画|再画|生成|画出来|请(?:你|帮我|给我)?画|(?:帮我|给我|你来)画")
            if choosing && (library || scene != nil) && !redrawing { self = .gallery(scene); continue }
            let asksAssistant = Safety.matches(clause, "(?:给我|帮我|请你|你能|你来|你|我要你).{0,15}(?:画|绘)|把.{0,35}故事.{0,10}画出来")
            if story && !asksAssistant { continue }
            if asksAssistant || Safety.matches(clause, "^(?:请|再|现在|开始)?(?:画图|出图|绘制)|生成.{0,10}图|(?:想|要|给我|让我们).{0,5}看.{0,35}(?:图|画)|画出来|画一下|配[一张幅些]*图|^(?:请|再|请你|帮我|给我)?画(?:出|[一张幅个只])|把.{0,35}画") {
                self = .drawing
            }
        }
    }
}
enum StoryIntent {
    static func startsNewStory(_ text:String)->Bool {
        !Safety.matches(text,"不[要用想].{0,4}新故事") && Safety.matches(text,"(?:开始|编|讲|来).{0,6}(?:全新|新的|新故事)|换.{0,12}故事(?:吧|。|！|$|，|,)|重新编")
    }
    static func illustration(_ text: String) -> Bool { PictureRequest(text) == .drawing }
    static func narrative(_ text: String) -> Bool { !Safety.matches(text,"不[要用].{0,6}[编讲].{0,6}故事|不[编讲]故事|不要故事") && !illustration(text) && Safety.matches(text,"讲.{0,24}故事|编.{0,24}故事|继续.{0,35}故事|接着讲|接着编") }
    static func continuesActiveStory(_ text: String, previous: Story?) -> Bool {
        guard let previous else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let picture = PictureRequest(trimmed)
        if picture == .drawing { return false }
        if case .gallery = picture { return false }
        guard !Safety.matches(trimmed, "不[要用想].{0,6}[编讲听].{0,6}故事|不[编讲听]故事|不要故事|休息一下|不想听了"),
              !VoiceTurnPolicy.isControlOnly(trimmed),
              ClassicalKnowledge.exactMatches(trimmed).isEmpty,
              !Safety.matches(trimmed, "现实|真的原因|科学|为什么|怎么读|怎么拼|什么意思|用英语|英文怎么|照片|背.{0,6}(?:古诗|诗)|讲.{0,6}成语|我今天在(?:学校|幼儿园|家里)") else { return false }
        let words = VoiceTurns.normalized(trimmed)
        if ["继续","继续吧","然后呢","后来呢","往下讲","接下来呢"].contains(words) { return true }
        if Safety.matches(words,"^(?:请|你)?(?:接着讲|接着编|继续讲|继续编|改叫|改成)|^(?:我希望|我想让)(?:它|这[颗只条座个]|主角)") { return true }
        let choice = ["我们一起让","我们就让","我们让","我想让","我想把","我选","让","叫","给","请","把"].first { words.hasPrefix($0) }
        if words.hasPrefix("我") && choice == nil { return false }
        let subject = choice.map { String(words.dropFirst($0.count)) } ?? words
        guard choice != nil || Safety.matches(subject,"去|要|拿|用|把|给|想|决定|找|带|走|跑|改叫|改成|不是") else { return false }
        if let first=subject.first, "它他她".contains(first) { return true }
        let context = previous.title + previous.summary
        // Match the proposed subject against the book, not a common verb later in the sentence.
        let prefix = String(subject.prefix(2))
        return prefix.count == 2 && context.contains(prefix)
    }
}
@MainActor final class StorySession {
    var current: Story?
    var currentPictureID:String?
    func reset() { current = nil;currentPictureID=nil }
}
protocol StoryIllustratingModel: PartnerModel {
    func illustrate(_ request: IllustrationRequest) async throws -> GeneratedArtwork
}
extension StoryIllustratingModel {
    func illustrate(_ story: Story) async throws -> GeneratedArtwork { try await illustrate(IllustrationRequest(text: "画出这个故事", story: story)) }
}
