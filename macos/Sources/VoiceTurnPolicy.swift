import Foundation

/// VAD detects sound; this policy decides whether that sound should take the turn.
enum VoiceTurnPolicy {
    struct Context {
        var overlapsOutput=false
        var expectsReply=false
        var outputID:String?
        var echoTexts:[String]=[]
    }
    static func commandText(_ text:String)->String {
        var value=VoiceTurns.normalized(text)
        let prefixes=["莉莉","丽丽","你能不能","能不能","可不可以","请你","麻烦你","麻烦","我说","那个","你先","请","你","嗯","呃","喂"]
        for _ in 0..<6 {
            guard let prefix=prefixes.first(where:{value.hasPrefix($0)}) else{break}
            value.removeFirst(prefix.count)
        }
        return value
    }
    private static let stopPrefixes=["先停一下","先停下来","先停下","暂停一下","停一下","停下来","停下","停止","暂停","不要讲了","别讲了","不要说了","别说了","先别讲","先别说","等一下","等我一下","等一等","等会儿","先等一下","先等等","等等"]
    private static let floorPrefixes=["听我说","先听我说","让我说","让我先说","我想说","我有话要说","我有一个问题","我想问个问题","我想问一下","我想问你","不对"]
    static func isUrgent(_ text:String,partial:Bool=false)->Bool {
        let raw=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if let first=raw.first,"“‘「『\"".contains(first) {return false}
        let value=commandText(text)
        if stopPrefixes.contains(where:{prefix in ["是什么意思","的意思","这个词","怎么读","怎么说","按钮","键"].contains{value.hasPrefix(prefix+$0)}}) {return false}
        if ["stop","pause","wait","holdon"].contains(value) {return true}
        if !value.isEmpty,value.count<=5,value.allSatisfy({$0=="停"}) {return true}
        return (stopPrefixes+floorPrefixes).contains{value.hasPrefix($0)}
    }
    static func isControlOnly(_ text:String)->Bool {
        guard isUrgent(text) else{return false}
        var value=commandText(text)
        if ["stop","pause","wait","holdon"].contains(value) {return true}
        let prefixes=(["停"]+stopPrefixes+floorPrefixes.filter{$0 != "不对"}).sorted{$0.count>$1.count}
        var found=false
        while let prefix=prefixes.first(where:{value.hasPrefix($0)}) {
            found=true;value.removeFirst(prefix.count)
        }
        return found && value.allSatisfy{"吧呀啊哦呢了先".contains($0)}
    }
    static func isBackchannel(_ text:String,context:Context)->Bool {
        guard context.overlapsOutput,!context.expectsReply,!isUrgent(text) else{return false}
        let value=VoiceTurns.normalized(text)
        if ["嗯","嗯嗯","嗯哼","哦","噢","啊","呀","哇","好","好的","好呀","对","对的","是的","知道了","明白了","哈哈","哈哈哈","继续","接着讲","不要停","别停"].contains(value) {return true}
        if value.range(of:"^(?:嗯|哦|噢|啊|好|好的|好呀|对|对的|是的|哈哈|我知道了|知道了|明白了){1,4}$",options:.regularExpression) != nil {return true}
        return !value.isEmpty && value.count<=6 && (value.allSatisfy{$0=="嗯"} || value.allSatisfy{$0=="哦"} || value.allSatisfy{$0=="哈"} || value.allSatisfy{$0=="对"})
    }
    static func expectsReply(_ text:String)->Bool {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        return value.hasSuffix("？") || value.hasSuffix("?")
    }
    /// Fast paths are deliberately small. Contextual comments go to the intent
    /// model; a completed genuine request falls back to listening on timeout.
    static func quickIntent(_ text:String,context:Context,final:Bool)->VoiceIntent? {
        let value=normalizedContent(text)
        if !final,context.overlapsOutput,!context.expectsReply,value.count>=2,
           context.echoTexts.contains(where:{VoiceTurns.normalized($0).contains(value)}) {return .undecided}
        if isUrgent(text,partial:!final) {return isControlOnly(text) ? .stop : .listen}
        if isBackchannel(text,context:context) {return .keepSpeaking}
        if !final,context.overlapsOutput,["我说","我想说","我有话"].contains(where:{value.hasPrefix($0)}) {return .listen}
        if ["莉莉","丽丽","喂喂","喂喂喂"].contains(value) {return .listen}
        if context.overlapsOutput,!context.expectsReply,VoiceTurns.isEcho(text,of:context.echoTexts) {return .keepSpeaking}
        if ["妈妈","爸爸","爷爷","奶奶"].contains(where:{commandText(text).hasPrefix($0)}),!context.expectsReply {return nil}
        if text.contains("？") || text.contains("?") {return .listen}
        if value.range(of:"为什么|怎么|是不是|能不能|可不可以|什么(?:意思|时候|名字)|哪[里儿个]|多少",options:.regularExpression) != nil {return .listen}
        if ["为什么","怎么","什么","哪里","哪儿","谁","多少","能不能","可不可以","不是","不对","我不想","我不喜欢","我害怕","我有点害怕","换一个","换个","我们换"].contains(where:{value.hasPrefix($0)}) {return .listen}
        if value.range(of:"^(?:它|他|她|小.{1,4})(?:不是|不会|不能|没有|不应该)",options:.regularExpression) != nil {return .listen}
        return nil
    }
    static func normalizedContent(_ text:String)->String {VoiceTurns.normalized(text)}
}

enum StoryParagraphs {
    /// Explicit paragraphs stay intact. Oversized prose is divided only after a
    /// complete sentence outside quotations, never at a comma or arbitrary word.
    static func split(_ text:String,softLimit:Int=100)->[String] {
        let explicit=text.components(separatedBy:"\n\n").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        return explicit.flatMap { paragraph -> [String] in
            guard paragraph.count>softLimit+40 else{return [paragraph]}
            var result:[String]=[],current="",quoteDepth=0,straightQuote=false,pendingEnd=false
            for character in paragraph {
                if pendingEnd && quoteDepth==0 && !straightQuote && !"”’」』\"'".contains(character) && current.count>=softLimit {
                    result.append(current);current="";pendingEnd=false
                }
                current.append(character)
                if "“‘「『".contains(character) {quoteDepth+=1}
                if "”’」』".contains(character) {quoteDepth=max(0,quoteDepth-1)}
                if character=="\"" {straightQuote.toggle()}
                if "。！？!?".contains(character) {pendingEnd=true}
                else if !"”’」』\"'".contains(character) {pendingEnd=false}
            }
            if !current.isEmpty {result.append(current)}
            return result
        }
    }
}
