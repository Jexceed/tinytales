import Foundation

@MainActor func classicalKnowledgePhoneTestCases()->[(String,@MainActor () async throws -> Void)] {
    func fixture() async throws -> (RealtimeCall,TestWire) {
        let wire=TestWire()
        let connected=RealtimeCall(store:try phoneFixture(),wire:wire,audio:SilentCallAudio(),permission:{true},inputCommitDelay:0)
        try await connected.connect(history:[],microphone:false,greet:false)
        wire.emit(["type":"session.created"]);await settle();wire.emit(["type":"session.updated"]);await settle()
        return (connected,wire)
    }
    func response(_ wire:TestWire)->[String:Any] {wire.sent.last{$0["type"] as? String=="response.create"}?["response"] as? [String:Any] ?? [:]}
    return [
        ("CK-005 phone uses an uncertain poem reference without rewriting the user's words",{
            let (call,wire)=try await fixture();defer{call.hangUp()}
            try await call.sendText("我说的是许头望明月")
            let prompt=response(wire)["instructions"] as? String ?? ""
            try require(prompt.contains("possible_misheard_quote") && prompt.contains("举头望明月"),"phone lost the tentative poem reference")
            let input=wire.sent.compactMap{$0["item"] as? [String:Any]}.last{$0["role"] as? String=="user"}
            try require((input?["content"] as? [[String:Any]])?.first?["text"] as? String=="我说的是许头望明月","lookup silently rewrote the input")
        }),
        ("CK-004 phone text and transcribed requests receive references without leaking them to later turns",{
            let (call,wire)=try await fixture();defer{call.hangUp()}
            let session=wire.sent.first{$0["type"] as? String=="session.update"}?["session"] as? [String:Any] ?? [:]
            try require((session["instructions"] as? String ?? "").contains(ClassicalKnowledge.instructions),"phone rules differ from typed rules")
            try require((session["tools"] as? [[String:Any]] ?? []).contains{$0["name"] as? String=="lookup_classics"},"phone cannot use the knowledge tool")
            try await call.sendText("背一下静夜思")
            let prompt=response(wire)["instructions"] as? String ?? ""
            try require(prompt.contains("床前明月光") && prompt.contains(LilyPersona.description) && prompt.contains("电话交流"),"response references erased persona or call rules")
            try await call.sendText("你好")
            try require(response(wire)["instructions"]==nil,"the previous poem reference survived into another turn")
            wire.emit(["type":"input_audio_buffer.speech_started","item_id":"idiom"]);await settle()
            await wire.finishInput("idiom","给我解释拔苗助长")
            try require((response(wire)["instructions"] as? String ?? "").contains("公孙丑上"),"voice transcript did not use the same reference injection")
            try await call.sendText("讲一个关于植物的成语")
            try require((response(wire)["instructions"] as? String ?? "").contains("idiom-ya-miao-zhu-zhang"),"phone topic lookup still depended on model query wording")
        }),
        ("CK-004 phone function calls return curated text and provenance through the realtime wire",{
            let (call,wire)=try await fixture();defer{call.hangUp()}
            try await call.sendText("讲一首关于春天的诗")
            wire.emit(["type":"response.created","response":["id":"lookup-response"]]);await settle()
            wire.emit(["type":"response.done","response":["id":"lookup-response","status":"completed","output":[["type":"function_call","name":"lookup_classics","call_id":"lookup-1","arguments":"{\"query\":\"春天\",\"kind\":\"poem\"}"]]]]);await settle()
            try await waitFor({wire.sent.contains{($0["item"] as? [String:Any])?["call_id"] as? String=="lookup-1"}},seconds:1)
            let output=wire.sent.compactMap{$0["item"] as? [String:Any]}.first{$0["call_id"] as? String=="lookup-1"}?["output"] as? String ?? ""
            try require(output.contains("春眠不觉晓") && output.contains("孟浩然") && output.contains("KS1_08.pdf"),"realtime tool omitted the checked source")
            try require(wire.sent.filter{$0["type"] as? String=="response.create"}.count==2,"lookup did not continue the same reply")
        })
    ]
}
