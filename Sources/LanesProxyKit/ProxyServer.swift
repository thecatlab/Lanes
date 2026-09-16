import Foundation
import Network

public final class ProxyServer {
    private let queue = DispatchQueue(label: "com.nusaindah.Lanes.Proxy", qos: .userInitiated)
    private let directory: URL
    private let port: UInt16
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private var connections: [UUID: ProxyConnection] = [:]
    public var onReady: (() -> Void)?
    public var onFailure: ((Error) -> Void)?

    public init(directory: URL, port: UInt16) { self.directory = directory; self.port = port }
    public func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 512 else { connection.cancel(); return }
            let flow = ProxyConnection(client: connection, queue: self.queue, port: self.port,
                                       policy: { ProxyPolicy.read(from: self.directory) })
            self.connections[flow.id] = flow
            flow.onFinish = { [weak self] id in self?.connections.removeValue(forKey: id) }
            flow.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.heartbeat()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.heartbeat() }
                self.timer = timer; timer.resume()
                self.onReady?()
            case .failed(let error): self.onFailure?(error)
            default: break
            }
        }
        listener.start(queue: queue)
    }
    public func stop() {
        queue.async {
            self.timer?.cancel(); self.listener?.cancel()
            for flow in Array(self.connections.values) { flow.finish() }
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("status.json"))
        }
    }
    private func heartbeat() {
        if let data = try? JSONEncoder().encode(ProxyStatus(port: port)) {
            try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        }
        let policy = ProxyPolicy.read(from: directory)
        // Close existing tunnels when a focus rule starts, including already-playing streams.
        for flow in Array(connections.values) where flow.host.map({ policy.blocks($0) }) == true { flow.finish() }
    }
}

private final class ProxyConnection {
    let id = UUID()
    var onFinish: ((UUID) -> Void)?
    private(set) var host: String?
    private let client: NWConnection
    private var upstream: NWConnection?
    private let queue: DispatchQueue
    private let port: UInt16
    private let policy: () -> ProxyPolicy
    private var buffer = Data()
    private var finished = false
    private var connected = false
    private var requestBody: RequestBody = .length(0)

    init(client: NWConnection, queue: DispatchQueue, port: UInt16, policy: @escaping () -> ProxyPolicy) {
        self.client = client; self.queue = queue; self.port = port; self.policy = policy
    }
    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
        }
        client.start(queue: queue)
        readHeader()
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.connected else { return }
            self.finish()
        }
    }
    func finish() {
        guard !finished else { return }
        finished = true
        client.cancel(); upstream?.cancel()
        onFinish?(id); onFinish = nil
    }
    private func reply(_ status: String, body: String, contentType: String = "text/plain; charset=utf-8") {
        let bytes = Data(body.utf8)
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        data.append(bytes)
        // Send a TCP FIN with the response. Cancelling immediately can reset the connection
        // before URLSession/browser clients accept a health, PAC, or blocked-site response.
        client.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else { self.finish(); return }
            self.client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in self?.finish() }
        })
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish() }
    }
    private func readHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data([13, 10, 13, 10])) {
                guard end.upperBound <= 65536 else { self.reply("431 Request Header Fields Too Large", body: "Request header too large."); return }
                let header = Data(self.buffer[..<end.upperBound])
                let rest = Data(self.buffer[end.upperBound...])
                self.buffer.removeAll()
                if let line = String(data: header, encoding: .utf8)?.components(separatedBy: "\r\n").first {
                    if line == "GET /proxy.pac HTTP/1.1" || line == "GET /proxy.pac HTTP/1.0" {
                        self.reply("200 OK", body: ProxySettings.pac(port: self.port), contentType: "application/x-ns-proxy-autoconfig"); return
                    }
                    if line == "GET /health HTTP/1.1" {
                        self.reply("200 OK", body: "LanesProxy/1"); return
                    }
                }
                do { try self.open(ProxyRequest(header), initial: rest) }
                catch { self.reply("400 Bad Request", body: "Invalid proxy request.") }
            } else if self.buffer.count > 65536 { self.reply("431 Request Header Fields Too Large", body: "Request header too large.") }
            else if complete || error != nil { self.finish() }
            else { self.readHeader() }
        }
    }
    private func open(_ request: ProxyRequest, initial: Data) throws {
        host = request.host
        if policy().blocks(request.host) {
            reply("403 Forbidden", body: "Blocked by Lanes during Focus. End focus or edit your blocked websites to continue.")
            return
        }
        guard !(request.port == port && ["127.0.0.1", "localhost", "::1"].contains(request.host)) else {
            reply("403 Forbidden", body: "A proxy cannot connect to itself."); return
        }
        requestBody = request.body
        // The proxy's own outbound sockets must bypass the system PAC to avoid routing back into itself.
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        // preferNoProxies may fall back after a failed direct connection. Never allow
        // that fallback to re-enter this loopback proxy. Localhost bypasses the PAC.
        parameters.prohibitedInterfaceTypes = [.loopback]
        let upstream = NWConnection(host: NWEndpoint.Host(request.host), port: NWEndpoint.Port(rawValue: request.port)!, using: parameters)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                self.connected = true
                // Recheck after DNS/connect, in case focus started while connecting.
                guard !self.policy().blocks(request.host) else {
                    self.reply("403 Forbidden", body: "Blocked by Lanes during Focus."); return
                }
                if request.isTunnel {
                    self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                        guard let self, error == nil else { self?.finish(); return }
                        self.sendInitial(initial, to: upstream) { self.relay(self.client, to: upstream, response: false) }
                        self.relay(upstream, to: self.client, response: true)
                    })
                } else {
                    upstream.send(content: request.header, completion: .contentProcessed { [weak self] error in
                        guard let self, error == nil else { self?.finish(); return }
                        if request.isUpgrade {
                            self.sendInitial(initial, to: upstream) { self.relay(self.client, to: upstream, response: false) }
                        } else { self.sendBody(initial) }
                        self.relay(upstream, to: self.client, response: true)
                    })
                }
            case .failed:
                if self.connected { self.finish() }
                else { self.reply("502 Bad Gateway", body: "The website could not be reached.") }
            default: break
            }
        }
        upstream.start(queue: queue)
    }
    private func sendInitial(_ data: Data, to target: NWConnection, then next: @escaping () -> Void) {
        guard !data.isEmpty else { next(); return }
        target.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish() } else { next() }
        })
    }
    private func sendBody(_ data: Data) {
        guard !finished, let upstream else { return }
        do {
            let (bytes, done) = try requestBody.consume(data)
            let next = { [weak self] in
                guard let self, !self.finished, !done else { return }
                self.client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                    guard let self else { return }
                    if let data, !data.isEmpty { self.sendBody(data) }
                    else if complete || error != nil { self.finish() }
                    else { self.sendBody(Data()) }
                }
            }
            sendInitial(bytes, to: upstream, then: next)
        } catch { finish() }
    }
    private func relay(_ source: NWConnection, to destination: NWConnection, response: Bool) {
        guard !finished else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if error != nil || sendError != nil { self.finish() }
                    else if complete { self.endDirection(destination, response: response) }
                    else { self.relay(source, to: destination, response: response) }
                })
            } else if error != nil { self.finish() }
            else if complete { self.endDirection(destination, response: response) }
            else { self.relay(source, to: destination, response: response) }
        }
    }
    private func endDirection(_ destination: NWConnection, response: Bool) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            if response { self?.finish() }
        })
    }
}
