import Foundation

/// Text-only input, audio-only output. Never opens or requests the microphone.
@MainActor final class RealtimeNarrator {
    private let wire: RealtimeWire
    private var continuation: CheckedContinuation<Data,Error>?
    private var timeout: Task<Void,Never>?
    private var text = ""
    private var voice = "shimmer"
    private var pcm = Data()
    private(set) var transcript = ""
    init(wire: RealtimeWire) {
        self.wire = wire
        wire.onEvent = { [weak self] event in Task { @MainActor in await self?.receive(event) } }
        wire.onError = { [weak self] _ in self?.finish(.failure(PartnerError.message("声音暂时没有连上。"))) }
    }
    func speak(_ text: String, voice: String) async throws -> Data {
        try Task.checkCancellation()
        self.text = text; self.voice = voice; pcm = Data(); transcript = ""
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; wire.connect()
                timeout = Task { try? await Task.sleep(nanoseconds:60_000_000_000); if !Task.isCancelled { self.finish(.failure(PartnerError.message("这段声音准备得有些久，请再试一次。"))) } }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }
    private var instructions: String {
        VoiceStyle.narration
    }
    private func receive(_ event: [String:Any]) async {
        guard continuation != nil else { return }
        do {
            switch event["type"] as? String {
            case "session.created":
                try await wire.send(["type":"session.update","session":["type":"realtime","model":"gpt-realtime-2.1-mini","instructions":instructions,"tools":[],"output_modalities":["audio"],"audio":["input":["turn_detection":NSNull()],"output":["format":["type":"audio/pcm","rate":24000],"voice":voice]]]])
            case "session.updated":
                try await wire.send(["type":"conversation.item.create","item":["type":"message","role":"user","content":[["type":"input_text","text":text]]]])
                try await wire.send(["type":"response.create","response":["instructions":instructions]])
            case "response.output_audio.delta":
                if let encoded=event["delta"] as? String,let bytes=Data(base64Encoded:encoded) { pcm.append(bytes) }
            case "response.output_audio_transcript.delta": transcript += event["delta"] as? String ?? ""
            case "response.output_audio_transcript.done": transcript = event["transcript"] as? String ?? transcript
            case "response.done":
                let result=event["response"] as? [String:Any] ?? [:]
                guard result["status"] as? String == "completed", pcm.count > 100, Self.normalized(transcript) == Self.normalized(text) else { throw PartnerError.message("朗读内容还没有对齐，请再试一次。") }
                finish(.success(Self.wave(pcm)))
            case "error": throw PartnerError.message("声音暂时没有准备好。")
            default: break
            }
        } catch { finish(.failure(error)) }
    }
    static func normalized(_ text:String)->String { String(text.filter { $0.isLetter || $0.isNumber }) }
    static func wave(_ pcm:Data)->Data {
        var data=Data("RIFF".utf8)
        func u32(_ value:UInt32){var n=value.littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)}}
        func u16(_ value:UInt16){var n=value.littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)}}
        u32(UInt32(pcm.count+36));data.append(Data("WAVEfmt ".utf8));u32(16);u16(1);u16(1);u32(24000);u32(48000);u16(2);u16(16);data.append(Data("data".utf8));u32(UInt32(pcm.count));data.append(pcm);return data
    }
    private func finish(_ result:Result<Data,Error>) {
        guard let continuation else { return }; self.continuation=nil
        timeout?.cancel();timeout=nil;wire.close();continuation.resume(with:result)
    }
}
