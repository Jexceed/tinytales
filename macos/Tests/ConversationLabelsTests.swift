import Foundation

@MainActor func conversationLabelsTestCases() -> [(String,@MainActor () async throws -> Void)] {
    [
        ("CL-001 legacy placeholders get distinct content labels without rewriting archives", {
            let store=try fixture();defer{remove(store)}
            let stories=[
                Story(id:"label-a",title:"新的小冒险",summary:"小兔坐着月亮船去看星星。",updatedAt:"2026-11-17T06:32:00Z"),
                Story(id:"label-b",title:"新的小小冒险",summary:"故事摘要：小熊带着蓝色雨伞去送苹果。",updatedAt:"2026-11-16T08:05:00Z"),
                Story(id:"label-c",title:"会唱歌的红色小火车",summary:"小火车经过森林石桥。",updatedAt:"2025-11-15T07:20:00Z")
            ]
            for story in stories {try store.saveStory(story)}
            let app=AppModel(store:store,keyProvider:{nil}),before=try store.stories()
            let rows=app.conversations,order=rows.map(\.navigationID)
            try expect(Set(rows.map(\.title)).count == 3 && rows[0].title.contains("月亮船") && rows[1].title.contains("蓝色雨伞"),"generic archives remained indistinguishable")
            try expect(rows[2].title == stories[2].title,"specific title was rewritten")
            for row in rows {
                app.selectConversation(row.id)
                try expect(app.conversationTitle == row.title && app.conversationUpdatedAt == row.updatedAt,"opening changed the label or timestamp")
                app.refresh()
            }
            try expect(app.conversations.map(\.navigationID) == order,"label derivation reordered history")
            app.newConversation()
            try expect(try store.stories() == before,"displaying old records rewrote the database")
            let reopened=AppModel(store:try LocalStore(url:store.url),keyProvider:{nil})
            try expect(reopened.conversations.map(\.title) == rows.map(\.title) && reopened.conversations.map(\.updatedAt) == rows.map(\.updatedAt),"restart lost derived labels or original dates")
        }),
        ("CL-002 typed replies replace a generic story title before publishing and saving", {
            let store=try fixture();defer{remove(store)}
            var settings=PartnerSettings();settings.speaks=false;try store.setSettings(settings)
            let text="红色小火车唱着歌经过森林石桥。"
            let fake=FakeModel([modern(text,state:text,title:"新的小冒险")])
            let app=AppModel(store:store,keyProvider:{"fixture"},modelFactory:{_ in fake})
            app.send("讲一个小火车的故事")
            for _ in 0..<100 {if !app.busy{break};try await Task.sleep(nanoseconds:10_000_000)}
            let saved=try store.stories()
            try expect(!app.busy && saved.count == 1 && saved[0].title.contains("小火车"),"typed checkpoint saved the placeholder")
            try expect(app.conversations.count == 1 && app.conversationTitle == saved[0].title,"published title differs from saved title")
            try expect(fake.inputs.count == 1,"naming added a model request")
        }),
        ("CL-002 shared checkpoints and save tools derive missing names from fictional content", {
            let store=try fixture();defer{remove(store)}
            for title in ["", "   ", "新的小冒险", "新的小小冒险"] {
                let toolkit=try PartnerTools(store:store,text:"讲一个小熊的故事")
                toolkit.prepareCheckpoint(PartnerReply(reply:"小熊用蓝色雨伞接住了苹果。",suggestions:[],narrative:true,storyTitle:title))
                try toolkit.commit(expectedRevision:store.revision)
                try expect(toolkit.session.current?.title.contains("蓝色雨伞") == true,"empty or generic checkpoint title survived")
            }
            let toolkit=try PartnerTools(store:store,text:"保存这个故事")
            _=try toolkit.execute(name:"save_story",args:["title":"新的小冒险","summary":"小兔坐月亮船去找星星。","fictional":true])
            try toolkit.commit(expectedRevision:store.revision)
            try expect(try store.stories().contains{$0.title.contains("月亮船")},"save_story kept a placeholder")
            let exact=try PartnerTools(store:store,text:"继续这个故事",session:StorySession())
            exact.prepareCheckpoint(PartnerReply(reply:"小兔找到了星星。",suggestions:[],narrative:true,storyTitle:"月亮船"))
            try expect(exact.preparedNarrative?.title == "月亮船","explicit title was replaced")
            let introduction=Story(title:"新的小冒险",summary:"好呀！我们来讲一个小故事吧。小兔坐着月亮船去看星星。")
            try expect(introduction.conversationTitle.contains("月亮船"),"spoken introduction became another generic title")
            let sameSentence=Story(title:"新的小冒险",summary:"好的，小熊带着蓝色雨伞去送苹果。")
            try expect(sameSentence.conversationTitle.hasPrefix("小熊"),"spoken filler hid the story subject")
            let advice=Story(title:"新的小冒险",summary:"当然可以呀！给小动物讲故事，先介绍清楚主角，再讲它的发现。")
            try expect(advice.conversationTitle == "给小动物讲故事","polite opening replaced the actual topic")
            let panels=Story(title:"新的小冒险",summary:"听起来真有画面感呢，我先整理成连环画。\n刚刚讲到：好呀。\n第一格：小松鼠在森林里找到彩虹叶子。\n第二格：叶子变成了一把伞。")
            try expect(panels.conversationTitle.contains("小松鼠") && !panels.conversationTitle.contains("画面感"),"panel introduction hid the concrete scene")
            let named=Story(title:"新的小冒险",summary:"我给你讲“守株待兔”的成语故事。农夫看到一只兔子跑来。")
            try expect(named.conversationTitle == "守株待兔","explicit work name was not recognized")
        }),
        ("CL-003 submitting updates time while selection caching and refresh preserve sidebar identity", {
            let store=try fixture();defer{remove(store)}
            var clock=ConversationLabels.date("2026-11-17T06:32:00Z")!
            let app=AppModel(store:store,keyProvider:{nil},now:{clock})
            app.recordUserMessageSent("  \n ")
            try expect(app.conversations.isEmpty && app.conversationUpdatedAt == nil,"blank input created a dated row")
            app.recordUserMessageSent("今天发现了一只蝴蝶");let a=app.selectedConversationID,firstTime=clock
            app.newConversation();clock=clock.addingTimeInterval(60)
            app.recordUserMessageSent("一起看看月亮");let b=app.selectedConversationID
            let order=app.conversations.map(\.navigationID)
            app.selectConversation(a);clock=clock.addingTimeInterval(60);app.refresh()
            try expect(app.conversationUpdatedAt == firstTime && app.conversationTitle.contains("蝴蝶"),"selecting or refreshing advanced the time")
            app.recordUserMessageSent("蝴蝶停在花朵上")
            let lastTime=clock
            app.selectConversation(b);app.selectConversation(a)
            try expect(app.conversationUpdatedAt == lastTime && app.conversations.map(\.navigationID) == order,"updated time was lost or moved the row")
            app.newConversation();app.recordUserMessageSent("我的学校是秘密学校")
            try expect(!app.conversationTitle.contains("秘密学校"),"private input was copied into the title")
        }),
        ("CL-004 timestamp labels preserve date minute year and local timezone without inventing missing times", {
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Singapore")!
            let now=ConversationLabels.date("2026-11-17T06:32:00Z")!
            try expect(ConversationLabels.timestamp(now,now:now,calendar:calendar) == "11月17日 14:32","date or local minute omitted")
            let old=ConversationLabels.date("2025-11-17T06:32:00.125Z")
            try expect(ConversationLabels.timestamp(old,now:now,calendar:calendar) == "2025年11月17日 14:32","old year or fractional ISO timestamp mishandled")
            try expect(ConversationLabels.timestamp(now,now:now,calendar:calendar,full:true) == "2026年11月17日 14:32","accessible timestamp is incomplete")
            let midnight=ConversationLabels.date("2026-11-16T18:05:00Z")
            try expect(ConversationLabels.timestamp(midnight,now:now,calendar:calendar) == "11月17日 02:05","UTC date was shown instead of local date")
            try expect(ConversationLabels.timestamp(ConversationLabels.date("broken"),now:now,calendar:calendar) == "时间未记录","invalid date became the current date")
            let damaged=Story(title:"旧故事",summary:"小兔在花园。",updatedAt:"broken")
            try expect(damaged.conversationUpdatedAt == nil,"archive invented a timestamp")
        })
    ]
}
