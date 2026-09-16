import Foundation
import LanesCore

public struct ProxyPolicy: Codable {
    public var domains: [String]
    public var expiresAt: Date
    public init(domains: [String], expiresAt: Date) { self.domains = domains; self.expiresAt = expiresAt }
    public func blocks(_ host: String, at now: Date = Date()) -> Bool {
        expiresAt > now && domains.contains { DomainRule.matches(host: host, domain: $0) }
    }
    public static func read(from directory: URL) -> ProxyPolicy {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("policy.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return ProxyPolicy(domains: [], expiresAt: .distantPast)
        }
        return value
    }
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("policy.json")
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public struct ProxyStatus: Codable {
    public var version: Int
    public var port: UInt16
    public var pid: Int32
    public var updatedAt: Date
    public init(port: UInt16) { version = 1; self.port = port; pid = ProcessInfo.processInfo.processIdentifier; updatedAt = Date() }
    public static func read(from directory: URL) -> ProxyStatus? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
              let status = try? JSONDecoder().decode(Self.self, from: data),
              Date().timeIntervalSince(status.updatedAt) >= -5,
              Date().timeIntervalSince(status.updatedAt) < 6 else { return nil }
        return status
    }
}

public enum ProxySettings {
    public static let port: UInt16 = 19347
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lanes/Proxy", isDirectory: true)
    }
    public static var pacURL: String { "http://127.0.0.1:\(port)/proxy.pac" }
    public static func pac(port: UInt16) -> String {
        """
        function FindProxyForURL(url, host) {
          if (isPlainHostName(host) || host === "localhost" || dnsDomainIs(host, ".localhost") ||
              host === "127.0.0.1" || host === "::1" || host === "[::1]") return "DIRECT";
          return "PROXY 127.0.0.1:\(port); DIRECT";
        }
        """
    }
}
