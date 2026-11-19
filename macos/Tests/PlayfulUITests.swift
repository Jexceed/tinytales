import Foundation
import ImageIO

/// Hold the first snapshot until a newer, real directory scan has completed.
private final class ThumbnailLoadProbe: @unchecked Sendable {
    private let lock=NSLock()
    private let firstScan=DispatchSemaphore(value:0)
    private var count=0
    private var returnedFirst=false
    private var usedMain=false
    var readings: (count:Int, returnedFirst:Bool, usedMain:Bool) {
        lock.withLock { (count,returnedFirst,usedMain) }
    }
    func releaseFirst() { firstScan.signal() }
    func load(_ root:URL) -> ArtworkThumbnailIndex {
        let snapshot=ArtworkThumbnailIndex.load(from:root)
        let first = lock.withLock {
            count += 1
            usedMain = usedMain || Thread.isMainThread
            return count == 1
        }
        if first {
            if !Thread.isMainThread { _ = firstScan.wait(timeout:.now()+5) }
            lock.withLock { returnedFirst=true }
        }
        return snapshot
    }
}

@MainActor func playfulUITestCases() -> [(String,@MainActor () async throws -> Void)] {
    [
        ("UI-014 shared books keep archive, foreground and background thumbnails independent", {
            let store=try fixture();defer{remove(store)}
            let story=Story(title:"蓝船",summary:"小兔坐在一艘蓝船上。")
            try store.saveStory(story)
            var settings=try store.settings();settings.speaks=false;try store.setSettings(settings)
            let cover=StoryArtwork(storyID:story.id,title:"原书封面",storyText:story.summary)
            try ArtworkArchive.save(cover,data:artworkFixtureData());defer{ArtworkArchive.remove(cover)}
            let read=tools([call("read_story",["id":story.id])])
            let answer=modern("蓝船的书签在这里。",narrative:false)
            let model=FakeIllustrator([read,answer,read,answer])
            let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in model})
            let archive=app.conversations[0]
            try await backgroundWait{app.thumbnailURL(for:archive)==cover.url}
            app.selectConversation(archive.id)
            let opened=app.selectedConversationID
            app.newConversation();app.send("请找回蓝船的书签");try await backgroundWait{!app.busy}
            let b=app.selectedConversationID
            guard let rowB=app.conversations.first(where:{$0.id==b}) else {throw PartnerError.message("TEST: missing B")}
            try expect(rowB.storyID==story.id && app.thumbnailURL(for:rowB)==nil,"a fresh conversation borrowed the archive cover")
            app.send("请画出刚才的故事");try await backgroundWait{!app.busy}
            guard let art=app.messages.last?.artwork else {throw PartnerError.message("TEST: B has no picture")}
            defer{ArtworkArchive.remove(art)}
            app.newConversation();app.send("再找找那本蓝船的书签");try await backgroundWait{!app.busy}
            guard let rowA=app.conversations.first(where:{$0.id==opened}),let rowC=app.conversations.first(where:{$0.id==app.selectedConversationID}) else {throw PartnerError.message("TEST: missing shared rows")}
            try expect(app.thumbnailURL(for:rowA)==cover.url && app.thumbnailURL(for:rowB)==art.url && app.thumbnailURL(for:rowC)==nil,"pictures crossed running sessions")
            app.selectConversation(b)
            let absent=StoryArtwork(storyID:story.id,title:"缺失的图片",storyText:story.summary)
            app.messages.append(ChatMessage(isUser:false,text:"上一次画的图",artwork:absent))
            try expect(app.thumbnailURL(for:rowC)==nil && app.thumbnailURL(for:rowB)==art.url,"a missing file hid the previous valid picture")
            let index=app.messages.firstIndex{$0.artwork?.id==art.id}!
            app.messages[index].isRetracted=true
            try expect(app.thumbnailURL(for:rowB)==nil,"the archive resurrected a retracted picture")
            app.messages.append(ChatMessage(isUser:false,text:"看雨景",sceneID:"rain"))
            try expect(app.thumbnailURL(for:rowB)?.lastPathComponent=="rain.png","an unrelated archived picture took priority over this gallery item")
        }),
        ("UI-015 regular refreshes reuse the index and stale background reads cannot restore removed covers", {
            let store=try fixture();defer{remove(store)}
            let book=Story(title:"蓝雨伞",summary:"小猫带上一把蓝雨伞。")
            try store.saveStory(book)
            let older=StoryArtwork(storyID:book.id,title:"旧画",storyText:book.summary)
            let newer=StoryArtwork(storyID:book.id,title:"新画",storyText:book.summary)
            let bytes=try artworkFixtureData()
            try ArtworkArchive.save(older,data:bytes);defer{ArtworkArchive.remove(older);ArtworkArchive.remove(newer)}
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-60)],ofItemAtPath:older.url.path)
            let probe=ThumbnailLoadProbe();defer{probe.releaseFirst()}
            let app=AppModel(store:store,keyProvider:{nil},loadArtworkIndex:{probe.load($0)})
            let row=app.conversations[0]
            try await backgroundWait{probe.readings.count==1}
            app.selectConversation(row.id)
            guard let opened=app.conversations.first(where:{$0.id==app.selectedConversationID}) else {throw PartnerError.message("TEST: opening the archive lost its row")}
            for _ in 0..<25 {app.refresh()}
            let attributes=try FileManager.default.attributesOfItem(atPath:ArtworkArchive.directory.path)
            let originalDate=attributes[.modificationDate] as! Date
            try ArtworkArchive.save(newer,data:bytes)
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:5)],ofItemAtPath:newer.url.path)
            // Managed writes must invalidate even when a filesystem reports the same directory time.
            try FileManager.default.setAttributes([.modificationDate:originalDate],ofItemAtPath:ArtworkArchive.directory.path)
            app.refresh()
            try await backgroundWait{app.thumbnailURL(for:row)==newer.url}
            try expect(app.thumbnailURL(for:opened)==older.url,"opening before the index arrived adopted another conversation's later picture")
            probe.releaseFirst()
            try await backgroundWait{probe.readings.returnedFirst}
            for _ in 0..<20 {await Task.yield()}
            try expect(probe.readings.count==2 && !probe.readings.usedMain && app.thumbnailURL(for:row)==newer.url,"ordinary refresh rescanned, blocked the main thread, or published a stale index")
            ArtworkArchive.remove(newer);app.refresh()
            try await backgroundWait{probe.readings.count==3 && app.thumbnailURL(for:row)==older.url}
            ArtworkArchive.clear(storyID:book.id);app.refresh()
            try await backgroundWait{probe.readings.count==4 && app.thumbnailURL(for:row)==nil}
        }),
        ("UI-016 only a completed visible word card can request speech when the conversation is idle", {
            let store=try fixture();defer{remove(store)}
            var settings=try store.settings();settings.speaks=false;settings.voiceStyle="shimmer";try store.setSettings(settings)
            let model=ControlledConversationModel()
            let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in model})
            defer{app.cancel();model.releaseAll()}
            let word=WordCard(hanzi:"雨伞",pinyin:"yǔ sǎn",english:"umbrella")
            let card=ChatMessage(isUser:false,text:"这是雨伞。",word:word)
            app.messages.append(card)
            var spoken:[String]=[]
            app.voice.cloudSpeech={ text in spoken.append(text);throw CancellationError() }
            app.send("聊聊雨伞");try await backgroundWait{model.requests.count==1}
            app.readWord(in:card.id)
            try expect(!app.canReadWord(in:card) && !app.voice.preparing && spoken.isEmpty,"older card spoke during generation")
            model.finish(0,"小兔撑起雨伞。");try await backgroundWait{!app.busy}
            app.readWord(in:card.id);try await backgroundWait{spoken==["雨伞"]}
            app.voice.stopSpeaking()
            let index=app.messages.firstIndex{$0.id==card.id}!
            app.messages[index].isStreaming=true;app.readWord(in:card.id)
            app.messages[index].isStreaming=false;app.messages[index].isRetracted=true;app.readWord(in:card.id)
            app.newConversation()
            app.voice.cloudSpeech={ text in spoken.append(text);throw CancellationError() }
            app.readWord(in:card.id)
            try expect(!app.voice.preparing && spoken==["雨伞"],"a stale or retracted card replayed")
        }),
        ("UI-018 a new picture celebrates once with a finite schedule and reduced motion stays still", {
            var celebrations=ArtworkCelebrations()
            let start=Date(timeIntervalSince1970:1000)
            try expect(celebrations.begin(id:"a",savedAt:start,now:start,reduceMotion:false)==start,"fresh art failed to celebrate")
            try expect(celebrations.begin(id:"a",savedAt:start,now:start.addingTimeInterval(0.2),reduceMotion:false)==nil,"quick navigation replayed the burst")
            try expect(celebrations.begin(id:"b",savedAt:start,now:start,reduceMotion:true)==nil && celebrations.begin(id:"b",savedAt:start,now:start,reduceMotion:false)==nil,"a reduced-motion presentation replayed")
            let later=start.addingTimeInterval(PlayfulMotion.celebrationWindow+1)
            try expect(celebrations.begin(id:"a",savedAt:start,now:later,reduceMotion:false)==nil && celebrations.begin(id:"c",savedAt:later,now:later,reduceMotion:false)==later,"old art reappeared or new art was suppressed")
            let frames=PlayfulMotion.celebrationFrames(start:start)
            try expect(frames.first==start && frames.count<=60 && frames.last!.timeIntervalSince(start)>PlayfulMotion.celebrationDuration && frames.last!.timeIntervalSince(start)<2,"animation did not stop on its empty terminal frame")
        }),
        ("UI-001 conversation badge colours are stable per id and independent of order, selection and restart", {
            try expect(PlayfulPalette.fnv1a("a") == 0xaf63dc4c8601ec8c,"badge hash is not the fixed FNV-1a and may vary per process")
            let ids=(0..<40).map{"conversation-\($0)"}+["archive:label-ui-a","D6F1B2C4-0000-4000-8000-000000000001"]
            let first=ids.map{PlayfulPalette.index(for:$0)}
            try expect(ids.map{PlayfulPalette.index(for:$0)} == first,"repeated lookup changed a badge colour")
            try expect(ids.reversed().map{PlayfulPalette.index(for:$0)} == Array(first.reversed()),"list order changed a badge colour")
            try expect(first.allSatisfy{(0..<PlayfulPalette.count).contains($0)},"badge index escaped the palette")
            try expect(Set(first).count == PlayfulPalette.count,"badge colours did not spread across the palette")
            let store=try fixture();defer{remove(store)}
            for story in [Story(id:"badge-a",title:"小兔看星星",summary:"小兔坐月亮船看星星。",updatedAt:"2020-01-03T00:00:00Z"),Story(id:"badge-b",title:"小熊送苹果",summary:"小熊带着蓝色伞。",updatedAt:"2020-01-02T00:00:00Z"),Story(id:"badge-c",title:"红色小火车",summary:"小火车经过石桥。",updatedAt:"2020-01-01T00:00:00Z")] {try store.saveStory(story)}
            let app=AppModel(store:store,keyProvider:{nil})
            let before=Dictionary(uniqueKeysWithValues:app.conversations.map{($0.navigationID,PlayfulPalette.index(for:$0.navigationID))})
            for row in app.conversations.reversed() {app.selectConversation(row.id);app.refresh()}
            app.newConversation()
            let after=Dictionary(uniqueKeysWithValues:app.conversations.map{($0.navigationID,PlayfulPalette.index(for:$0.navigationID))})
            try expect(after == before,"selecting or refreshing changed a badge colour")
            let reopened=AppModel(store:try LocalStore(url:store.url),keyProvider:{nil})
            try expect(Dictionary(uniqueKeysWithValues:reopened.conversations.map{($0.navigationID,PlayfulPalette.index(for:$0.navigationID))}) == before,"restart changed a badge colour")
        }),
        ("UI-002 real call states outrank a tap and idle blinking stops under reduced motion", {
            let expected:[(StageActivity,StagePose)]=[(.connecting,.waving),(.listening,.listening),(.thinking,.thinking),(.speaking,.speaking),(.muted,.idle)]
            for (activity,pose) in expected {
                for cheering in [true,false] {for reduce in [true,false] {
                    try expect(LilyStage.pose(activity:activity,cheering:cheering,elapsed:0,reduceMotion:reduce) == pose,"\(activity) did not own the pose (cheering \(cheering), reduce \(reduce))")
                }}
            }
            try expect(LilyStage.pose(activity:.idle,cheering:true,elapsed:0,reduceMotion:false) == .waving,"tap did not wave")
            try expect(LilyStage.pose(activity:.idle,cheering:true,elapsed:0,reduceMotion:true) == .waving,"reduced motion lost the static tap response")
            let blinkMoment=LilyStage.blinkPeriod-LilyStage.blinkLength/2
            try expect(LilyStage.pose(activity:.idle,cheering:false,elapsed:blinkMoment,reduceMotion:false) == .blink,"idle Lily never blinks")
            try expect(LilyStage.pose(activity:.idle,cheering:false,elapsed:1,reduceMotion:false) == .idle,"idle Lily blinks constantly")
            let samples=Array(stride(from:0.0,to:30,by:0.05))
            try expect(samples.allSatisfy{LilyStage.pose(activity:.idle,cheering:false,elapsed:$0,reduceMotion:true) == .idle},"reduced motion still blinks")
            try expect(samples.allSatisfy{LilyStage.pose(activity:.speaking,cheering:false,elapsed:$0,reduceMotion:true) == .speaking},"reduced motion still animates the mouth")
            let blinkShare=Double(samples.filter{LilyStage.pose(activity:.idle,cheering:false,elapsed:$0,reduceMotion:false) == .blink}.count)/Double(samples.count)
            try expect(blinkShare > 0 && blinkShare < 0.1,"blinking is not occasional: \(blinkShare)")
            try expect(StagePose.allCases.allSatisfy{$0.row < 2 && $0.column < 3},"pose escaped the 3x2 atlas")
        }),
        ("UI-003 tapping Lily is a finite local cheer with cooldown and no conversation side effects", {
            var cheer=LilyCheer();let t0=Date(timeIntervalSinceReferenceDate:1_000)
            try expect(!cheer.isActive(at:t0),"cheer active before any tap")
            try expect(cheer.tap(at:t0) && cheer.isActive(at:t0.addingTimeInterval(0.5)),"tap did not start a cheer")
            try expect(!cheer.tap(at:t0.addingTimeInterval(0.8)),"rapid tap restarted the cheer")
            try expect(!cheer.isActive(at:t0.addingTimeInterval(LilyCheer.duration+0.01)),"cheer did not end")
            try expect(!cheer.tap(at:t0.addingTimeInterval(LilyCheer.duration+0.3)),"cooldown ignored")
            try expect(cheer.tap(at:t0.addingTimeInterval(LilyCheer.duration+LilyCheer.cooldown+0.01)),"cheer never available again")
            let p=cheer.progress(at:t0.addingTimeInterval(LilyCheer.duration+LilyCheer.cooldown+0.5)) ?? -1
            try expect(p >= 0 && p <= 1,"cheer progress out of range")
            let store=try fixture();defer{remove(store)}
            var spoken=0
            let app=AppModel(store:store,keyProvider:{nil},replySpeaker:{_ in spoken+=1})
            app.newConversation();app.draft="草稿还在"
            let snapshot=(app.selectedConversationID,app.draft,app.messages.count,app.conversations.count,app.inCall,app.busy,app.voice.speaking)
            var tapped=LilyCheer();let now=Date()
            for offset in stride(from:0.0,to:5,by:0.25) {tapped.tap(at:now.addingTimeInterval(offset));_=LilyStage.pose(activity:.idle,cheering:tapped.isActive(at:now.addingTimeInterval(offset)),elapsed:offset,reduceMotion:false)}
            try expect(app.selectedConversationID == snapshot.0 && app.draft == snapshot.1 && app.messages.count == snapshot.2 && app.conversations.count == snapshot.3,"tap changed the conversation")
            try expect(app.inCall == snapshot.4 && app.busy == snapshot.5 && app.voice.speaking == snapshot.6 && spoken == 0,"tap started a call, request or speech")
        }),
        ("UI-004 reduced motion zeroes every spontaneous movement and normal motion stays bounded", {
            for t in stride(from:0.0,to:20,by:0.37) {
                try expect(PlayfulMotion.floatOffset(elapsed:t,reduceMotion:true) == 0,"float under reduced motion")
                try expect(abs(PlayfulMotion.floatOffset(elapsed:t,reduceMotion:false)) <= PlayfulMotion.floatAmplitude,"float exceeded amplitude")
                try expect(PlayfulMotion.haloScale(level:5,elapsed:t,reduceMotion:true) == 1,"halo pulses under reduced motion")
                let halo=PlayfulMotion.haloScale(level:5,elapsed:t,reduceMotion:false)
                try expect(halo >= 1 && halo <= PlayfulMotion.maxHalo,"halo out of bounds")
            }
            for p in stride(from:0.0,through:1,by:0.05) {
                try expect(PlayfulMotion.cheerHop(progress:p,reduceMotion:true) == 0,"hop under reduced motion")
                let hop=PlayfulMotion.cheerHop(progress:p,reduceMotion:false)
                try expect(hop <= 0 && hop >= -PlayfulMotion.maxHop,"hop out of bounds")
            }
            try expect(abs(PlayfulMotion.cheerHop(progress:1,reduceMotion:false)) < 0.001 && PlayfulMotion.cheerHop(progress:nil,reduceMotion:false) == 0,"hop does not land")
            try expect(PlayfulMotion.particleCount(reduceMotion:true) == 0 && (1...8).contains(PlayfulMotion.particleCount(reduceMotion:false)),"particle budget wrong")
            try expect(!PlayfulMotion.bubbleEntrance(age:0.1,reduceMotion:true) && PlayfulMotion.bubbleEntrance(age:0.1,reduceMotion:false),"bubble entrance ignored reduced motion")
            try expect(!PlayfulMotion.bubbleEntrance(age:5,reduceMotion:false) && !PlayfulMotion.bubbleEntrance(age:-1,reduceMotion:false),"old bubbles replay their entrance")
        }),
        ("UI-005 greeting follows local time and entry, and opening cards still only fill the draft", {
            try expect(PlayfulGreeting.title(hour:8,voice:false).hasPrefix("早上好"),"morning greeting")
            try expect(PlayfulGreeting.title(hour:14,voice:false).hasPrefix("下午好"),"afternoon greeting")
            try expect(PlayfulGreeting.title(hour:20,voice:false).hasPrefix("晚上好") && PlayfulGreeting.title(hour:2,voice:false).hasPrefix("晚上好"),"evening greeting")
            try expect((0..<24).allSatisfy{PlayfulGreeting.title(hour:$0,voice:true) == "莉莉在这里"} && PlayfulGreeting.subtitle(voice:true) == nil,"voice entry gained topic prompts")
            try expect(PlayfulGreeting.subtitle(voice:false) != nil,"text entry lost its question")
            let store=try fixture();defer{remove(store)}
            let app=AppModel(store:store,keyProvider:{nil})
            app.newConversation()
            try expect(app.showsOpeningOptions,"text entry hides opening cards")
            app.chooseOpening(.story)
            try expect(app.draft == OpeningPrompt.story.text,"opening card did not fill the draft")
            try expect(!app.busy && app.messages.filter{$0.source != "welcome"}.isEmpty && app.conversations.isEmpty && !app.isConversationStarted,"opening card sent or created a conversation")
            try expect(Set(OpeningPrompt.allCases.map(\.title)).count == OpeningPrompt.allCases.count,"opening cards lost distinct topics")
        }),
        ("UI-006 main-window surfaces stay soft rather than glaring while text keeps AAA contrast", {
            let white=SoftRGB(1,1,1)
            try expect(abs(white.luminance-1) < 0.0001 && abs(SoftRGB(0,0,0).luminance) < 0.0001,"luminance formula is not WCAG relative luminance")
            try expect(SoftRGB(1,0.985,0.95).luminance > PlayfulSurfaces.maxBackdropLuminance,"the old glaring backdrop would pass the bound")
            for colour in PlayfulSurfaces.backdrops {
                try expect(colour.luminance <= PlayfulSurfaces.maxBackdropLuminance,"backdrop too bright: \(colour) \(colour.luminance)")
                try expect(SoftRGB.contrast(PlayfulSurfaces.ink,colour) >= PlayfulSurfaces.minTextContrast,"text contrast too low on \(colour)")
            }
            for colour in PlayfulSurfaces.surfaces {
                try expect(colour != white && colour.luminance <= PlayfulSurfaces.maxSurfaceLuminance,"surface too bright: \(colour) \(colour.luminance)")
                try expect(SoftRGB.contrast(PlayfulSurfaces.ink,colour) >= PlayfulSurfaces.minTextContrast,"text contrast too low on \(colour)")
            }
            try expect(PlayfulSurfaces.cloudOpacityScale > 0 && PlayfulSurfaces.cloudOpacityScale < 1,"clouds were not toned down")
        }),
        ("UI-007 the big talk button appears only on a blank, idle conversation and leaves topic cards draft-only", {
            let store=try fixture();defer{remove(store)}
            let app=AppModel(store:store,keyProvider:{nil})
            app.newConversation()
            try expect(app.showsWelcomeTalkButton && app.showsOpeningOptions,"blank text entry lacks the talk button or topics")
            app.chooseOpening(.today)
            try expect(app.showsWelcomeTalkButton && app.draft == OpeningPrompt.today.text && app.conversations.isEmpty,"topic card did more than fill the draft")
            app.enterVoiceConversation()
            try expect(app.showsWelcomeTalkButton && !app.showsOpeningOptions,"voice entry lost the talk button or gained topics")
            app.newConversation();app.recordUserMessageSent("今天发现了蝴蝶");app.messages.append(ChatMessage(isUser:true,text:"今天发现了蝴蝶"))
            try expect(!app.showsWelcomeTalkButton,"talk button stayed after the conversation started")
            // Minimum window: 600 high minus header (~70) and composer (~110) leaves ~420 for the welcome.
            for voice in [false,true] {
                try expect(PlayfulLayout.welcomeHeadHeight(voice:voice,compact:true) <= 420,"talk button falls below the fold in the minimum window (voice \(voice))")
                try expect(PlayfulLayout.stageSize(voice:voice,compact:true) < PlayfulLayout.stageSize(voice:voice,compact:false),"compact layout did not shrink the stage")
            }
        }),
        ("UI-008 sidebar thumbnails use the conversation's latest picture without changing order or titles", {
            let store=try fixture();defer{remove(store)}
            let drawn=Story(id:"thumb-a",title:"小兔看星星",summary:"小兔坐月亮船看星星。",updatedAt:"2020-01-02T00:00:00Z"),plain=Story(id:"thumb-b",title:"小熊送苹果",summary:"小熊带着蓝色伞。",updatedAt:"2020-01-01T00:00:00Z")
            for story in [drawn,plain] {try store.saveStory(story)}
            let older=StoryArtwork(storyID:drawn.id,title:"旧画",storyText:drawn.summary),newer=StoryArtwork(storyID:drawn.id,title:"新画",storyText:drawn.summary)
            try ArtworkArchive.save(older,data:artworkFixtureData());defer{ArtworkArchive.remove(older)}
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-3600)],ofItemAtPath:older.url.path)
            try ArtworkArchive.save(newer,data:artworkFixtureData());defer{ArtworkArchive.remove(newer)}
            let app=AppModel(store:store,keyProvider:{nil})
            let rows=app.conversations,order=rows.map(\.navigationID),titles=rows.map(\.title)
            try await backgroundWait { rows.first{$0.storyID == drawn.id}.flatMap{app.thumbnailURL(for:$0)} == newer.url }
            try expect(rows.first{$0.storyID == drawn.id}.flatMap{app.thumbnailURL(for:$0)} == newer.url,"archived conversation did not show its latest saved picture")
            try expect(rows.first{$0.storyID == plain.id}.flatMap{app.thumbnailURL(for:$0)} == nil,"conversation without pictures got a thumbnail")
            app.newConversation();app.recordUserMessageSent("画一辆小火车")
            let live=StoryArtwork(storyID:"live-story",title:"小火车",storyText:"红色小火车过桥。")
            try ArtworkArchive.save(live,data:artworkFixtureData());defer{ArtworkArchive.remove(live)}
            app.messages.append(ChatMessage(isUser:true,text:"画一辆小火车"));app.messages.append(ChatMessage(isUser:false,text:"画好啦",artwork:live))
            guard let current=app.conversations.first(where:{$0.id == app.selectedConversationID}) else {throw PartnerError.message("TEST: live row missing")}
            try expect(app.thumbnailURL(for:current) == live.url,"current conversation did not show its new picture")
            let liveRow=current.navigationID
            if let other=app.conversations.first(where:{$0.storyID == plain.id}) {app.selectConversation(other.id)}
            try expect(app.conversations.first{$0.navigationID == liveRow}.flatMap{app.thumbnailURL(for:$0)} == live.url,"background conversation lost its picture")
            app.newConversation();app.recordUserMessageSent("看一张雨天的画")
            app.messages.append(ChatMessage(isUser:false,text:"小兔和小刺猬。",sceneID:"rain"))
            if let galleryRow=app.conversations.first(where:{$0.id == app.selectedConversationID}) {
                try expect(app.thumbnailURL(for:galleryRow)?.lastPathComponent == "rain.png","gallery picture did not become the thumbnail")
            } else {throw PartnerError.message("TEST: gallery row missing")}
            try expect(app.conversations.filter{order.contains($0.navigationID)}.map(\.navigationID) == order && app.conversations.filter{order.contains($0.navigationID)}.map(\.title) == titles,"thumbnails changed order or titles")
        }),
        ("UI-009 the call avatar has a pose and status symbol for every real call state", {
            let states:[StageActivity]=[.connecting,.listening,.thinking,.speaking,.muted]
            let poses=states.map{LilyStage.pose(activity:$0,cheering:false,elapsed:0,reduceMotion:false)}
            try expect(Set(poses.map(\.rawValue)).count >= 4,"call states share too few poses")
            try expect(Set(states.map(\.badgeSymbol)).count == states.count,"call states lost distinct status symbols")
            try expect(StageActivity.listening.badgeSymbol == "mic.fill" && StageActivity.speaking.badgeSymbol == "speaker.wave.2.fill" && StageActivity.muted.badgeSymbol == "mic.slash.fill","status symbols diverged from the call panel")
            try expect(stride(from:0.0,to:10,by:0.1).allSatisfy{LilyStage.pose(activity:.speaking,cheering:false,elapsed:$0,reduceMotion:true) == .speaking},"reduced motion still moves the mouth")
        }),
        ("UI-010 drawing progress shows the painting wait and only freshly saved pictures celebrate", {
            for line in ["莉莉在选画面…","莉莉在画画…","莉莉在补好细节…","快画好啦…"] {try expect(PaintingStatus.isDrawing(line),"\(line) not recognised as drawing")}
            for line in ["莉莉在认真听","莉莉正在想一想","莉莉再想一个开头",""] {try expect(!PaintingStatus.isDrawing(line),"\(line) mistaken for drawing")}
            let fills=stride(from:0.0,to:20,by:0.1).map{PaintingStatus.fill(elapsed:$0,reduceMotion:false)}
            try expect(fills.allSatisfy{$0 >= PaintingStatus.minimumFill - 0.0001 && $0 <= 1} && (fills.max() ?? 0) > 0.95 && (fills.min() ?? 1) < PaintingStatus.minimumFill + 0.05 && PaintingStatus.minimumFill > 0,"canvas fill does not loop between a coloured start and a full canvas")
            try expect(Set(stride(from:0.0,to:20,by:0.5).map{PaintingStatus.fill(elapsed:$0,reduceMotion:true)}).count == 1,"canvas moves under reduced motion")
            try expect(PlayfulMotion.celebrates(artworkAge:0.5,reduceMotion:false),"fresh picture did not celebrate")
            try expect(!PlayfulMotion.celebrates(artworkAge:0.5,reduceMotion:true) && !PlayfulMotion.celebrates(artworkAge:60,reduceMotion:false) && !PlayfulMotion.celebrates(artworkAge:nil,reduceMotion:false),"old, unknown or reduced-motion pictures celebrated")
            let art=StoryArtwork(storyID:"fresh",title:"新画",storyText:"小兔。")
            try ArtworkArchive.save(art,data:artworkFixtureData());defer{ArtworkArchive.remove(art)}
            let age=ArtworkArchive.savedAt(art).map{Date().timeIntervalSince($0)}
            try expect(PlayfulMotion.celebrates(artworkAge:age,reduceMotion:false),"just-saved picture age was not recognised")
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-120)],ofItemAtPath:art.url.path)
            try expect(!PlayfulMotion.celebrates(artworkAge:ArtworkArchive.savedAt(art).map{Date().timeIntervalSince($0)},reduceMotion:false),"reopened old picture celebrated again")
        }),
        ("UI-011 word cards read the hanzi and stay silent during calls", {
            try expect(WordCard(hanzi:"雨伞",pinyin:"yǔ sǎn",english:"umbrella").readAloudText == "雨伞","word card reads something other than the word")
            let store=try fixture();defer{remove(store)}
            let app=AppModel(store:store,keyProvider:{nil})
            try expect(app.canReadWords == !app.inCall && app.canReadWords,"idle app cannot read word cards")
        }),
        ("UI-012 the child avatar is a bundled original square illustration with recorded provenance", {
            let image=URL(fileURLWithPath:"macos/Resources/Brand/child-avatar.png"),record=URL(fileURLWithPath:"macos/Resources/Brand/child-avatar.json")
            guard let source=CGImageSourceCreateWithURL(image as CFURL,nil),let picture=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw PartnerError.message("TEST: child avatar missing or unreadable")}
            try expect(picture.width == picture.height && picture.width >= 256 && picture.width <= 1024,"child avatar is not a modest square image")
            let info=try JSONSerialization.jsonObject(with:Data(contentsOf:record)) as? [String:Any] ?? [:]
            try expect((info["prompt"] as? String)?.isEmpty == false && (info["mode"] as? String)?.isEmpty == false && (info["purpose"] as? String)?.isEmpty == false,"child avatar provenance is incomplete")
            try expect((info["prompt"] as? String)?.contains("girl") == true,"child avatar is no longer the requested little girl")
        }),
        ("UI-013 voice-correction entries are named 重说 / 修改 everywhere", {
            try expect(VoiceFixLabels.retry == "重说" && VoiceFixLabels.edit == "修改","voice-correction labels changed")
            for file in ["Views.swift","CallActivity.swift","DesktopPet.swift","PlayfulViews.swift"] {
                let source=try String(contentsOf:URL(fileURLWithPath:"macos/Sources/"+file),encoding:.utf8)
                try expect(!source.contains("\"改文字\""),"\(file) still shows the old 改文字 label")
            }
        })
    ]
}
