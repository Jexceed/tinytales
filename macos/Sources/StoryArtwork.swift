import Foundation
import CryptoKit
import ImageIO

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
    var url: URL { ArtworkArchive.directory.appendingPathComponent(id + (fileExtension == "jpg" ? ".jpg" : ".png")) }
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
    static func save(_ artwork: StoryArtwork, data: Data) throws {
        guard UUID(uuidString:artwork.id) != nil else { throw PartnerError.message("配图记录不可用。") }
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil), image.width > 0, image.height > 0, image.width <= 4096, image.height <= 4096 else { throw PartnerError.message("这张画没有生成完整，请再试一次。") }
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw PartnerError.message("故事配图目录不可用。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:artwork.url,options:.atomic)
        try JSONEncoder().encode(artwork).write(to:directory.appendingPathComponent(artwork.id+".json"),options:.atomic)
    }
    static func remove(_ artwork: StoryArtwork) { guard UUID(uuidString:artwork.id) != nil else { return }; try? FileManager.default.removeItem(at:artwork.url);try? FileManager.default.removeItem(at:directory.appendingPathComponent(artwork.id+".json")) }
    static func clear(storyID: String? = nil, keepingIDs: Set<String> = []) {
        guard directory.path == directory.resolvingSymlinksInPath().path else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension == "json" {
            guard let data=try? Data(contentsOf:file),let art=try? JSONDecoder().decode(StoryArtwork.self,from:data),!keepingIDs.contains(art.id),storyID == nil || art.storyID == storyID else {continue}
            remove(art)
        }
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
    static func narrative(_ text: String) -> Bool { !Safety.matches(text,"不[要用].{0,6}[编讲].{0,6}故事|不[编讲]故事|不要故事") && !illustration(text) && Safety.matches(text,"讲.{0,8}故事|编.{0,10}故事|继续.{0,35}故事|接着讲|接着编") }
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
