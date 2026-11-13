import Foundation
import CFNetwork

@MainActor protocol RealtimeWire: AnyObject {
    var onEvent: (([String: Any]) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func connect()
    func send(_ event: [String: Any]) async throws
    func close()
}
@MainActor final class OpenAIRealtimeWire: RealtimeWire {
    var onEvent: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    private let key: String
    private let model:String
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiving: Task<Void, Never>?
    private var generation = UUID()
    private var sending:Task<Void,Never>?
    private var outbound:[(String,CheckedContinuation<Void,Error>)]=[]
    init(key: String,model:String = "gpt-realtime-2.1-mini") { self.key = key;self.model=model }
    func connect() {
        close(); let id = generation
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 20
        let env = ProcessInfo.processInfo.environment
        if let raw = env["HTTPS_PROXY"] ?? env["https_proxy"] ?? env["HTTP_PROXY"], let url = URL(string: raw), let host = url.host {
            config.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable: 1, kCFNetworkProxiesHTTPProxy: host, kCFNetworkProxiesHTTPPort: url.port ?? 80, kCFNetworkProxiesHTTPSEnable: 1, kCFNetworkProxiesHTTPSProxy: host, kCFNetworkProxiesHTTPSPort: url.port ?? 80]
        }
        let session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.session = session; self.socket = socket; socket.resume()
        receiving = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.generation == id else { return }
                    let data: Data
                    switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    self.onEvent?(event)
                }
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.onError?("电话暂时没有连上，请检查网络后重试。")
            }
        }
    }
    func send(_ event:[String:Any]) async throws {
        try Task.checkCancellation()
        guard socket != nil else{throw PartnerError.message("通话已经结束。")}
        let payload=String(decoding:try JSONSerialization.data(withJSONObject:event),as:UTF8.self)
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            outbound.append((payload,continuation));pump()
        }
    }
    private func pump() {
        guard sending==nil,let socket else{return};let id=generation
        sending=Task {[weak self] in
            guard let self else{return}
            defer{if self.generation==id {self.sending=nil}}
            while self.generation==id && !Task.isCancelled && !self.outbound.isEmpty {
                let (payload,continuation)=self.outbound.removeFirst()
                do {try await socket.send(.string(payload));continuation.resume()}
                catch {continuation.resume(throwing:error)}
            }
        }
    }
    func close() {
        generation = UUID(); receiving?.cancel(); receiving = nil
        sending?.cancel();sending=nil
        let waiting=outbound;outbound=[];for (_,continuation) in waiting {continuation.resume(throwing:CancellationError())}
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}
