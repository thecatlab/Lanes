import Foundation

public enum Lane: String, Codable, CaseIterable, Identifiable {
    case primary = "Primary", maintenance = "Maintenance", sandbox = "Sandbox"
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .primary: return "scope"; case .maintenance: return "gearshape"; case .sandbox: return "flask" }
    }
}

public struct Area: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var lane: Lane?
    public init(id: UUID = UUID(), name: String, lane: Lane?) { self.id = id; self.name = name; self.lane = lane }
}

public struct Segment: Identifiable, Codable {
    public var id = UUID()
    public var sessionID: UUID
    public var lane: Lane
    public var areaID: UUID?
    public var start: Date
    public var end: Date
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    public func duration(in interval: DateInterval) -> TimeInterval {
        max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
    }
}

public struct Session: Codable {
    public var id = UUID()
    public var lane: Lane
    public var areaID: UUID?
    public var recordID: UUID?
    public var isPaused: Bool { recordID == nil }
}

public struct Idea: Identifiable, Codable {
    public var id = UUID()
    public var text: String
    public var created: Date
}

public struct Preferences: Codable {
    public var areaLimits: [String: Int] = [Lane.primary.rawValue: 1]
    public var showProjects = true
    public var projectCount = 5
    public var showActiveArea = true
    public var sandboxBudgetEnabled = false
    public var sandboxMinutes = 60
    public var budgetNotifications = false
    public var blockingEnabled = true
    public var blockedDomains: [String] = []
    public var launchAtLogin = false
    public init() {}
}

public enum FocusError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

public struct FocusState: Codable {
    public var version = 1
    public var areas: [Area] = []
    public var segments: [Segment] = []
    public var ideas: [Idea] = []
    public var preferences = Preferences()
    public var session: Session?
    public var selectedLane: Lane = .primary
    public var rememberedAreas: [String: UUID] = [:]
    public var budgetNotifiedDay: String?
    public init() {}

