import Foundation

/// Content-derived labels only; raw conversation text stays in memory.
enum ConversationLabels {
    static func isPlaceholder(_ title:String) -> Bool {
        let normalized=title.components(separatedBy:.whitespacesAndNewlines.union(.punctuationCharacters)).joined()
        let acknowledgement=normalized.replacingOccurrences(of:#"[呀啊哦呢啦]+$"#,with:"",options:.regularExpression)
        return ["", "莉莉", "新对话", "语音对话", "故事对话", "新的小冒险", "新的小小冒险", "小小冒险", "小冒险", "新的冒险", "新故事", "新的故事", "小故事", "一个小故事", "故事", "我们开始吧", "故事开始了", "让我们开始吧", "我们来讲一个小故事吧"].contains(normalized)
            || ["嗯", "好", "好的", "当然", "当然可以", "没问题", "可以"].contains(acknowledgement)
    }

    static func storyTitle(_ candidates:[String], summary:String) -> String {
        if let title=candidates.first(where:{!isPlaceholder($0)}) {
            return String(title.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").prefix(35))
        }
        guard !Safety.isPrivate(summary), !Safety.isRisk(summary) else{return "故事对话"}
        // Prefer an explicitly named work or the first panel over spoken setup.
        if let expression=try? NSRegularExpression(pattern:#"[《“「]([^》”」\n]{2,20})[》”」](?:的)?(?:成语故事|故事|童话|古诗|诗歌)"#),
           let match=expression.firstMatch(in:summary,range:NSRange(summary.startIndex...,in:summary)),
           match.range.location < 60,let range=Range(match.range(at:1),in:summary) {
            return String(summary[range])
        }
        let panel=summary.range(of:#"(?:^|\n)\s*(?:第一[格幕幅]|画面[一1])[：:]\s*"#,options:.regularExpression)
        let content=panel.map{String(summary[$0.upperBound...])} ?? summary
        let prefixes=["故事摘要：", "故事摘要:", "故事设定：", "故事设定:", "当前故事：", "当前故事:", "刚刚讲到：", "刚刚讲到:", "主角：", "主角:"]
        for part in content.components(separatedBy:CharacterSet(charactersIn:"\n。！？!?；;")) {
            var line=part.trimmingCharacters(in:.whitespacesAndNewlines)
            for prefix in prefixes where line.hasPrefix(prefix) {line=String(line.dropFirst(prefix.count)).trimmingCharacters(in:.whitespacesAndNewlines)}
            line=line.replacingOccurrences(of:#"^(?:(?:嗯|好|好的|当然可以|没问题)[呀啊哦呢啦]*[，,\s]+)+"#,with:"",options:.regularExpression)
            guard !isPlaceholder(line) else{continue}
            if let comma=line.firstIndex(where:{$0 == "，" || $0 == ","}),line.distance(from:line.startIndex,to:comma)>=7 {
                line=String(line[..<comma])
            }
            let excerpt=String(line.prefix(20)).trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
            if !excerpt.isEmpty {return excerpt + (line.count > 20 ? "…" : "")}
        }
        return "故事对话"
    }

    static func date(_ value:String) -> Date? {
        let formatter=ISO8601DateFormatter()
        if let date=formatter.date(from:value) {return date}
        formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return formatter.date(from:value)
    }

    static func timestamp(_ date:Date?, now:Date=Date(), calendar:Calendar = .autoupdatingCurrent, full:Bool=false) -> String {
        guard let date else{return "时间未记录"}
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"zh_CN")
        formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=calendar.timeZone
        let sameYear=calendar.component(.year,from:date) == calendar.component(.year,from:now)
        formatter.dateFormat=full || !sameYear ? "yyyy年M月d日 HH:mm" : "M月d日 HH:mm"
        return formatter.string(from:date)
    }
}

extension Story {
    var conversationTitle:String {ConversationLabels.storyTitle([title],summary:summary)}
    var conversationUpdatedAt:Date? {ConversationLabels.date(updatedAt)}
}
