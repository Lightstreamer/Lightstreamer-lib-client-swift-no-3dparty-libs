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
//import Starscream

typealias WSFactoryService = (NSRecursiveLock, String,
            String,
            [String:String],
            @escaping (LsWebsocketClient) -> Void,
            @escaping (LsWebsocketClient, String) -> Void,
            @escaping (LsWebsocketClient, String) -> Void) -> LsWebsocketClient

func createWS(_ lock: NSRecursiveLock, _ url: String,
                      protocols: String,
                      headers: [String:String],
                      onOpen: @escaping (LsWebsocketClient) -> Void,
                      onText: @escaping (LsWebsocketClient, String) -> Void,
                      onError: @escaping (LsWebsocketClient, String) -> Void) -> LsWebsocketClient {
    return LsWebsocket(lock, url,
                       protocols: protocols,
                       headers: headers,
                       onOpen: onOpen,
                       onText: onText,
                       onError: onError)
}

protocol LsWebsocketClient: AnyObject {
    var disposed: Bool { get }
    func send(_ text: String)
    func dispose()
}

/// Delegate for URLSession
private class LsWebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate {
    private let lock = NSRecursiveLock()
    private weak var session: LsWebsocketSession?
    
    func setSession(_ session: LsWebsocketSession) {
        synchronized {
            self.session = session
        }
    }
    
