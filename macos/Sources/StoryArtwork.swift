import Foundation
import CryptoKit
import ImageIO

struct GeneratedArtwork { var data: Data; var caption: String }
struct StoryArtwork: Codable, Equatable {
    var id = UUID().uuidString
    var storyID: String
    var title: String
    var storyText: String
    var caption: String = ""
    var storyHash: String { SHA256.hash(data:Data(storyText.utf8)).map { String(format:"%02x",$0) }.joined() }
    var url: URL { ArtworkArchive.directory.appendingPathComponent(id + ".png") }
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
        let storyRequest = Safety.matches(text,"故事的起点|我们一起编|[讲编].{0,12}故事|接着讲|接着编")
        let asksAssistant = Safety.matches(text,"(?:给我|帮我|请你|你能|你来).{0,15}(?:画|绘)|把.{0,35}故事.{0,10}画出来")
        if Scene.requested(in:text) != nil && !asksAssistant && !Safety.matches(text,"重新画|再画|画出来") {return false}
        if storyRequest && !asksAssistant {return false}
        return Safety.matches(text,"画出来|画一下|配[一张幅些]*图|绘制|插画|^(?:请|请你|帮我|给我)?画(?:出|[一张幅个])|(?:给我|帮我|请你|你能|你来).{0,15}(?:画|绘)|把.{0,35}画")
    }
    static func explicitGallery(_ text: String) -> Bool { Safety.matches(text,"(?:看|看看|展示|打开).{0,12}(?:雨天|下雨|夜空|花园|森林|海底|海獭|星空|独角兽|晚安|小熊|小兔|素材|图库|图片库)") }
    static func narrative(_ text: String) -> Bool { !Safety.matches(text,"不[要用].{0,6}[编讲].{0,6}故事|不[编讲]故事|不要故事") && !illustration(text) && Safety.matches(text,"讲.{0,8}故事|编.{0,10}故事|继续.{0,35}故事|接着讲|接着编") }
}
@MainActor final class StorySession {
    var current: Story?
    var currentPictureID:String?
    func reset() { current = nil;currentPictureID=nil }
}
protocol StoryIllustratingModel: PartnerModel {
    func illustrate(_ story: Story) async throws -> GeneratedArtwork
}
