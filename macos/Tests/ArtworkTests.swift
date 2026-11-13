import Foundation
import AppKit

func artworkFixtureData(jpeg: Bool = false) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:24,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    for y in 0..<24 { for x in 0..<32 { bitmap.setColor(.orange,atX:x,y:y) } }
    return bitmap.representation(using:jpeg ? .jpeg : .png,properties:[:])!
}
func artworkResponse(_ value: [String: Any]) throws -> [String: Any] {
    ["status":"completed", "output":[["type":"message","content":[["type":"output_text","text":try jsonString(value)]]]]]
}
let trainArtworkPlan: [String: Any] = ["ready":true,"sameStory":false,"title":"唱歌的小火车","source":"一辆红色小火车唱着歌经过小桥，桥下是明亮平静的河水。","scene":"One small red steam train with a smiling face crossing one stone bridge above a calm reflective river, warm morning light."]

@MainActor func artworkTestCases() -> [(String, @MainActor () async throws -> Void)] {
    [
        ("AI-001 colloquial drawing requests are recognized without confusing fictional actions", {
            for text in ["我说你画图吧，还是我要看一张图。","你画图吧","不要画小兔，画一辆红色小火车","画个小火车","生成一张图","我想看一张小火车的图片","把刚才的小火车画出来","我要看一张图"] {
                try expect(StoryIntent.illustration(text),"missed request: " + text)
            }
            for text in ["不要画图，继续讲","我喜欢画画","教我怎么画小兔","我们一起编一个故事，小兔画一张小地图。","给纸船再画个朋友，然后接着讲故事。","我想看图库里的《森林里的小种子》这张图片。"] {
                try expect(!StoryIntent.illustration(text),"false drawing request: " + text)
            }
        }),
        ("AI-001 model-selected drawing is not restricted to local keyword matches", {
            let store=try fixture();defer{remove(store)}
            let fake=FakeIllustrator([tools([call("illustrate_story")])])
            let engine=CompanionEngine(store:store,model:fake)
            let result=try await engine.turn("整一张会唱歌的小火车的画给我瞧瞧")
            guard let art=result.artwork else {throw PartnerError.message("TEST: semantic drawing was blocked")};defer{ArtworkArchive.remove(art)}
            try expect(fake.illustrationRequests.count == 1 && fake.inputs.count == 1,"model tool path failed or needed a redundant reply")
        }),
        ("AI-002 typed drawing uses recent dialogue without requiring a saved story", {
            let store = try fixture(); defer { remove(store) }
            let fake = FakeIllustrator([]), engine = CompanionEngine(store:store,model:fake)
            engine.seedHistory([["role":"user","content":"会唱歌的小火车"],["role":"assistant","content":"小火车唱着歌，稳稳走过小桥，桥下的水像镜子。"]])
            let result = try await engine.turn("我说你画图吧，还是我要看一张图。")
            guard let art = result.artwork else { throw PartnerError.message("TEST: missing art") }; defer { ArtworkArchive.remove(art) }
            try expect(fake.illustrationRequests.count == 1 && fake.inputs.isEmpty,"drawing depended on an extra chat completion")
            try expect(fake.illustrationRequests[0].dialogue.contains { $0["text"]?.contains("像镜子") == true },"lost recent scene")
            try expect(try store.stories().isEmpty,"drawing required an invented story archive")
        }),
        ("AI-003 a new subject supersedes an unrelated story and only resolved artwork metadata is stored", {
            let png = try artworkFixtureData(), old = Story(title:"小兔",summary:"小兔在森林捡萝卜。")
            var planningInput = ""
            let client = OpenAIClient(key:"fixture",testTransport:{path,body in
                if path == "images/generations" { return ["data":[["b64_json":png.base64EncodedString()]]] }
                if (body["input"] as? String) != nil { planningInput = body["input"] as? String ?? ""; return try artworkResponse(trainArtworkPlan) }
                return try artworkResponse(["matches":true,"duplicated_character":false,"caption":"红色小火车正在过桥。"])
            })
            let generated = try await client.illustrate(IllustrationRequest(text:"不要画刚才的小兔，画一辆红色小火车",story:old))
            try expect(planningInput.contains("红色小火车") && planningInput.contains("currentStory"),"resolver lost source precedence")
            try expect(generated.source?.id != old.id && generated.source?.summary.contains("小火车") == true && generated.source?.summary.contains("小兔") == false,"old world persisted in new art")
        }),
        ("AI-003 no subject produces a short clarification without generating a fabricated image", {
            var images = 0
            let client = OpenAIClient(key:"fixture",testTransport:{path,_ in
                if path == "images/generations" { images += 1 }
                return try artworkResponse(["ready":false,"sameStory":false,"title":"","source":"","scene":""])
            })
            do { _ = try await client.illustrate(IllustrationRequest(text:"画刚才那个",story:nil)); throw PartnerError.message("TEST: fabricated subject") }
            catch { try expect(!error.localizedDescription.contains("TEST:") && !error.localizedDescription.contains("保存"),"wrong clarification") }
            try expect(images == 0,"paid image request without subject")
        }),
        ("AI-004 duplicate tool calls reuse the same generation and cancellation publishes nothing", {
            let store = try fixture(); defer { remove(store) }
            let fake = FakeIllustrator([])
            let toolkit = try PartnerTools(store:store,text:"画一辆小火车",illustrator:{try await fake.illustrate($0)})
            _ = try await toolkit.perform(name:"illustrate_story",args:[:])
            let first = toolkit.selectedArtwork
            _ = try await toolkit.perform(name:"illustrate_story",args:[:])
            try expect(fake.illustrationRequests.count == 1 && toolkit.selectedArtwork == first,"duplicate generation")
            fake.illustrationDelay = 1_000_000_000
            let pending = try PartnerTools(store:store,text:"画一只小猫",illustrator:{try await fake.illustrate($0)})
            let task = Task { try await pending.perform(name:"illustrate_story",args:[:]) }
            try await Task.sleep(nanoseconds:20_000_000); task.cancel()
            do { _ = try await task.value; throw PartnerError.message("TEST: cancellation ignored") }
            catch { try expect(error is CancellationError,"cancellation not propagated") }
            try expect(pending.selectedArtwork == nil,"cancelled art was selected")
        }),
        ("AI-005 JPEG artwork is decodable and legacy PNG metadata still opens", {
            let bytes = try artworkFixtureData(jpeg:true)
            let art = StoryArtwork(storyID:"fixture",title:"小火车",storyText:"小火车过桥",caption:"小火车过桥。",fileExtension:"jpg")
            try ArtworkArchive.save(art,data:bytes); defer { ArtworkArchive.remove(art) }
            try expect(art.url.pathExtension == "jpg" && NSImage(contentsOf:art.url) != nil,"JPEG did not render")
            let old = try JSONDecoder().decode(StoryArtwork.self,from:JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"storyID":"old","title":"旧画","storyText":"旧画内容","caption":"旧画"] ))
            try expect(old.url.pathExtension == "png","old picture migration failed")
        }),
        ("AI-006 generation uses refined settings and repairs a concrete mismatch only once", {
            let bytes = try artworkFixtureData(jpeg:true)
            var imageBodies:[[String:Any]] = [],reviews=0
            let client = OpenAIClient(key:"fixture",testTransport:{path,body in
                if path == "images/generations" { imageBodies.append(body);return ["data":[["b64_json":bytes.base64EncodedString()]]] }
                if body["input"] is String { return try artworkResponse(trainArtworkPlan) }
                reviews += 1
                return try artworkResponse(["matches":reviews > 1,"duplicated_character":reviews == 1,"caption":reviews == 1 ? "同一辆小火车被重复画了两次，只保留一辆。" : "小火车在桥上。"])
            })
            let art = try await client.illustrate(IllustrationRequest(text:"画小火车",story:nil))
            try expect(imageBodies.count == 2 && reviews == 2 && art.fileExtension == "jpg","repair or JPEG failed")
            try expect(imageBodies[1]["size"] as? String == "1536x1024" && imageBodies[1]["output_compression"] as? Int == 90,"wrong quality profile")
            try expect((imageBodies[1]["prompt"] as? String)?.contains("只保留一辆") == true,"repair omitted concrete issue")
        }),
        ("AI-006 commentary and repeated JSON use the final valid structured result", {
            let first = try jsonString(["ready":false,"scene":"old {scene}"])
            let last = try jsonString(trainArtworkPlan)
            let parsed = try artworkObject(first + "\nDraft correction outside JSON.\n```json\n" + last + "\n```")
            try expect(parsed["ready"] as? Bool == true && parsed["title"] as? String == "唱歌的小火车","used commentary or obsolete object")
            do {_ = try artworkObject("not an object");throw PartnerError.message("TEST: non JSON accepted")}
            catch {try expect(!error.localizedDescription.contains("TEST:"),"invalid JSON accepted")}
        }),
        ("AI-006 repeated mismatch and malformed images fail without false success", {
            let bytes = try artworkFixtureData();var images=0
            let client = OpenAIClient(key:"fixture",testTransport:{path,body in
                if path == "images/generations" {images += 1;return ["data":[["b64_json":bytes.base64EncodedString()]]]}
                if body["input"] is String {return try artworkResponse(trainArtworkPlan)}
                return try artworkResponse(["matches":false,"duplicated_character":true,"caption":"小火车重复出现。"])
            })
            do {_ = try await client.illustrate(IllustrationRequest(text:"画小火车",story:nil));throw PartnerError.message("TEST: invalid art published")}
            catch {try expect(!error.localizedDescription.contains("TEST:"),"wrong image accepted")}
            try expect(images == 2,"unbounded paid retry")
        }),
        ("AI-007 progress is visible before a slow render and remains cancellable", {
            var progress:[String]=[],renderStarted=false
            let client = OpenAIClient(key:"fixture",testTransport:{path,_ in
                if path == "images/generations" {renderStarted=true;try expect(!progress.isEmpty,"no progress before rendering");try await Task.sleep(nanoseconds:2_000_000_000)}
                return try artworkResponse(trainArtworkPlan)
            })
            let task = Task {try await client.illustrate(IllustrationRequest(text:"画小火车",story:nil,progress:{progress.append($0)}))}
            for _ in 0..<100 {if renderStarted {break};try await Task.sleep(nanoseconds:1_000_000)}
            task.cancel()
            do {_ = try await task.value;throw PartnerError.message("TEST: ignored cancellation")}
            catch {try expect(error is CancellationError,"slow render cancellation failed")}
            try expect(renderStarted,"did not enter renderer")
        })
    ]
}
