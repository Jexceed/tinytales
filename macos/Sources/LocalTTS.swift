import Foundation

enum AppResources {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.jexceed.tinytales", isDirectory: true)
    }
}

enum SpeechSegments {
    static func requests(_ text:String,cloud:Bool)->[String] { text.isEmpty ? [] : (cloud ? [text] : split(text,limit:160)) }
    static func split(_ text: String, limit: Int = 70) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = [], current = ""
        for character in text {
            current.append(character)
            if current.count >= limit {
                if let boundary = current.lastIndex(where: { "，。！？!?；;、：: \n".contains($0) }) {
                    let after = current.index(after:boundary)
                    result.append(String(current[..<after])); current = String(current[after...])
                } else { result.append(current); current = "" }
            } else if current.count >= 30 && "。！？!?\n".contains(character) { result.append(current); current = "" }
        }
        if !current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { result.append(current) }
        return result
    }
}
@MainActor final class LocalTTSClient {
    let engineRoot: URL
    let resources: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var workerID = UUID()
    var onStatus: ((String) -> Void)?
    private(set) var ready = false
    static func discover(supportDirectory: URL = AppResources.supportDirectory) -> URL? {
        let root = supportDirectory.appendingPathComponent("local-tts", isDirectory: true)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path,
              let data = try? Data(contentsOf: root.appendingPathComponent("runtime.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any], manifest["layoutVersion"] as? Int == 1,
              FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(".venv/bin/python").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("checkpoints/F5TTS_v1_Base/model_1250000.safetensors").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("checkpoints/vocos-mel-24khz/pytorch_model.bin").path) else { return nil }
        return root
    }
    init(engineRoot: URL, resources: URL) { self.engineRoot = engineRoot; self.resources = resources }
    func start() throws {
        if process?.isRunning == true { return }
        let worker = resources.appendingPathComponent("TTS/f5_worker.py")
        guard FileManager.default.fileExists(atPath: worker.path) else { throw PartnerError.message("本地语音组件还没有打包完整。") }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        let id = UUID(); workerID = id
        process.executableURL = engineRoot.appendingPathComponent(".venv/bin/python")
        process.currentDirectoryURL = engineRoot
        process.arguments = ["-I", "-u", worker.path, "--engine-root", engineRoot.path, "--reference", resources.appendingPathComponent("TTS/reference.wav").path, "--reference-text", resources.appendingPathComponent("TTS/reference.txt").path]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let inherited = Set(["HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "USER", "LOGNAME"])
        var environment = ProcessInfo.processInfo.environment.filter { inherited.contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HOME"] = engineRoot.appendingPathComponent("cache/huggingface").path
        environment["TORCH_HOME"] = engineRoot.appendingPathComponent("cache/torch").path
        environment["MPLCONFIGDIR"] = engineRoot.appendingPathComponent("cache/matplotlib").path
        environment["XDG_CACHE_HOME"] = engineRoot.appendingPathComponent("cache").path
        process.environment = environment
        stdout.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            Task { @MainActor in if !data.isEmpty, self?.workerID == id { self?.receive(data) } }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in if self?.workerID == id { self?.failed() } } }
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        ready = false; onStatus?("正在加载本地 F5 语音模型")
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: 0..<newline); buffer.removeSubrange(0...newline)
            guard let result = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = result["type"] as? String else { continue }
            if type == "ready" { ready = true; onStatus?("F5 本地神经语音已就绪"); continue }
            if type == "fatal" { failed(); continue }
            guard let id = result["id"] as? String, let continuation = pending.removeValue(forKey: id) else { continue }
            if type == "audio", let wav = result["wav"] as? String, let bytes = Data(base64Encoded: wav), bytes.count > 44 { continuation.resume(returning: bytes) }
            else { continuation.resume(throwing: PartnerError.message("本地神经语音暂时没有准备好，改用系统声音。")) }
        }
    }
    func synthesize(_ text: String) async throws -> Data {
        try Task.checkCancellation(); try start()
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                let request = try JSONSerialization.data(withJSONObject: ["id": id, "text": text]) + Data([10])
                guard let input else { throw PartnerError.message("本地语音进程暂不可用。") }
                try input.write(contentsOf: request)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    if let value = self?.pending.removeValue(forKey: id) { value.resume(throwing: PartnerError.message("本地语音生成等得有点久，改用系统声音。")) }
                }
            } catch { pending.removeValue(forKey: id)?.resume(throwing: PartnerError.message("本地语音进程暂不可用。")) }
        }
    }
    func cancelPending() { let values = Array(pending.values); pending.removeAll(); for value in values { value.resume(throwing: CancellationError()) } }
    private func failed() {
        workerID = UUID()
        ready = false; onStatus?("本地 F5 暂不可用，可使用系统优质声音")
        let values = Array(pending.values); pending.removeAll()
        for value in values { value.resume(throwing: PartnerError.message("本地语音暂不可用，改用系统声音。")) }
        output?.readabilityHandler = nil; input = nil; output = nil; buffer.removeAll(); process?.terminate(); process = nil
    }
    func shutdown() {
        workerID = UUID()
        cancelPending(); output?.readabilityHandler = nil
        if process?.isRunning == true { try? input?.write(contentsOf: Data("{\"type\":\"shutdown\"}\n".utf8)); process?.terminate() }
        process = nil; input = nil; output = nil; ready = false
    }
}