    public func areas(in lane: Lane) -> [Area] {
        areas.filter { $0.lane == lane }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func area(_ id: UUID?) -> Area? { areas.first { $0.id == id } }
    public func preferredArea(in lane: Lane) -> UUID? {
        let items = areas(in: lane)
        if items.count == 1 { return items[0].id }
        return items.first { $0.id == rememberedAreas[lane.rawValue] }?.id
    }
    public func limit(for lane: Lane) -> Int? { preferences.areaLimits[lane.rawValue] }
    public func validateCapacity(_ lane: Lane, excluding id: UUID? = nil) throws {
        if let limit = limit(for: lane), areas(in: lane).filter({ $0.id != id }).count >= limit {
            throw FocusError.message("\(lane.rawValue) has \(limit) of \(limit) Areas. Move an Area or increase the limit in Settings.")
        }
    }
    public mutating func setLimit(_ value: Int?, lane: Lane) throws {
        if let value, value < max(1, areas(in: lane).count) {
            throw FocusError.message("Move or unassign Areas before lowering this limit.")
        }
        preferences.areaLimits[lane.rawValue] = value
    }
    @discardableResult public mutating func addArea(name: String, lane: Lane?) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FocusError.message("Give this Area a name.") }
        if let lane { try validateCapacity(lane) }
        let area = Area(name: name, lane: lane)
        areas.append(area)
        if let lane { rememberedAreas[lane.rawValue] = area.id }
        return area.id
    }
    public mutating func renameArea(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FocusError.message("Give this Area a name.") }
        guard let index = areas.firstIndex(where: { $0.id == id }) else { return }
        areas[index].name = name
    }
    public mutating func moveArea(_ id: UUID, to lane: Lane?, at now: Date) throws {
        guard let index = areas.firstIndex(where: { $0.id == id }) else { return }
        if let lane { try validateCapacity(lane, excluding: id) }
        checkpoint(at: now)
        let oldLane = areas[index].lane
        areas[index].lane = lane
        if let oldLane, rememberedAreas[oldLane.rawValue] == id { rememberedAreas[oldLane.rawValue] = nil }
        if let lane { rememberedAreas[lane.rawValue] = id }
        if session?.areaID == id {
            let paused = session!.isPaused
            session!.recordID = nil
            session!.areaID = lane == nil ? nil : id
            if let lane { session!.lane = lane; selectedLane = lane }
            if !paused { openSegment(at: now) }
        }
    }
    public mutating func start(lane: Lane, at now: Date) {
        end(at: now)
        selectedLane = lane
        session = Session(lane: lane, areaID: preferredArea(in: lane))
        openSegment(at: now)
    }
    private mutating func openSegment(at now: Date) {
        guard let current = session else { return }
        let record = Segment(sessionID: current.id, lane: current.lane, areaID: current.areaID, start: now, end: now)
        segments.append(record)
        session!.recordID = record.id
    }
    public mutating func checkpoint(at now: Date) {
        guard let id = session?.recordID, let index = segments.lastIndex(where: { $0.id == id }) else { return }
        segments[index].end = max(segments[index].end, now)
    }
    public mutating func pause(at now: Date) { checkpoint(at: now); session?.recordID = nil }
    public mutating func resume(at now: Date) {
        guard session?.isPaused == true else { return }
        openSegment(at: now)
    }
    public mutating func end(at now: Date) { checkpoint(at: now); session = nil }
    public mutating func selectArea(_ id: UUID?, at now: Date) throws {
        let lane = session?.lane ?? selectedLane
        if let id, area(id)?.lane != lane { throw FocusError.message("Choose an Area assigned to \(lane.rawValue).") }
        rememberedAreas[lane.rawValue] = id
        guard session != nil else { return }
        checkpoint(at: now)
        let paused = session!.isPaused
        session!.areaID = id
        session!.recordID = nil
        if !paused { openSegment(at: now) }
    }
    public mutating func recover() -> Bool {
        guard session != nil else { return false }
        // The last durable checkpoint is the end of recorded time. Never count time while the app was absent.
        session!.recordID = nil
        return true
    }
    public var sessionDuration: TimeInterval {
        guard let id = session?.id else { return 0 }
        return segments.filter { $0.sessionID == id }.reduce(0) { $0 + $1.duration }
    }
    public func laneTotal(_ lane: Lane, in interval: DateInterval) -> TimeInterval {
        segments.filter { $0.lane == lane }.reduce(0) { $0 + $1.duration(in: interval) }
    }
    public func projectTotals(at now: Date, count: Int) -> [(area: Area, duration: TimeInterval)] {
        let interval = DateInterval(start: now.addingTimeInterval(-30 * 86400), end: now)
        var totals: [UUID: TimeInterval] = [:]
        for segment in segments {
            if let id = segment.areaID { totals[id, default: 0] += segment.duration(in: interval) }
        }
        var rows: [(area: Area, duration: TimeInterval)] = []
        for area in areas {
            if let total = totals[area.id], total > 0 { rows.append((area, total)) }
        }
        rows.sort {
            if $0.duration == $1.duration { return $0.area.name.localizedStandardCompare($1.area.name) == .orderedAscending }
            return $0.duration > $1.duration
        }
        return Array(rows.prefix(max(1, min(5, count))))
    }
    public mutating func addIdea(_ text: String, at now: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { ideas.insert(Idea(text: text, created: now), at: 0) }
    }
}

public enum DomainRule {
    public static func normalize(_ input: String) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let components = URLComponents(string: raw.contains("://") ? raw : "https://" + raw),
              let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              host.contains("."), !host.contains(" "), !host.contains(":"),
              host.utf8.allSatisfy({ $0 < 128 }),
              host.split(separator: ".").allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
              }), host.count <= 253 else { throw FocusError.message("Enter a domain such as youtube.com.") }
        return host
    }
    public static func matches(host: String, domain: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix("." + domain)
    }
}

public enum TimeText {
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        if minutes == 0 { return seconds > 0 ? "<1m" : "0m" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    public static func clock(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
