/*
 * Copyright (C) 2021 Lightstreamer Srl
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import Foundation
//import Alamofire

typealias HTTPFactoryService = (NSRecursiveLock, String,
                                String,
                                [String:String],
                                @escaping (LsHttpClient, String) -> Void,
                                @escaping (LsHttpClient, String) -> Void,
                                @escaping (LsHttpClient) -> Void) -> LsHttpClient

func createHTTP(_ lock: NSRecursiveLock, _ url: String,
                body: String,
                headers: [String:String],
                onText: @escaping (LsHttpClient, String) -> Void,
                onError: @escaping (LsHttpClient, String) -> Void,
                onDone: @escaping (LsHttpClient) -> Void) -> LsHttpClient {
    return LsHttp(lock, url,
                  body: body,
                  headers: headers,
                  onText: onText,
                  onError: onError,
                  onDone: onDone)
}

protocol LsHttpClient: AnyObject {
    var disposed: Bool { get }
    func dispose()
}

/// Delegate for URLSession
private class LsHttpSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let lock = NSRecursiveLock()
    private weak var session: LsHttpSession?
    
    func setSession(_ session: LsHttpSession) {
        synchronized {
            self.session = session
        }
    }
    
    func getSession() -> LsHttpSession? {
        synchronized {
            return self.session
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let taskWrapper = getSession()?.getWrapper(dataTask) else { return }
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            taskWrapper.getDelegate()?.onTaskError("Unexpected response type")
            return
        }
        if !(200...299).contains(response.statusCode) {
            completionHandler(.cancel)
            taskWrapper.getDelegate()?.onTaskError("Unexpected HTTP status code:\(response.statusCode)")
        } else {
            completionHandler(.allow)
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let taskWrapper = getSession()?.getWrapper(dataTask) else { return }
        if let txt = String(data: data, encoding: .utf8) {
            if streamLogger.isDebugEnabled {
                streamLogger.debug("HTTP event: text(\(txt))")
            }
            taskWrapper.getDelegate()?.onTaskText(txt)
        } else {
            taskWrapper.getDelegate()?.onTaskError("Unable to decode received data as UTF-8: \(data)")
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let task = task as? URLSessionDataTask else {
            assert(false, "Expected task of type URLSessionDataTask")
            return
        }
        guard let taskWrapper = getSession()?.getWrapper(task) else { return }
        if let error = error {
            if streamLogger.isDebugEnabled {
                streamLogger.debug("HTTP event: error(\(error.localizedDescription))")
            }
            taskWrapper.getDelegate()?.onTaskError(error.localizedDescription)
        } else {
            if streamLogger.isDebugEnabled {
                streamLogger.debug("HTTP event: complete")
            }
            taskWrapper.getDelegate()?.onTaskDone()
        }
    }
    
    private func synchronized<T>(block: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return block()
    }
}

/// Wrapper of URLSession
private class LsHttpSession: NSObject, URLSessionWebSocketDelegate {
    public static let shared = LsHttpSession()
    
    private let lock = NSRecursiveLock()
    private let urlSession: URLSession
    // URLSessionDataTask does not notify when portions of data arrive.
    // To track these events, a URLSessionTaskDelegate is attached to URLSession.
    // When URLSession triggers such an event for a URLSessionDataTask,
    // this map helps retrieve the corresponding LsHttpTask wrapper.
    private var taskMap = [URLSessionDataTask: LsHttpTask]()
    private var delegate = LsHttpSessionDelegate()
    
    public override init() {
        urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        super.init()
        delegate.setSession(self)
    }
    
    public func create(with request: URLRequest) -> LsHttpTask {
        synchronized {
            let task = urlSession.dataTask(with: request)
            return LsHttpTask(task: task, session: self)
        }
    }
    
    func setWrapper(task: URLSessionDataTask, wrapper: LsHttpTask) {
        synchronized {
            taskMap[task] = wrapper
        }
    }
    
    func getWrapper(_ task: URLSessionDataTask) -> LsHttpTask? {
        synchronized {
            return taskMap[task]
        }
    }
    
    func disposeWrapper(_ task: URLSessionDataTask) {
        synchronized {
            taskMap.removeValue(forKey: task)
            return
        }
    }
    
    private func synchronized<T>(block: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return block()
    }
}

/// Wrapper of URLSessionDataTask
private class LsHttpTask {
    private let lock = NSRecursiveLock()
    private let session: LsHttpSession
    private let task: URLSessionDataTask
    private var delegate: LsHttpTaskDelegate?
    
    public init(task: URLSessionDataTask, session: LsHttpSession) {
        self.session = session
        self.task = task
        session.setWrapper(task: task, wrapper: self)
    }
    
    public func setDelegate(_ delegate: LsHttpTaskDelegate) {
        synchronized {
            self.delegate = delegate
        }
    }
    
    public func getDelegate() -> LsHttpTaskDelegate? {
        synchronized {
            return self.delegate
        }
    }
    
    public func open() {
        task.resume()
    }
    
    public func cancel() {
        task.cancel()
        session.disposeWrapper(task)
    }
    
    private func synchronized<T>(block: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return block()
    }
}

/// Delegate responsible for publishing events from LsHttpTask
private protocol LsHttpTaskDelegate: AnyObject {
    func onTaskText(_ chunk: String)
    func onTaskError(_ error: String)
    func onTaskDone()
}

class LsHttp: LsHttpClient, LsHttpTaskDelegate {
    let lock: NSRecursiveLock
    private let request: LsHttpTask
    let assembler = LineAssembler()
    let onText: (LsHttp, String) -> Void
    let onError: (LsHttp, String) -> Void
    let onDone: (LsHttp) -> Void
    var m_disposed = false
  
    init(_ lock: NSRecursiveLock, _ url: String,
         body: String,
         headers: [String:String] = [:],
         onText: @escaping (LsHttp, String) -> Void,
         onError: @escaping (LsHttp, String) -> Void,
         onDone: @escaping (LsHttp) -> Void) {
        self.lock = lock
        self.onText = onText
        self.onError = onError
        self.onDone = onDone
        var headers = headers
        headers["Content-Type"] = "text/plain; charset=utf-8"
        if streamLogger.isDebugEnabled {
            if headers.isEmpty {
                streamLogger.debug("HTTP sending: \(url) \(String(reflecting: body))")
            } else {
                streamLogger.debug("HTTP sending: \(url) \(String(reflecting: body)) \(headers)")
            }
        }
        /*
        request = AF.streamRequest(url, method: .post, headers: HTTPHeaders(headers)) { urlRequest in
            urlRequest.httpBody = Data(body.utf8)
        }
        request.validate().responseStreamString(on: defaultQueue, stream: { [weak self] e in self?.onEvent(e) })
        */
        var urlRequest = URLRequest(url: URL(string: url)!)
        urlRequest.httpMethod = "POST"
        for (key, val) in headers {
            urlRequest.setValue(val, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = Data(body.utf8)
        self.request = LsHttpSession.shared.create(with: urlRequest)
        request.setDelegate(self)
        request.open()
    }
    
    var disposed: Bool {
        synchronized {
            m_disposed
        }
    }
    
    func dispose() {
        synchronized {
            if streamLogger.isDebugEnabled {
                streamLogger.debug("HTTP disposing")
            }
            m_disposed = true
            request.cancel()
        }
    }
    
    func onTaskText(_ chunk: String) {
        defaultQueue.async { [weak self] in
            guard let self = self else { return }
            for line in self.assembler.process(chunk) {
                onText(self, line)
            }
        }
    }
    
    func onTaskError(_ error: String) {
        defaultQueue.async { [weak self] in
            guard let self = self else { return }
            onError(self, error)
        }
    }
    
    func onTaskDone() {
        defaultQueue.async { [weak self] in
            guard let self = self else { return }
            onDone(self)
        }
    }
        
    /*
    private func onEvent(_ stream: DataStreamRequest.Stream<String, Never>) {
        synchronized {
            guard !m_disposed else {
                return
            }
            if streamLogger.isDebugEnabled {
                switch stream.event {
                case let .stream(result):
                    switch result {
                    case let .success(chunk):
                        streamLogger.debug("HTTP event: text(\(String(reflecting: chunk)))")
                    }
                case let .complete(completion):
                    if let error = completion.error {
                        streamLogger.debug("HTTP event: error(\(error.errorDescription ?? "unknown error"))")
                    } else {
                        streamLogger.debug("HTTP event: complete")
                    }
                }
            }
            switch stream.event {
            case let .stream(result):
                switch result {
                case let .success(chunk):
                    for line in self.assembler.process(chunk) {
                        onText(self, line)
                    }
                }
            case let .complete(completion):
                if let error = completion.error {
                    onError(self, error.localizedDescription)
                } else {
                    onDone(self)
                }
            }
        }
    }
    */
    
    private func synchronized<T>(block: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return block()
    }
}
