import Foundation

@MainActor protocol TeacherSpeech:AnyObject {
    func prepare() async throws
    func speak(_ text:String,speaker:String,onChunk:@escaping @MainActor (Data)->Void) async throws
}

/// One offline model process shared by narration, previews and the telephone.
@MainActor final class TeacherSpeechClient:TeacherSpeech {
    private let root:URL
    private let worker:URL
    private var process:Process?
    private var input:FileHandle?
    private var output:FileHandle?
    private var buffer=Data()
    private var generation=UUID()
    private var ready=false
    private var waiters:[UUID:CheckedContinuation<Void,Error>]=[:]
    private var pending:(id:String,continuation:CheckedContinuation<Void,Error>,chunk:@MainActor (Data)->Void)?
    private var startupTimeout:Task<Void,Never>?
    private var speechTimeout:Task<Void,Never>?

    static func discover(support:URL=AppResources.supportDirectory,resources:URL?=Bundle.main.resourceURL)->TeacherSpeechClient? {
        let root=support.appendingPathComponent("qwen-tts",isDirectory:true)
        guard let resources else{return nil}
        let worker=resources.appendingPathComponent("TTS/qwen_worker.py")
        guard root.standardizedFileURL==root.resolvingSymlinksInPath(),
              FileManager.default.isExecutableFile(atPath:root.appendingPathComponent(".venv/bin/python").path),
              FileManager.default.fileExists(atPath:root.appendingPathComponent("model/model.safetensors").path),
              FileManager.default.fileExists(atPath:root.appendingPathComponent("model/speech_tokenizer/model.safetensors").path),
              FileManager.default.fileExists(atPath:worker.path) else{return nil}
        return TeacherSpeechClient(root:root,worker:worker)
    }
    init(root:URL,worker:URL) {self.root=root;self.worker=worker}
    func prepare() async throws {
        try Task.checkCancellation()
        if ready{return}
        let ticket=UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                waiters[ticket]=continuation
                do {try start()}catch{fail()}
            }
            try Task.checkCancellation()
        } onCancel: {Task {@MainActor [weak self] in self?.waiters.removeValue(forKey:ticket)?.resume(throwing:CancellationError())}}
    }
    private func start() throws {
        guard process?.isRunning != true else{return}
        let child=Process(),stdin=Pipe(),stdout=Pipe();let id=generation
        child.executableURL=root.appendingPathComponent(".venv/bin/python")
        child.currentDirectoryURL=root
        child.arguments=["-I","-u",worker.path,"--engine-root",root.path]
        let inherited=Set(["HOME","USER","LOGNAME","LANG","LC_ALL","LC_CTYPE","TMPDIR"])
        var environment=ProcessInfo.processInfo.environment.filter{inherited.contains($0.key)}
        environment["PATH"]="/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HF_HUB_OFFLINE"]="1";environment["TRANSFORMERS_OFFLINE"]="1"
        environment["TOKENIZERS_PARALLELISM"]="false"
        environment["HF_HOME"]=root.appendingPathComponent("cache").path
        child.environment=environment
        child.standardInput=stdin;child.standardOutput=stdout;child.standardError=FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler={[weak self] file in
            let bytes=file.availableData
            Task {@MainActor in guard let self,self.generation==id,!bytes.isEmpty else{return};self.receive(bytes)}
        }
        child.terminationHandler={[weak self] _ in Task {@MainActor in guard let self,self.generation==id else{return};self.fail()}}
        try child.run();process=child;input=stdin.fileHandleForWriting;output=stdout.fileHandleForReading
        startupTimeout=Task {try? await Task.sleep(nanoseconds:45_000_000_000);if !Task.isCancelled,self.generation==id,!self.ready {self.fail()}}
    }
    func speak(_ text:String,speaker:String,onChunk:@escaping @MainActor (Data)->Void) async throws {
        try await prepare();try Task.checkCancellation()
        if let old=pending?.id {cancel(old)}
        let id=UUID().uuidString
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                pending=(id,continuation,onChunk)
                do {try send(["type":"speak","id":id,"text":text,"speaker":speaker,"instructions":VoiceStyle.localDelivery])}
                catch {fail();return}
                speechTimeout=Task {try? await Task.sleep(nanoseconds:120_000_000_000);if !Task.isCancelled,self.pending?.id==id {self.fail()}}
            }
        } onCancel: {Task {@MainActor [weak self] in self?.cancel(id)}}
    }
    private func send(_ request:[String:Any]) throws {
        guard let input else{throw PartnerError.message("中文声音还没准备好。")}
        try input.write(contentsOf:JSONSerialization.data(withJSONObject:request)+Data([10]))
    }
    private func cancel(_ id:String) {
        guard pending?.id==id else{return}
        try? send(["type":"cancel","id":id]);speechTimeout?.cancel();speechTimeout=nil
        let value=pending;pending=nil;value?.continuation.resume(throwing:CancellationError())
    }
    private func receive(_ bytes:Data) {
        buffer.append(bytes)
        while let end=buffer.firstIndex(of:10) {
            let line=Data(buffer[..<end]);buffer.removeSubrange(...end)
            guard let event=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any],let type=event["type"] as? String else{continue}
            if type=="ready" {
                guard event["sample_rate"] as? Int==24000 else{fail();return}
                ready=true;startupTimeout?.cancel();startupTimeout=nil
                let values=waiters.values;waiters=[:];for waiter in values{waiter.resume()};continue
            }
            if type=="fatal" {fail();return}
            guard let current=pending,event["id"] as? String==current.id else{continue}
            if type=="chunk",let encoded=event["pcm"] as? String,let pcm=Data(base64Encoded:encoded),!pcm.isEmpty {current.chunk(pcm)}
            else if type=="done" {pending=nil;speechTimeout?.cancel();speechTimeout=nil;current.continuation.resume()}
            else if type=="error" {pending=nil;speechTimeout?.cancel();speechTimeout=nil;current.continuation.resume(throwing:PartnerError.message("这句话的中文声音没有生成好，请再试一次。"))}
        }
    }
    private func fail() {
        generation=UUID();ready=false;startupTimeout?.cancel();speechTimeout?.cancel()
        let error=PartnerError.message("中文声音暂时没有准备好，请重新试一次。")
        let values=waiters.values;waiters=[:];for waiter in values{waiter.resume(throwing:error)}
        let value=pending;pending=nil;value?.continuation.resume(throwing:error)
        output?.readabilityHandler=nil;try? input?.close();input=nil;output=nil;buffer=Data()
        if process?.isRunning==true {process?.terminate()};process=nil
    }
}