    func getSession() -> LsWebsocketSession? {
        synchronized {
            return self.session
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard let taskWrapper = getSession()?.getWrapper(webSocketTask) else { return }
        if streamLogger.isDebugEnabled {
            streamLogger.debug("WS event: open")
        }
        taskWrapper.getDelegate()?.onTaskOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let taskWrapper = getSession()?.getWrapper(webSocketTask) else { return }
        if streamLogger.isDebugEnabled {
            streamLogger.debug("WS event: closed(\(closeCode) - \(String(describing: reason)))")
        }
        taskWrapper.getDelegate()?.onTaskError("unexpected disconnection: \(closeCode) - \(String(describing: reason))")
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
private class LsWebsocketSession: NSObject, URLSessionWebSocketDelegate {
    public static let shared = LsWebsocketSession()
    
    private let lock = NSRecursiveLock()
    private let urlSession: URLSession
    // URLSessionWebSocketTask does not provide event notifications for connection openings or disconnections.
    // To track these events, I attach a URLSessionWebSocketDelegate to URLSession.
    // When URLSession notifies such an event for a URLSessionWebSocketTask, this map helps retrieve the corresponding LsWebsocketTask wrapper.
    private var taskMap = [URLSessionWebSocketTask: LsWebsocketTask]()
    private var delegate = LsWebSocketSessionDelegate()
    
    public override init() {
        urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        super.init()
        delegate.setSession(self)
    }
    
    public func create(with request: URLRequest) -> LsWebsocketTask {
        synchronized {
            let task = urlSession.webSocketTask(with: request)
            return LsWebsocketTask(task: task, session: self)
        }
    }
    
    func setWrapper(task: URLSessionWebSocketTask, wrapper: LsWebsocketTask) {
        synchronized {
            taskMap[task] = wrapper
        }
    }
    
    func getWrapper(_ task: URLSessionWebSocketTask) -> LsWebsocketTask? {
        synchronized {
            return taskMap[task]
        }
    }
    
    func disposeWrapper(_ task: URLSessionWebSocketTask) {
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

/// Wrapper of URLSessionWebSocketTask
private class LsWebsocketTask {
    private let lock = NSRecursiveLock()
    private let session: LsWebsocketSession
    private let task: URLSessionWebSocketTask
    private var delegate: LsWebSocketTaskDelegate?
    
    public init(task: URLSessionWebSocketTask, session: LsWebsocketSession) {
        self.session = session
        self.task = task
        session.setWrapper(task: task, wrapper: self)
    }
    
    public func setDelegate(_ delegate: LsWebSocketTaskDelegate) {
        synchronized {
            self.delegate = delegate
        }
    }
    
    public func getDelegate() -> LsWebSocketTaskDelegate? {
        synchronized {
            return self.delegate
        }
    }
    
    public func connect() {
        task.resume()
        listen()
    }
    
    private func listen()  {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let chunk):
                    if streamLogger.isDebugEnabled {
                        streamLogger.debug("WS event: text(\(chunk))")
                    }
                    for line in chunk.split(separator: "\r\n") {
                        self.getDelegate()?.onTaskText(String(line))
                    }
                case .data(_):
                    fatalError("Unexpect message type")
                @unknown default:
                    fatalError("Unexpect message type")
                }
            case .failure(let error):
                if streamLogger.isDebugEnabled {
                    streamLogger.debug("WS event: error(\(error.localizedDescription))")
                }
                self.getDelegate()?.onTaskError(error.localizedDescription)
            }
            self.listen()
        }
    }
    
    public func disconnect() {
        task.cancel()
        session.disposeWrapper(task)
    }
    
    public func write(string text: String) {
        task.send(.string(text)) { [weak self] error in
            guard let error = error, let self = self else { return }
            self.getDelegate()?.onTaskError(error.localizedDescription)
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

/// Delegate responsible for publishing events from LsWebsocketTask
private protocol LsWebSocketTaskDelegate: AnyObject {
    func onTaskOpen()
    func onTaskText(_ text: String)
    func onTaskError(_ error: String)
}

class LsWebsocket: LsWebsocketClient, LsWebSocketTaskDelegate {
    let lock: NSRecursiveLock
    private let socket: LsWebsocketTask
    let onOpen: (LsWebsocket) -> Void
    let onText: (LsWebsocket, String) -> Void
    let onError: (LsWebsocket, String) -> Void
    var m_disposed = false
  
    init(_ lock: NSRecursiveLock, _ url: String,
         protocols: String,
         headers: [String:String] = [:],
         onOpen: @escaping (LsWebsocket) -> Void,
         onText: @escaping (LsWebsocket, String) -> Void,
         onError: @escaping (LsWebsocket, String) -> Void) {
        self.lock = lock
        self.onOpen = onOpen
        self.onText = onText
        self.onError = onError
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(protocols, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
        }
        if streamLogger.isDebugEnabled {
            streamLogger.debug("WS connecting: \(request) \(request.allHTTPHeaderFields ?? [:])")
        }
        /*
        socket = WebSocket(request: request)
        socket.callbackQueue = defaultQueue
        socket.onEvent = { [weak self] e in
            self?.onEvent(e)
        }
        socket.connect()
        */
        self.socket = LsWebsocketSession.shared.create(with: request)
        socket.setDelegate(self)
        socket.connect()
    }
    
    var disposed: Bool {
        synchronized {
            m_disposed
        }
    }

    func send(_ text: String) {
        synchronized {
            if streamLogger.isDebugEnabled {
                streamLogger.debug("WS sending: \(String(reflecting: text))")
            }
            socket.write(string: text)
        }
    }

    func dispose() {
        synchronized {
            if streamLogger.isDebugEnabled {
                streamLogger.debug("WS disposing")
            }
            m_disposed = true
            socket.disconnect()
        }
    }
    
    func onTaskOpen() {
        defaultQueue.async { [weak self] in
            guard let self = self else { return }
            onOpen(self)
        }
    }
    
    func onTaskText(_ text: String) {
        defaultQueue.async { [weak self] in
            guard let self = self else { return }
            onText(self, text)
        }
    }
    
    func onTaskError(_ error: String) {
        defaultQueue.async { [weak self] in
            guard let self = self else { return }
            onError(self, error)
        }
    }
    
    /*
    private func onEvent(_ event: WebSocketEvent) {
        synchronized {
            guard !m_disposed else {
                return
            }
            if streamLogger.isDebugEnabled {
                streamLogger.debug("WS event: \(event)")
            }
            switch event {
            case .connected(_):
                onOpen(self)
            case .text(let chunk):
                for line in chunk.split(separator: "\r\n") {
                    onText(self, String(line))
                }
            case .error(let error):
                onError(self, error?.localizedDescription ?? "n.a.")
            case .cancelled:
                onError(self, "unexpected cancellation")
            case let .disconnected(reason, code):
                onError(self, "unexpected disconnection: \(code) - \(reason)")
            default:
                break
            /*
            case .binary(let data):
                break
            case .ping(_):
                break
            case .pong(_):
                break
            case .viabilityChanged(_):
                break
            case .reconnectSuggested(_):
                break
            */
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
