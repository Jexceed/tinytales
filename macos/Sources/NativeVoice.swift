import Foundation
import AVFoundation
import Combine

final class RecordingBuffer {
    private let lock = NSLock()
    private var bytes = Data()
    private var sampleRate: UInt32 = 48000
    func configure(rate: Double) { lock.lock(); defer { lock.unlock() }; bytes.removeAll(keepingCapacity: false); sampleRate = UInt32(rate) }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        var chunk = Data(capacity: Int(buffer.frameLength) * 2)
        for index in 0..<Int(buffer.frameLength) {
            var value = Int16(max(-1, min(1, samples[index])) * 32767).littleEndian
            withUnsafeBytes(of: &value) { chunk.append(contentsOf: $0) }
        }
        lock.lock(); defer { lock.unlock() }
        if bytes.count + chunk.count <= 7_900_000 { bytes.append(chunk) }
    }
    func wav() -> Data {
        lock.lock(); defer { lock.unlock() }
        var data = Data()
        func str(_ s: String) { data.append(Data(s.utf8)) }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(bytes.count + 36)); str("WAVEfmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16); str("data"); u32(UInt32(bytes.count)); data.append(bytes)
        bytes.removeAll(keepingCapacity: false)
        return data
    }
    func clear() { lock.lock(); defer { lock.unlock() }; bytes.removeAll(keepingCapacity: false) }
}
@MainActor final class NativeVoice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var recording = false
    @Published var speaking = false
    @Published var preparing = false
    @Published var backendStatus = "macOS 系统声音"
    @Published var voiceNotice = ""
    var cloudSpeech: (@MainActor (String) async throws -> Data)?
    var teacherSpeech:TeacherSpeech?
    private var style="shimmer"
    private var local: LocalTTSClient?
    private var backend = "auto"
    private var speechTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playback: CheckedContinuation<Void, Error>?
    private var speechGeneration = UUID()
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private let buffer = RecordingBuffer()
    private var timer: Task<Void, Never>?
    private var onReady: ((Data) -> Void)?
    override init() { super.init(); synthesizer.delegate = self }
    func configure(backend: String, warm: Bool = false, style:String="shimmer") {
        self.backend = backend;self.style=style
        if backend == "system" { local?.shutdown(); local = nil }
        if backend != "system", let root = LocalTTSClient.discover(), let resources = Bundle.main.resourceURL {
            if local?.engineRoot != root || local?.resources != resources {
                local?.shutdown()
                let client = LocalTTSClient(engineRoot: root, resources: resources)
                client.onStatus = { [weak self] status in self?.backendStatus = status }
                local = client
            }
            if local?.ready != true { backendStatus = "本地 F5 可用，正在等待预热" }
            if warm { do { try local?.start() } catch { backendStatus = "本地 F5 未能启动，使用系统优质声音" } }
        } else { local?.shutdown(); local = nil; backendStatus = backend == "local-f5" ? "本机未找到 F5 模型，使用系统优质声音" : "macOS 系统优质声音" }
        if backend != "system" && backend != "local-f5" && cloudSpeech != nil { backendStatus = "莉莉的亲和声音" }
        if backend=="auto",VoiceStyle.speaker(style) != nil {backendStatus=VoiceStyle.title(style)+" · 中文声音"}
    }
    func speak(_ text: String) {
        stopSpeaking()
        voiceNotice = ""
        if backend=="auto",let speaker=VoiceStyle.speaker(style) {
            guard let teacherSpeech else{voiceNotice="中文声音还没准备好，请重新打开应用。";return}
            let captured=speechGeneration;preparing=true
            speechTask=Task {
                do {
                    var pcm=Data()
                    try await teacherSpeech.speak(text,speaker:speaker){pcm.append($0)}
                    try Task.checkCancellation();guard captured==speechGeneration else{return}
                    guard !pcm.isEmpty else{throw PartnerError.message("这句话的中文声音没有生成好，请再试一次。")}
                    try await play(RealtimeNarrator.wave(pcm),generation:captured)
                    if captured==speechGeneration {preparing=false;speaking=false}
                }catch{
                    guard captured==speechGeneration,!(error is CancellationError) else{return}
                    preparing=false;speaking=false;voiceNotice=error.localizedDescription
                }
            }
            return
        }
        if backend != "system", (backend != "local-f5" && cloudSpeech != nil) || local != nil {
            let useCloud = backend != "local-f5" && cloudSpeech != nil
            let cloud = cloudSpeech, local = local
            let captured = speechGeneration
            preparing = true
            speechTask = Task {
                do {
                    for chunk in SpeechSegments.requests(text,cloud:useCloud) {
                        try Task.checkCancellation(); guard captured == speechGeneration else { return }
                        preparing = true
                        let data: Data
                        if useCloud, let cloud { data = try await cloud(chunk) }
                        else if let local { data = try await local.synthesize(chunk) }
                        else { throw PartnerError.message("声音暂时没有准备好。") }
                        try Task.checkCancellation(); guard captured == speechGeneration else { return }
                        try await play(data,generation:captured)
                    }
                    if captured == speechGeneration { speaking = false; preparing = false }
                } catch {
                    guard captured == speechGeneration, !(error is CancellationError) else { return }
                    preparing = false; speaking = false; voiceNotice = error.localizedDescription
                    systemSpeak(text)
                }
            }
            return
        }
        systemSpeak(text)
    }
    private func play(_ data:Data,generation:UUID) async throws {
        try Task.checkCancellation();guard generation==speechGeneration else{throw CancellationError()}
        preparing=false;speaking=true
        let audio=try AVAudioPlayer(data:data);audio.delegate=self;player=audio
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            playback=continuation
            if !audio.play() {playback=nil;continuation.resume(throwing:PartnerError.message("这段声音暂时无法播放。"))}
        }
    }
    private func systemSpeak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-CN" }.sorted { $0.quality.rawValue > $1.quality.rawValue }
        utterance.voice = voices.first ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.43; utterance.pitchMultiplier = 1.04
        speaking = true; synthesizer.speak(utterance)
    }
    func stopSpeaking() {
        speechGeneration = UUID(); speechTask?.cancel(); speechTask = nil; local?.cancelPending()
        player?.stop(); player = nil; playback?.resume(throwing: CancellationError()); playback = nil
        synthesizer.stopSpeaking(at: .immediate); speaking = false; preparing = false
    }
    func shutdown() { stopSpeaking(); cancelRecording(); local?.shutdown() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor in guard self.player === player else { return }; self.playback?.resume(returning: ()); self.playback = nil } }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { Task { @MainActor in guard self.player === player else { return }; self.playback?.resume(throwing: PartnerError.message("本地声音播放暂时中断。")); self.playback = nil } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor in if !self.synthesizer.isSpeaking { self.speaking = false } } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { Task { @MainActor in if !self.synthesizer.isSpeaking { self.speaking = false } } }
    func startRecording(onReady: @escaping (Data) -> Void) async throws {
        cancelRecording(); stopSpeaking()
        let allowed = await MicrophoneAuthorization.shared.obtain()
        try Task.checkCancellation()
        guard allowed else { throw PartnerError.message("麦克风还没有打开。可以在系统设置 → 隐私与安全性 → 麦克风中允许“小小故事屋”，也可以先用文字聊聊。") }
        let engine = AVAudioEngine(), input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PartnerError.message("暂时没有找到可用的麦克风。") }
        buffer.configure(rate: format.sampleRate)
        let capture = buffer
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { pcm, _ in capture.append(pcm) }
        do { engine.prepare(); try engine.start() } catch { input.removeTap(onBus: 0); buffer.clear(); throw PartnerError.message("麦克风暂时没有准备好，请检查输入设备。") }
        self.engine = engine; self.onReady = onReady; recording = true
        timer = Task { try? await Task.sleep(nanoseconds: 45_000_000_000); if !Task.isCancelled { finishRecording() } }
    }
    func finishRecording() {
        guard recording else { return }
        timer?.cancel(); timer = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil; recording = false
        let result = buffer.wav(), callback = onReady; onReady = nil
        callback?(result)
    }
    func cancelRecording() {
        timer?.cancel(); timer = nil; onReady = nil
        if recording { engine?.inputNode.removeTap(onBus: 0) }
        engine?.stop(); engine = nil; recording = false; buffer.clear()
    }
}
