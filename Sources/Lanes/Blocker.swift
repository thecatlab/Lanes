import AppKit
import LanesCore
import LanesProxyKit

@MainActor final class Blocker: ObservableObject {
    @Published var message = "Website blocking needs setup"
    @Published var ready = false
    @Published var installed = false
    @Published var busy = false
    @Published var setupError: String?
    @Published var active = false
    // Keep the requested rules across transient helper/network failures until Focus ends.
    private var domains: [String] = []
    private var timer: Timer?
    private var healthy = false
    private var checkingHealth = false
    private var leaseWrittenAt = Date.distantPast
    private var focusActivity: NSObjectProtocol?
    private let healthSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
    }()

    func load() {
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.checkHealth() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        if installed { install(configureNetwork: false) }
        else { checkHealth() }
    }
    private func checkHealth() {
        guard installed, !checkingHealth else { return }
        checkingHealth = true
        Task {
            do {
                let (data, response) = try await healthSession.data(from: URL(string: "http://127.0.0.1:\(ProxySettings.port)/health")!)
                healthy = (response as? HTTPURLResponse)?.statusCode == 200 && data == Data("LanesProxy/1".utf8)
            } catch { healthy = false }
            checkingHealth = false
            refresh()
        }
    }
    private func refresh() {
        installed = ProxyInstallation.configured()
        ready = installed && healthy && ProxyInstallation.activeRoute()
        if !domains.isEmpty && Date().timeIntervalSince(leaseWrittenAt) >= 10 {
            do { try renewLease() }
            catch {
                active = false; message = "Blocking stopped: couldn't save rules"
                return
            }
        }
        active = ready && !domains.isEmpty
        if !ready {
            message = !installed ? "Website blocking needs setup" : (!healthy ? "Local blocker is reconnecting" : "This network isn't using Lanes")
        } else { message = active ? "Website blocking active" : "Website blocking ready" }
    }
    func install() { install(configureNetwork: true) }
    private func install(configureNetwork: Bool) {
        guard !busy else { return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "LanesProxy") else { setupError = "The local blocker is missing. Reinstall Lanes."; return }
        busy = true; setupError = nil
        Task {
            do {
                try await Task.detached {
                    try ProxyInstallation.installHelper(from: helper)
                    if configureNetwork && (!ProxyInstallation.configured() || !ProxyInstallation.activeRoute()) {
                        try ProxyInstallation.configure()
                    }
                }.value
            } catch { setupError = error.localizedDescription }
            busy = false; refresh(); checkHealth()
        }
    }
    func remove() {
        guard !busy else { return }
        stop(); busy = true; setupError = nil
        Task {
            do { try await Task.detached { try ProxyInstallation.remove() }.value }
            catch { setupError = error.localizedDescription }
            busy = false; healthy = false; refresh()
        }
    }
    func start(domains: [String]) throws {
        refresh()
        guard ready else { throw FocusError.message("Finish local blocker setup in Settings, or turn Block websites off to track time.") }
        guard !domains.isEmpty else { throw FocusError.message("Add at least one website in Settings.") }
        let normalized = try domains.map(DomainRule.normalize)
        try ProxyPolicy(domains: normalized, expiresAt: Date().addingTimeInterval(35)).write(to: ProxySettings.directory)
        self.domains = normalized; leaseWrittenAt = Date()
        if focusActivity == nil {
            focusActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Maintain website blocking during Focus")
        }
        active = true; message = "Website blocking active"
    }
    private func renewLease() throws {
        try ProxyPolicy(domains: domains, expiresAt: Date().addingTimeInterval(35)).write(to: ProxySettings.directory)
        leaseWrittenAt = Date()
    }
    func stop() {
        domains = []; active = false
        if let focusActivity { ProcessInfo.processInfo.endActivity(focusActivity); self.focusActivity = nil }
        do { try ProxyPolicy(domains: [], expiresAt: .distantPast).write(to: ProxySettings.directory) }
        catch { setupError = "Couldn't clear blocking rules. They will expire automatically within 35 seconds." }
        message = ready ? "Website blocking ready" : "Website blocking needs setup"
    }
}
