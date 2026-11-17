import Foundation

/// Deliberately ignores cancellation until the test releases each request.
/// This exposes late delivery, out-of-order completion and retry races.
@MainActor final class ControlledConversationModel:StreamingPartnerModel,StoryIllustratingModel {
    struct ReplyRequest {
        let input:[[String:Any]]
        let onReply:@MainActor (String) async throws -> Void
        var completion:CheckedContinuation<ModelOutput,Error>?
    }
    struct ArtworkRequest {
        let request:IllustrationRequest
        var completion:CheckedContinuation<GeneratedArtwork,Error>?
    }
    var requests:[ReplyRequest]=[]
    var artworkRequests:[ArtworkRequest]=[]
    func moderate(_ text:String) async throws -> Bool {true}
    func assessSafety(_ text:String,scope:SafetyReviewScope) async throws -> SafetyAssessment {SafetyAssessment(decision:.allow)}
    func respond(input:[[String:Any]],instructions:String,tools:[[String:Any]],allowTools:Bool) async throws -> ModelOutput {
        try await respondStreaming(input:input,instructions:instructions,tools:tools,allowTools:allowTools,onReply:{_ in})
    }
    func respondStreaming(input:[[String:Any]],instructions:String,tools:[[String:Any]],allowTools:Bool,onReply:@escaping @MainActor (String) async throws -> Void) async throws -> ModelOutput {
        try await withCheckedThrowingContinuation {requests.append(ReplyRequest(input:input,onReply:onReply,completion:$0))}
    }
    func illustrate(_ request:IllustrationRequest) async throws -> GeneratedArtwork {
        request.progress?("莉莉在画画…")
        return try await withCheckedThrowingContinuation {artworkRequests.append(ArtworkRequest(request:request,completion:$0))}
    }
    func emit(_ index:Int,_ text:String) async throws {try await requests[index].onReply(text)}
    func finish(_ index:Int,_ text:String,title:String="",state:String="") {
        let reply=PartnerReply(reply:text,suggestions:[],narrative:!state.isEmpty,storyTitle:title,storyState:state)
        let output=ModelOutput(items:[],text:String(decoding:try! JSONEncoder().encode(reply),as:UTF8.self))
        let completion=requests[index].completion;requests[index].completion=nil;completion?.resume(returning:output)
    }
    func fail(_ index:Int) {
        let completion=requests[index].completion;requests[index].completion=nil
        completion?.resume(throwing:PartnerError.message("测试连接暂时断开，请重试。"))
    }
    func finishArtwork(_ index:Int,_ result:GeneratedArtwork) {
        let completion=artworkRequests[index].completion;artworkRequests[index].completion=nil;completion?.resume(returning:result)
    }
    func releaseAll() {
        for index in requests.indices {
            let completion=requests[index].completion;requests[index].completion=nil;completion?.resume(throwing:CancellationError())
        }
        for index in artworkRequests.indices {
            let completion=artworkRequests[index].completion;artworkRequests[index].completion=nil;completion?.resume(throwing:CancellationError())
        }
    }
}

@MainActor func backgroundWait(_ condition:()->Bool) async throws {
    let deadline=Date().addingTimeInterval(3)
    while !condition() {
        guard Date()<deadline else {throw PartnerError.message("TEST: background event did not arrive")}
        try await Task.sleep(nanoseconds:2_000_000)
    }
}
