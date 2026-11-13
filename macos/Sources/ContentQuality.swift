import Foundation

struct ContentVerdict {
    var accepted:Bool
    var issues:[String]
    var inputTokens=0
    var outputTokens=0
}
protocol ContentQualityReviewingModel:PartnerModel {
    func reviewContent(user:String,previous:Story?,reply:PartnerReply) async throws -> ContentVerdict
}
enum ContentQuality {
    static func continuesStory(_ user:String,previous:Story?)->Bool {
        guard previous != nil, !Safety.matches(user,"现实|真的|知识|科学|为什么|英语|英文|照片|停|不想听|休息|我今天|我自己") else{return false}
        return Safety.matches(user,"(?:希望|想让).{0,8}(?:它|这[颗只条座个]|主角)|接着讲|接着编|继续.{0,8}故事|不是.{0,12}是|改成|改叫|别.{0,5}忘")
    }
    static func needsReview(user:String,reply:PartnerReply,previous:Story? = nil)->Bool {
        reply.narrative || continuesStory(user,previous:previous) || Safety.matches(user,"怎么读|怎么拼|英语|英文|发音|拼音|为什么|现实|真的原因|换气|剩几|科学|照片|不是.{0,12}是|改成|改叫|别.*忘")
    }
    static func minimumLength(user:String,reply:PartnerReply)->Int {
        guard reply.narrative, Safety.matches(user,"[讲编].{0,18}故事|继续|接着讲|接着编|先讲一段|讲完整|讲完") else{return 0}
        if Safety.matches(user,"短短|短点|简短|两句|一句|短开头|不要太长") {return 0}
        let amounts=["两百":200,"二百":200,"三百":300,"四百":400,"五百":500,"六百":600,"七百":700,"八百":800,"九百":900]
        for (word,amount) in amounts where user.contains(word+"字") {return min(850,Int(Double(amount)*0.88))}
        if let range=user.range(of:"[2-9][0-9]{1,2}(?=个?字)",options:.regularExpression),let count=Int(user[range]) {return min(850,Int(Double(count)*0.88))}
        return Safety.matches(user,"完整.*故事|故事.*讲完|讲完") ? 300 : 130
    }
}
