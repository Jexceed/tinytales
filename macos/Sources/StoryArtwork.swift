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
    static var directory: URL { AppResources.supportDirectory.appendingPathComponent("artwork",isDirectory:true) }
    static func save(_ artwork: StoryArtwork, data: Data) throws {
        guard UUID(uuidString:artwork.id) != nil else { throw PartnerError.message("配图记录不可用。") }
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil), image.width > 0, image.height > 0, image.width <= 4096, image.height <= 4096 else { throw PartnerError.message("这张画没有生成完整，请再试一次。") }
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw PartnerError.message("故事配图目录不可用。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:artwork.url,options:.atomic)
        try JSONEncoder().encode(artwork).write(to:directory.appendingPathComponent(artwork.id+".json"),options:.atomic)
    }
    static func remove(_ artwork: StoryArtwork) { guard UUID(uuidString:artwork.id) != nil else { return }; try? FileManager.default.removeItem(at:artwork.url);try? FileManager.default.removeItem(at:directory.appendingPathComponent(artwork.id+".json")) }
    static func clear(storyID: String? = nil) {
        guard directory.path == directory.resolvingSymlinksInPath().path else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension == "json" {
            guard let data=try? Data(contentsOf:file),let art=try? JSONDecoder().decode(StoryArtwork.self,from:data),storyID == nil || art.storyID == storyID else {continue}
            remove(art)
        }
    }
}
enum StoryIntent {
    static func startsNewStory(_ text:String)->Bool {
        !Safety.matches(text,"不[要用想].{0,4}新故事") && Safety.matches(text,"(?:开始|编|讲|来).{0,6}(?:全新|新的|新故事)|换.{0,12}故事(?:吧|。|！|$|，|,)|重新编")
    }
    static func illustration(_ text: String) -> Bool {
        if Safety.matches(text,"图库|素材"), !Safety.matches(text,"重新画|再画|生成|画出来") { return false }
        if Safety.matches(text,"(?:不要|不用|别|不想|不需要).{0,3}(?:画|绘|生成.{0,3}图)|我(?:喜欢|学|正在|在)画画|教我.{0,5}画") {
            let tail = text.components(separatedBy:CharacterSet(charactersIn:"，,；;")).last ?? text
            return tail != text && illustration(tail)
        }
        let storyRequest = Safety.matches(text,"故事的起点|我们一起编|[讲编].{0,12}故事|接着讲|接着编")
        let asksAssistant = Safety.matches(text,"(?:给我|帮我|请你|你能|你来|你|我要你).{0,15}(?:画|绘)|把.{0,35}故事.{0,10}画出来")
        if Scene.requested(in:text) != nil && !asksAssistant && !Safety.matches(text,"重新画|再画|画出来") {return false}
        if storyRequest && !asksAssistant {return false}
        return Safety.matches(text,"画图|出图|生成.{0,10}(?:图片|图画|图)|(?:想|要|给我|让我们).{0,5}看.{0,35}(?:图|画)|画出来|画一下|配[一张幅些]*图|绘制|插画|^(?:请|请你|帮我|给我)?画(?:出|[一张幅个只])|(?:给我|帮我|请你|你能|你来|你).{0,15}(?:画|绘)|把.{0,35}画")
    }
    static func explicitGallery(_ text: String) -> Bool { Safety.matches(text,"(?:看|看看|展示|打开).{0,12}(?:雨天|下雨|夜空|花园|森林|海底|海獭|星空|独角兽|晚安|小熊|小兔|素材|图库|图片库)") }
    static func excludesDrawing(_ text: String) -> Bool {
        !illustration(text) && Safety.matches(text,"(?:不要|不用|别|不想|不需要).{0,3}(?:画|绘|生成.{0,3}图)|我(?:喜欢|学|正在|在)画画|教我.{0,5}画|故事的起点|我们一起编|[讲编].{0,12}故事|接着讲|接着编")
    }
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
