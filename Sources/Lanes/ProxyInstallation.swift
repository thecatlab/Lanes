import Foundation
import LanesCore
import LanesProxyKit
import Security
import SystemConfiguration

enum ProxyInstallation {
    static let label = "com.nusaindah.Lanes.Proxy"
    static let backup = ProxySettings.directory.appendingPathComponent("network-backup.plist")
    static var agent: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static let pacKeys = [kSCPropNetProxiesProxyAutoConfigEnable as String, kSCPropNetProxiesProxyAutoConfigURLString as String]
    static let proxyGroups = [["HTTPEnable", "HTTPProxy", "HTTPPort"], ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"]]
    static let localExceptions = ["localhost", "127.0.0.1", "::1", "*.localhost"]

    static func services(_ preferences: SCPreferences) -> [SCNetworkService] {
        (SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] ?? []).filter { service in
            guard let interface = SCNetworkServiceGetInterface(service), let type = SCNetworkInterfaceGetInterfaceType(interface) else { return false }
            return [kSCNetworkInterfaceTypeEthernet, kSCNetworkInterfaceTypeIEEE80211].contains(type)
        }
    }
    static func config(_ service: SCNetworkService) -> [String: Any] {
        guard let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { return [:] }
        return SCNetworkProtocolGetConfiguration(protocolRef) as? [String: Any] ?? [:]
    }
    static func ownsEndpoint(_ config: [String: Any], _ keys: [String]) -> Bool {
        config[keys[1]] as? String == "127.0.0.1" && (config[keys[2]] as? NSNumber)?.uint16Value == ProxySettings.port
    }
    static func ownsPAC(_ config: [String: Any]) -> Bool { config[pacKeys[1]] as? String == ProxySettings.pacURL }
    static func owns(_ config: [String: Any]) -> Bool { ownsPAC(config) || proxyGroups.contains { ownsEndpoint(config, $0) } }
    static func directProxyEnabled(_ config: [String: Any]) -> Bool {
        proxyGroups.allSatisfy { ownsEndpoint(config, $0) && (config[$0[0]] as? NSNumber)?.boolValue == true }
            && (config[pacKeys[0]] as? NSNumber)?.boolValue != true
    }
    static func networkConfiguration(_ original: [String: Any]) -> [String: Any] {
        var value = original
        for keys in proxyGroups {
            value[keys[0]] = 1; value[keys[1]] = "127.0.0.1"; value[keys[2]] = Int(ProxySettings.port)
        }
        if ownsPAC(value) { value[pacKeys[0]] = 0; value[pacKeys[1]] = nil }
        var exceptions = value["ExceptionsList"] as? [String] ?? []
        for host in localExceptions where !exceptions.contains(host) { exceptions.append(host) }
        value["ExceptionsList"] = exceptions
        return value
    }
    static func restoredConfiguration(_ current: [String: Any], original: [String: Any]) -> [String: Any] {
        var value = current
        let ownsDirectProxy = proxyGroups.contains { ownsEndpoint(current, $0) }
        for keys in proxyGroups where ownsEndpoint(current, keys) {
            for key in keys { value[key] = original[key] }
        }
        if ownsPAC(current) {
            for key in pacKeys { value[key] = original[key] }
        }
        if ownsDirectProxy {
            // Restore the disabled legacy PAC flag only if it hasn't been replaced by another configuration.
            if current[pacKeys[1]] == nil && (current[pacKeys[0]] as? NSNumber)?.boolValue != true {
                for key in pacKeys { value[key] = original[key] }
            }
            if current["ExceptionsList"] as? [String] == networkConfiguration(original)["ExceptionsList"] as? [String] {
                value["ExceptionsList"] = original["ExceptionsList"]
            }
        }
        return value
    }
    static func configured() -> Bool {
        guard let preferences = SCPreferencesCreate(nil, "Lanes" as CFString, nil) else { return false }
        return services(preferences).contains { service in
            let value = config(service)
            return owns(value)
        }
    }
    static func activeRoute() -> Bool {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return directProxyEnabled(proxies)
    }
    static func installHelper(from source: URL) throws {
        let fm = FileManager.default
        let destination = ProxySettings.directory.appendingPathComponent("LanesProxy")
        try fm.createDirectory(at: ProxySettings.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let agentConfig = (try? Data(contentsOf: agent)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        if let sourceData = try? Data(contentsOf: source), let existing = try? Data(contentsOf: destination), sourceData == existing,
           agentConfig?["ProcessType"] as? String == "Standard",
           ProxyStatus.read(from: ProxySettings.directory)?.port == ProxySettings.port { return }
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        let temporary = ProxySettings.directory.appendingPathComponent("LanesProxy.new")
        if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        try? fm.removeItem(at: ProxySettings.directory.appendingPathComponent("status.json"))
        let plist: [String: Any] = [
            "Label": label, "ProgramArguments": [destination.path], "RunAtLoad": true,
            "KeepAlive": true, "ThrottleInterval": 2, "ProcessType": "Standard",
            "StandardOutPath": ProxySettings.directory.appendingPathComponent("helper.log").path,
            "StandardErrorPath": ProxySettings.directory.appendingPathComponent("helper.log").path
        ]
        try fm.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agent, options: .atomic)
        try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agent.path])
        for _ in 0..<50 {
            if ProxyStatus.read(from: ProxySettings.directory)?.port == ProxySettings.port { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw FocusError.message("The local blocker couldn't start. Check that port \(ProxySettings.port) is available, then try setup again.")
    }
    static func configure() throws {
        guard let preflight = SCPreferencesCreate(nil, "Lanes" as CFString, nil) else { throw failure() }
        try validate(services(preflight))
        try authorized { preferences in
            let targets = services(preferences)
            try validate(targets)
            var saved = (try? Data(contentsOf: backup)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: [String: Any]] } ?? [:]
            for service in targets where !owns(config(service)) {
                guard let id = SCNetworkServiceGetServiceID(service) else { throw failure() }
                saved[id as String] = config(service)
            }
            try PropertyListSerialization.data(fromPropertyList: saved, format: .xml, options: 0).write(to: backup, options: .atomic)
            for service in targets {
                guard let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { throw failure() }
                let value = networkConfiguration(config(service))
                guard SCNetworkProtocolSetConfiguration(protocolRef, value as CFDictionary) else { throw failure() }
            }
        }
    }
    private static func validate(_ services: [SCNetworkService]) throws {
        guard !services.isEmpty else { throw FocusError.message("No Wi-Fi or Ethernet network service was found.") }
        let enabledKeys = [kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesProxyAutoDiscoveryEnable, kSCPropNetProxiesProxyAutoConfigEnable] as [String]
        for service in services {
            let value = config(service)
            for key in enabledKeys where (value[key] as? NSNumber)?.boolValue == true {
                if key == pacKeys[0] && ownsPAC(value) { continue }
                if proxyGroups.contains(where: { $0[0] == key && ownsEndpoint(value, $0) }) { continue }
                let name = SCNetworkServiceGetName(service) as String? ?? "This network"
                throw FocusError.message("\(name) already uses a proxy. Lanes left it unchanged. Turn off that proxy before setting up Lanes, or keep website blocking off.")
            }
        }
    }
    static func remove() throws {
        try ProxyPolicy(domains: [], expiresAt: .distantPast).write(to: ProxySettings.directory)
        if configured() {
            let saved = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: [String: Any]] ?? [:]
            try authorized { preferences in
                for service in SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] ?? [] {
                    let current = config(service)
                    guard owns(current), let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
                    guard let id = SCNetworkServiceGetServiceID(service) else { throw failure() }
                    let original = saved[id as String] ?? [:]
                    let restored = restoredConfiguration(current, original: original)
                    guard SCNetworkProtocolSetConfiguration(protocolRef, restored as CFDictionary) else { throw failure() }
                }
            }
        }
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        for file in [agent, backup, ProxySettings.directory.appendingPathComponent("status.json")] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
    private static func authorized(_ update: (SCPreferences) throws -> Void) throws {
        var authorization: AuthorizationRef?
        let status = "system.services.systemconfiguration.network".withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCreate(&rights, nil, [.interactionAllowed, .extendRights], &authorization)
            }
        }
        guard status == errAuthorizationSuccess, let authorization else { throw FocusError.message("Network setup wasn't approved. Your settings are unchanged.") }
        defer { AuthorizationFree(authorization, []) }
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "Lanes website blocking" as CFString, nil, authorization), SCPreferencesLock(preferences, true) else { throw failure() }
        defer { SCPreferencesUnlock(preferences) }
        try update(preferences)
        guard SCPreferencesCommitChanges(preferences) else { throw failure() }
        guard SCPreferencesApplyChanges(preferences) else {
            throw FocusError.message("Network settings were saved but couldn't be applied. Retry setup, or remove website blocking setup to restore them.")
        }
    }
    private static func failure() -> FocusError { .message("Couldn't update network settings: \(String(cString: SCErrorString(SCError())))") }
    @discardableResult private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw FocusError.message("Couldn't start the background blocker. \(output)") }
        return output
    }
}
