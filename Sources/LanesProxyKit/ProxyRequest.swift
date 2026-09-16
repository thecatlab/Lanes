import Foundation

struct ProxyRequest {
    let method: String
    let host: String
    let port: UInt16
    let isTunnel: Bool
    let isUpgrade: Bool
    let header: Data
    var body: RequestBody

    init(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ProxyError.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])),
              first[0].allSatisfy({ $0.isASCII && $0.isLetter }) else { throw ProxyError.invalidRequest }
        method = String(first[0]); isTunnel = method == "CONNECT"
        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { throw ProxyError.invalidRequest }
            let key = String(line[..<colon])
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }) else { throw ProxyError.invalidRequest }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { throw ProxyError.invalidRequest }
            headers.append((key, value))
        }
        let lengths = headers.filter { $0.0.lowercased() == "content-length" }
        let encodings = headers.filter { $0.0.lowercased() == "transfer-encoding" }
        guard lengths.count <= 1, encodings.count <= 1, lengths.isEmpty || encodings.isEmpty else { throw ProxyError.invalidRequest }
        if let encoding = encodings.first {
            guard encoding.1.lowercased() == "chunked" else { throw ProxyError.invalidRequest }
            body = .chunked(ChunkedBody())
        } else if let length = lengths.first {
            guard !length.1.isEmpty, length.1.allSatisfy(\.isNumber), let count = Int(length.1), count >= 0 else { throw ProxyError.invalidRequest }
            body = .length(count)
        } else { body = .length(0) }
        let target = String(first[1])
        guard let url = URLComponents(string: isTunnel ? "https://" + target : target),
              let rawHost = url.host, !rawHost.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
              isTunnel ? (url.path.isEmpty && url.query == nil && url.port != nil) : url.scheme?.lowercased() == "http",
              let destinationPort = UInt16(exactly: url.port ?? (isTunnel ? 443 : 80)), destinationPort > 0 else { throw ProxyError.invalidRequest }
        host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        port = destinationPort
        isUpgrade = !isTunnel && headers.contains { $0.0.lowercased() == "upgrade" && $0.1.lowercased() == "websocket" }
        if isTunnel { header = Data(); return }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        let connectionTokens = Set(headers.filter { $0.0.lowercased() == "connection" }.flatMap { $0.1.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
        guard connectionTokens.isDisjoint(with: ["content-length", "transfer-encoding"]) else { throw ProxyError.invalidRequest }
        let remove: Set<String> = ["host", "proxy-connection", "proxy-authorization", "proxy-authenticate", "connection", "keep-alive"]
        var output = "\(method) \(path) HTTP/1.1\r\n"
        let authority = host.contains(":") ? "[\(host)]" : host
        output += "Host: \(authority)\(port == 80 ? "" : ":\(port)")\r\n"
        for (key, value) in headers where !remove.contains(key.lowercased()) && (!connectionTokens.contains(key.lowercased()) || (isUpgrade && key.lowercased() == "upgrade")) {
            output += "\(key): \(value)\r\n"
        }
        output += isUpgrade ? "Connection: Upgrade\r\n\r\n" : "Connection: close\r\n\r\n"
        header = Data(output.utf8)
    }
}

enum ProxyError: Error { case invalidRequest }

enum RequestBody {
    case length(Int), chunked(ChunkedBody)
    mutating func consume(_ data: Data) throws -> (Data, Bool) {
        switch self {
        case .length(let remaining):
            let count = min(remaining, data.count)
            self = .length(remaining - count)
            return (Data(data.prefix(count)), count == remaining)
        case .chunked(var decoder):
            let result = try decoder.consume(data)
            self = .chunked(decoder)
            return result
        }
    }
}

// Validate request framing while streaming, so a second pipelined request never crosses a policy decision.
struct ChunkedBody {
    enum State { case size, bytes(Int), ending(Int), trailers, done }
    var state = State.size
    var line = Data()
    var trailerBytes = 0
    mutating func consume(_ data: Data) throws -> (Data, Bool) {
        var output = Data()
        for byte in data {
            if case .done = state { break }
            output.append(byte)
            switch state {
            case .size, .trailers:
                line.append(byte)
                guard line.count <= 8192 else { throw ProxyError.invalidRequest }
                if case .trailers = state { trailerBytes += 1; guard trailerBytes <= 32768 else { throw ProxyError.invalidRequest } }
                if line.suffix(2) == Data([13, 10]) {
                    if case .size = state {
                        let value = String(decoding: line.dropLast(2), as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)[0]
                        guard !value.isEmpty, value.allSatisfy(\.isHexDigit), let count = Int(value, radix: 16), count >= 0 else { throw ProxyError.invalidRequest }
                        state = count == 0 ? .trailers : .bytes(count)
                    } else if line.count == 2 { state = .done }
                    else if !line.contains(58) { throw ProxyError.invalidRequest }
                    line.removeAll(keepingCapacity: true)
                }
            case .bytes(let remaining): state = remaining == 1 ? .ending(0) : .bytes(remaining - 1)
            case .ending(let index):
                guard byte == (index == 0 ? 13 : 10) else { throw ProxyError.invalidRequest }
                state = index == 0 ? .ending(1) : .size
            case .done: break
            }
        }
        if case .done = state { return (output, true) }
        return (output, false)
    }
}
