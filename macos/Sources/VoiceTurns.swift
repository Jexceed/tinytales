import Foundation

/// This only delays an already pending submission while a remote VAD start is
/// in flight. It neither recognizes words nor grants permission to interrupt.
struct LocalSpeechContinuation {
    private var voicedSeconds=0.0
    private(set) var lastActivity = -Double.infinity
    mutating func observe(_ pcm:Data,now:Double=ProcessInfo.processInfo.systemUptime) {
        if AudioMeter.level(pcm)>=0.015 {
            voicedSeconds+=Double(pcm.count)/48_000
            if voicedSeconds>=0.08 {lastActivity=now}
        } else {voicedSeconds=0}
    }
    func remainingQuietTime(_ delay:UInt64,now:Double=ProcessInfo.processInfo.systemUptime)->Double {
        max(0,Double(delay)/1e9-(now-lastActivity))
    }
    mutating func reset() {voicedSeconds=0;lastActivity = -Double.infinity}
}

/// Input items can finish transcription out of order. Each item is accepted once,
/// and only completed, nonempty user turns authorize a response.
struct VoiceTurns {
    // ASR items are acoustic chunks, not complete conversational turns.
    static let continuationDelay:UInt64 = 1_600_000_000
    struct Segment {
        var id:String
        var committed=false
        var finished=false
        var accepted=false
        var consumed=false
        var overlapsPlayback=false
        var text=""
    }
    private(set) var segments:[Segment]=[]
    private(set) var speakingID:String?
    @discardableResult mutating func begin(_ id:String,overlap:Bool)->Bool {
        guard !segments.contains(where:{$0.id==id}) else{return false}
        segments.append(Segment(id:id,overlapsPlayback:overlap))
        speakingID=id;return true
    }
    mutating func commit(_ id:String) {
        if !segments.contains(where:{$0.id==id}) {segments.append(Segment(id:id))}
        if let i=segments.firstIndex(where:{$0.id==id}) {segments[i].committed=true}
    }
    mutating func stop(_ id:String) {if speakingID==id {speakingID=nil}}
    mutating func delta(_ id:String,_ text:String)->String? {
        guard let i=segments.firstIndex(where:{$0.id==id}),!segments[i].finished else{return nil}
        segments[i].text += text;return segments[i].text
    }
    mutating func preview(_ id:String,_ text:String) {
        if let i=segments.firstIndex(where:{$0.id==id}),!segments[i].finished {segments[i].text=text}
    }
    enum Result {case accepted(String),empty,echo,duplicate}
    mutating func finish(_ id:String,_ text:String,assistantTexts:[String])->Result {
        guard let i=segments.firstIndex(where:{$0.id==id}),!segments[i].finished else{return .duplicate}
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        segments[i].finished=true;segments[i].text=text
        if !text.contains(where:{$0.isLetter || $0.isNumber}) {return .empty}
        if segments[i].overlapsPlayback && Self.isEcho(text,of:assistantTexts) {return .echo}
        segments[i].accepted=true;return .accepted(text)
    }
    mutating func discard(_ id:String) {
        if let i=segments.firstIndex(where:{$0.id==id}) {segments[i].finished=true;segments[i].accepted=false}
        if speakingID==id {speakingID=nil}
    }
    var readySegments:[Segment]? {
        guard speakingID==nil,!segments.contains(where:{!$0.finished || ($0.accepted && !$0.committed)}) else{return nil}
        let ready=segments.filter{$0.accepted && !$0.consumed}
        guard !ready.isEmpty else{return nil}
        return ready
    }
    mutating func consumeReady()->[Segment]? {
        guard let ready=readySegments else{return nil}
        for i in segments.indices where segments[i].accepted && !segments[i].consumed {segments[i].consumed=true}
        return ready
    }
    var pendingTranscript:String {
        Self.join(segments.filter{!$0.consumed && (!$0.finished || $0.accepted)})
    }
    func earlierInTurn(before id:String)->String {
        Self.join(segments.prefix{$0.id != id}.filter{!$0.consumed && (!$0.finished || $0.accepted)})
    }
    func hasUnfinished(before id:String)->Bool {
        segments.prefix{$0.id != id}.contains{!$0.finished}
    }
    static func join(_ segments:[Segment])->String {
        segments.reduce("") { result,segment in
            let text=segment.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty else{return result}
            // Preserve recognizer punctuation; only restore a word boundary
            // between ASCII clauses, rather than adding Chinese line breaks.
            let space=result.unicodeScalars.last?.isASCII == true && text.unicodeScalars.first?.isASCII == true
            return result+(space ? " " : "")+text
        }
    }
    func isPending(_ id:String)->Bool {segments.contains{$0.id==id && !$0.finished}}
    var hasUnfinished:Bool {speakingID != nil || segments.contains{!$0.finished}}
    func overlapsPlayback(_ id:String)->Bool {segments.first{$0.id==id}?.overlapsPlayback ?? false}
    mutating func reset() {segments=[];speakingID=nil}
    static func normalized(_ text:String)->String {String(text.lowercased().filter{$0.isLetter || $0.isNumber})}
    static func isEcho(_ text:String,of candidates:[String])->Bool {
        let text=normalized(text)
        guard text.count>=8 else{return false}
        return candidates.contains { candidate in
            let candidate=normalized(candidate)
            return candidate.count>=8 && (candidate.contains(text) || (text.contains(candidate) && Double(candidate.count)/Double(text.count)>0.9))
        }
    }
    static func isStopRequest(_ text:String)->Bool {
        VoiceTurnPolicy.isControlOnly(text)
    }
}
