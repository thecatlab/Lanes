import AppKit
import Combine
import LanesCore
import ServiceManagement
import UserNotifications

@MainActor final class AppStore: ObservableObject {
    @Published var state: FocusState
    @Published var now = Date()
    @Published var error: String?
    @Published var recoveryMessage: String?
    let blocker = Blocker()
    private let file: URL
    private var ticker: Timer?
    private var tickCount = 0
    private var anchorDate = Date()
    private var anchorUptime = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []
    private var canSave = true
    private var blockerSubscription: AnyCancellable?

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lanes", isDirectory: true)
        file = root.appendingPathComponent("state.json")
        state = FocusState()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(FocusState.self, from: Data(contentsOf: file))
                if state.recover() { recoveryMessage = "Previous session paused. Resume when you're ready." }
            }
        } catch {
            canSave = false
            self.error = "Couldn't read saved data. Your original file is untouched. \(error.localizedDescription)"
        }
        blocker.load()
        blocker.stop()
        blockerSubscription = blocker.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        })
    }
    private func clockNow() -> Date {
        state.session?.isPaused == false ? anchorDate.addingTimeInterval(ProcessInfo.processInfo.systemUptime - anchorUptime) : Date()
    }
    private func resetClock() { anchorDate = Date(); anchorUptime = ProcessInfo.processInfo.systemUptime; now = anchorDate }
    func tick() {
        now = clockNow()
        state.checkpoint(at: now)
        tickCount += 1
        if tickCount % 15 == 0, state.session?.isPaused == false { save() }
        checkBudget()
    }
    func save() {
        guard canSave else { return }
        do { try JSONEncoder().encode(state).write(to: file, options: .atomic) }
        catch { self.error = "Your latest changes couldn't be saved. \(error.localizedDescription)" }
    }
    @discardableResult func change(_ operation: (inout FocusState) throws -> Void) -> Bool {
        do { try operation(&state); save(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func start(_ lane: Lane) {
        guard canSave else { error = "Saved data needs recovery before starting a session."; return }
        do {
            if state.preferences.blockingEnabled { try blocker.start(domains: state.preferences.blockedDomains) }
            tick()
            state.start(lane: lane, at: now)
            anchorDate = now; anchorUptime = ProcessInfo.processInfo.systemUptime
            recoveryMessage = nil
            save()
        } catch { self.error = error.localizedDescription }
    }
    func pause() { now = clockNow(); state.pause(at: now); save() }
    func resume() {
        do {
            if state.preferences.blockingEnabled { try blocker.start(domains: state.preferences.blockedDomains) }
            resetClock(); state.resume(at: now); recoveryMessage = nil; save()
        } catch { self.error = error.localizedDescription }
    }
    func end() { now = clockNow(); state.end(at: now); blocker.stop(); recoveryMessage = nil; save() }
    func selectArea(_ id: UUID?) {
        now = clockNow()
        change { try $0.selectArea(id, at: now) }
    }
    func moveArea(_ id: UUID, to lane: Lane?) {
        now = clockNow()
        change { try $0.moveArea(id, to: lane, at: now) }
    }
    var currentLane: Lane { state.session?.lane ?? state.selectedLane }
    var currentArea: Area? { state.area(state.session != nil ? state.session!.areaID : state.preferredArea(in: state.selectedLane)) }
    var today: DateInterval { Calendar.current.dateInterval(of: .day, for: now)! }
    func todayTotal(_ lane: Lane) -> TimeInterval { state.laneTotal(lane, in: today) }
    var sandboxRemaining: TimeInterval { Double(state.preferences.sandboxMinutes * 60) - todayTotal(.sandbox) }
    var budgetText: String {
        sandboxRemaining > 0 ? "Daily budget · \(TimeText.duration(sandboxRemaining)) left" : "Daily budget reached · \(TimeText.duration(-sandboxRemaining)) over"
    }
    var statusText: String? {
        guard let session = state.session, state.preferences.showActiveArea else { return nil }
        let name = state.area(session.areaID)?.name ?? session.lane.rawValue
        return session.isPaused ? "Paused · \(name)" : "Currently working on \(name)"
    }
    private func checkBudget() {
        guard state.preferences.sandboxBudgetEnabled, state.session?.lane == .sandbox, !state.session!.isPaused, sandboxRemaining <= 0 else { return }
        let day = String(Int(today.start.timeIntervalSince1970))
        guard state.budgetNotifiedDay != day else { return }
        state.budgetNotifiedDay = day; save()
        if state.preferences.budgetNotifications {
            let content = UNMutableNotificationContent()
            content.title = "Sandbox daily budget reached"
            content.body = "Your time is still being tracked. End focus when you're ready."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sandbox-" + day, content: content, trigger: nil))
        }
    }
    func enableNotifications(_ enabled: Bool) {
        if !enabled { change { $0.preferences.budgetNotifications = false }; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            Task { @MainActor in
                self.change { $0.preferences.budgetNotifications = allowed }
                if !allowed { self.error = "Notifications aren't allowed. The daily budget still appears in the panel." }
            }
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            change { $0.preferences.launchAtLogin = enabled }
        } catch { self.error = error.localizedDescription }
    }
    func setBlocking(_ enabled: Bool) {
        do {
            if enabled && state.session != nil { try blocker.start(domains: state.preferences.blockedDomains) }
            if !enabled { blocker.stop() }
            change { $0.preferences.blockingEnabled = enabled }
        } catch { self.error = error.localizedDescription }
    }
    func updateDomains(_ domains: [String]) {
        do {
            if state.preferences.blockingEnabled && state.session != nil { try blocker.start(domains: domains) }
            change { $0.preferences.blockedDomains = domains }
        } catch { self.error = error.localizedDescription }
    }
}
