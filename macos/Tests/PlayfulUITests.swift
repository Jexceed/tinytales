import Foundation

@MainActor func playfulUITestCases() -> [(String,@MainActor () async throws -> Void)] {
    [
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
        })
    ]
}
