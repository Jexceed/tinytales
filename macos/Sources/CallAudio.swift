import Foundation
import AVFoundation

@MainActor final class MicrophoneAuthorization {
    static let shared = MicrophoneAuthorization()
    private let status: () -> AVAuthorizationStatus
    private let request: () async -> Bool
    private var pending: Task<Bool, Never>?
    init(status: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }, request: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.status = status; self.request = request
    }
    func obtain() async -> Bool {
        switch status() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            if let pending { return await pending.value }
            let task = Task { await request() }; pending = task
            let result = await task.value; pending = nil; return result
        @unknown default: return false
        }
    }
}

@MainActor protocol CallAudio: AnyObject {
    var onMicrophone: ((Data) -> Void)? { get set }
    var onDrained: ((String) -> Void)? { get set }
    var onInputLevel: ((Double) -> Void)? { get set }
    var onOutputLevel: ((Double) -> Void)? { get set }
    var muted: Bool { get set }
    var playedMilliseconds: Int { get }
    func start() throws
    func beginOutput(itemID: String)
    func enqueue(_ pcm: Data)
    func outputEnded()
    func pauseOutput()
    func resumeOutput()
    func stopOutput()
    func stop()
}
/// One continuously running, echo-cancelled input/output graph for a phone call.
@MainActor final class NativeCallAudio: CallAudio {
    var onMicrophone: ((Data) -> Void)?
    var onDrained: ((String) -> Void)?
    var onInputLevel: ((Double) -> Void)?
    var onOutputLevel: ((Double) -> Void)?
    var muted = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var outputID = ""
    private var outputGeneration = UUID()
    private var inputGeneration = UUID()
    private var pending = 0
    private var ended = false
    private var receivedFrames = 0
    private var startFrame: AVAudioFramePosition = 0
    private var outputPaused=false
    private var pausedMilliseconds=0
    private(set) var diagnostics: [String: Any] = [:]
    var isRunning: Bool { engine?.isRunning == true }
    var isOutputPlaying:Bool {player?.isPlaying == true}
    var pendingPlaybackBuffers:Int {pending}
    private func formatDetails(_ format: AVAudioFormat) -> [String: Any] { ["sampleRate": format.sampleRate, "channels": format.channelCount, "interleaved": format.isInterleaved] }
    var playedMilliseconds: Int {
        if outputPaused{return pausedMilliseconds}
        guard let player, let time = player.lastRenderTime, let clock = player.playerTime(forNodeTime: time) else { return 0 }
        return max(0, min(receivedFrames * 1000 / 24000, Int(clock.sampleTime - startFrame) * 1000 / Int(clock.sampleRate)))
    }
    func start() throws {
        stop(); muted = false
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        var tapped = false
        diagnostics = ["stage": "devices"]
        do {
            // Recreate the voice-processing I/O unit before reading its hardware
            // formats. A newly created plain I/O node can still report zero
            // channels immediately after a previous voice-processing call ends.
            diagnostics["stage"]="voice-processing"
            try engine.inputNode.setVoiceProcessingEnabled(true)
            let input = engine.inputNode, output = engine.outputNode
            let inputHardware = input.inputFormat(forBus: 0), outputHardware = output.outputFormat(forBus: 0)
            diagnostics["inputHardwareBeforeStart"]=formatDetails(inputHardware)
            diagnostics["inputClientBeforeStart"]=formatDetails(input.outputFormat(forBus:0))
            diagnostics["outputHardwareBeforeStart"]=formatDetails(outputHardware)
            guard inputHardware.sampleRate > 0, inputHardware.channelCount > 0 else { throw PartnerError.message("没有找到可用的麦克风，请检查系统的声音输入设置。") }
            guard outputHardware.sampleRate > 0, outputHardware.channelCount > 0 else { throw PartnerError.message("没有找到可用的扬声器，请检查系统的声音输出设置。") }
            input.isVoiceProcessingAGCEnabled=true
            // VoiceProcessingIO needs a coherent I/O clock. A 24 kHz player must
            // not select the device-side format while the microphone stays at
            // AVAudioEngine's initial 44.1 kHz. The mixer resamples model output;
            // the input converter produces 24 kHz PCM for the wire separately.
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputHardware.sampleRate, channels: 1, interleaved: false),
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: source, to: target) else { throw PartnerError.message("这组音频设备暂时无法用于通话，请换一个输入或输出设备。") }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            engine.connect(engine.mainMixerNode, to: output, format: source)
            diagnostics = ["stage": "start", "input": formatDetails(source), "inputHardware": formatDetails(inputHardware), "outputHardware": formatDetails(outputHardware), "mixerOutput": formatDetails(engine.mainMixerNode.outputFormat(forBus: 0)), "playback": formatDetails(playbackFormat), "wireInput": formatDetails(target), "voiceProcessing": input.isVoiceProcessingEnabled,"automaticGainControl":input.isVoiceProcessingAGCEnabled,"voiceInputMuted":input.isVoiceProcessingInputMuted]
            let generation = inputGeneration
            input.installTap(onBus: 0, bufferSize: 960, format: source) { [weak self] input, _ in
                let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24000 / source.sampleRate) + 32)
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var supplied = false; var conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return input
                }
                guard conversionError == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
                let data = Data(bytes: samples, count: Int(output.frameLength) * 2)
                Task { @MainActor in
                    guard let self, self.inputGeneration == generation, self.isRunning, !self.muted else { return }
                    self.onInputLevel?(AudioMeter.level(data)); self.onMicrophone?(data)
                }
            }
            tapped = true
            try engine.start(); player.play()
            self.engine = engine; self.player = player; diagnostics["stage"] = "running"
            diagnostics["input"] = formatDetails(input.outputFormat(forBus: 0))
            diagnostics["outputClient"] = formatDetails(output.inputFormat(forBus: 0))
        } catch {
            diagnostics["errorDomain"] = (error as NSError).domain; diagnostics["errorCode"] = (error as NSError).code
            player.stop(); if tapped { engine.inputNode.removeTap(onBus: 0) }; engine.stop()
            if let message = error as? PartnerError { throw message }
            throw PartnerError.message("通话声音暂时没有接通，请重新点一次电话。")
        }
    }
    func beginOutput(itemID: String) {
        if outputID == itemID { return }
        stopOutput(); outputID = itemID
        if let player, let time = player.lastRenderTime, let clock = player.playerTime(forNodeTime: time) { startFrame = clock.sampleTime }
    }
    func enqueue(_ pcm: Data) {
        guard let player, pcm.count >= 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(pcm.count/2)),
              let samples = buffer.floatChannelData?[0] else { return }
        let bytes = [UInt8](pcm); buffer.frameLength = AVAudioFrameCount(bytes.count/2)
        for i in 0..<Int(buffer.frameLength) { samples[i] = Float(Int16(bitPattern: UInt16(bytes[i*2]) | UInt16(bytes[i*2+1]) << 8)) / 32768 }
        let level = AudioMeter.level(pcm)
        if pending == 0 { onOutputLevel?(level) }
        receivedFrames += Int(buffer.frameLength); pending += 1; let id = outputGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in guard let self, self.outputGeneration == id else { return }; self.onOutputLevel?(level); self.pending -= 1; if self.pending == 0 && self.ended && !self.outputPaused { self.onDrained?(self.outputID) } }
        }
        if !player.isPlaying && !outputPaused { player.play() }
    }
    func outputEnded() { ended = true; if pending == 0 && !outputPaused { onDrained?(outputID) } }
    func pauseOutput() {
        guard !outputPaused else{return}
        pausedMilliseconds=playedMilliseconds;outputPaused=true;player?.pause();onOutputLevel?(0)
    }
    func resumeOutput() {
        guard outputPaused else{return}
        outputPaused=false;player?.play()
        if let player,let time=player.lastRenderTime,let clock=player.playerTime(forNodeTime:time) {
            startFrame=clock.sampleTime-AVAudioFramePosition(Double(pausedMilliseconds)*clock.sampleRate/1000)
        }
        if pending==0 && ended {onDrained?(outputID)}
    }
    func stopOutput() {
        outputPaused=false;pausedMilliseconds=0
        outputGeneration = UUID(); onOutputLevel?(0); player?.stop(); player?.play()
        pending = 0; ended = false; receivedFrames = 0; startFrame = 0; outputID = ""
    }
    func stop() {
        outputPaused=false;pausedMilliseconds=0
        inputGeneration = UUID(); outputGeneration = UUID(); onInputLevel?(0); onOutputLevel?(0)
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        player?.stop(); player = nil; engine = nil
        pending = 0; receivedFrames = 0; ended = false; outputID = ""
    }
}

enum AudioMeter {
    static func level(_ pcm: Data) -> Double {
        guard pcm.count >= 2 else { return 0 }
        let bytes = [UInt8](pcm); var total = 0.0
        for offset in stride(from: 0, to: bytes.count-1, by: 2) {
            let value = Double(Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8)) / 32768
            total += value * value
        }
        return min(1, sqrt(total / Double(bytes.count / 2)) * 5)
    }
}
