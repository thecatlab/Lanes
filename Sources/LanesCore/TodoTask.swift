import Foundation

public enum TodoSection: String, Codable, CaseIterable, Identifiable {
    case active = "ACTIVE", next = "NEXT", backlog = "BACKLOG"
    public var id: String { rawValue }
}

public struct TodoTask: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    public var areaID: UUID?
    public var section: TodoSection
    public var isArchived = false
    public init(name: String, areaID: UUID?, section: TodoSection) {
        self.name = name; self.areaID = areaID; self.section = section
    }
}

extension FocusState {
    // The focus picker follows the product's priority order, independent of storage order.
    public func focusTasks(areaID: UUID?) -> [TodoTask] {
        TodoSection.allCases.flatMap { section in tasks.filter { !$0.isArchived && $0.areaID == areaID && $0.section == section } }
    }
    public func selectedTask(areaID: UUID?) -> TodoTask? {
        focusTasks(areaID: areaID).first { $0.id == selectedTaskID }
    }
    public mutating func selectTask(_ id: UUID?, areaID: UUID?) throws {
        if let id, !focusTasks(areaID: areaID).contains(where: { $0.id == id }) {
            throw FocusError.message("Choose an unfinished task in the selected Area.")
        }
        selectedTaskID = id
    }

    @discardableResult public mutating func addTask(name: String, areaID: UUID?, section: TodoSection) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FocusError.message("Give this task a name.") }
        let task = TodoTask(name: name, areaID: areaID, section: section)
        tasks.append(task)
        return task.id
    }
    public mutating func setTaskArchived(_ id: UUID, _ archived: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isArchived = archived
        // A completed task cannot remain selected in the Focus screen.
        if archived && selectedTaskID == id { selectedTaskID = nil }
    }
    public mutating func moveTask(_ id: UUID, to section: TodoSection, before target: UUID? = nil) {
        guard id != target, let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isArchived else { return }
        var task = tasks.remove(at: index)
        task.section = section
        let insertion = target.flatMap { target in tasks.firstIndex { $0.id == target && $0.section == section && !$0.isArchived } }
        tasks.insert(task, at: insertion ?? tasks.endIndex)
    }
}
