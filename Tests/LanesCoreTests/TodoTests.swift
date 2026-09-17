import Foundation

@main struct TodoTests {
    static func main() throws {
        let tests = TodoTests()
        try tests.testLegacyStateLoadsWithoutTodoFields()
        try tests.testTasksColorsAndLimitSurviveSave()
        try tests.testMoveBeforeAfterAndAcrossSections()
        try tests.testArchiveRestoreAndInboxCopy()
        tests.testEmptyTaskRejected()
        try tests.testFocusTaskSelection()
        print("Passed 6 To-do regression checks")
    }
    func testLegacyStateLoadsWithoutTodoFields() throws {
        var state = FocusState()
        let areaID = try state.addArea(name: "Existing project", lane: .primary)
        state.addIdea("Keep this thought", at: Date())
        state.start(lane: .primary, at: Date())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "savedTasks")
        var preferences = json["preferences"] as! [String: Any]
        preferences.removeValue(forKey: "todoVisibleRows")
        json["preferences"] = preferences
        let decoded = try JSONDecoder().decode(FocusState.self, from: JSONSerialization.data(withJSONObject: json))
        assert(decoded.tasks.isEmpty)
        assert(decoded.selectedTaskID == nil)
        assert(decoded.preferences.todoVisibleRows == nil)
        assert(decoded.areas.first?.badgeColor == nil)
        assert(decoded.area(areaID)?.name == "Existing project")
        assert(decoded.ideas.first?.text == "Keep this thought")
        assert(decoded.session?.areaID == areaID)
        assert(decoded.segments.count == 1)
    }

    func testTasksColorsAndLimitSurviveSave() throws {
        var state = FocusState()
        let id = try state.addArea(name: "Ketjeh Seafood", lane: .primary)
        state.areas[0].badgeColor = "279B73"
        state.preferences.todoVisibleRows = 15
        try state.addTask(name: "  Review menu  ", areaID: id, section: .next)
        state.setTaskArchived(state.tasks[0].id, true)
        let decoded = try JSONDecoder().decode(FocusState.self, from: JSONEncoder().encode(state))
        assert(decoded.tasks == state.tasks)
        assert(decoded.tasks[0].name == "Review menu")
        assert(decoded.areas[0].badgeColor == "279B73")
        assert(decoded.preferences.todoVisibleRows == 15)
    }

    func testMoveBeforeAfterAndAcrossSections() throws {
        var state = FocusState()
        for name in ["A", "B", "C"] { try state.addTask(name: name, areaID: nil, section: .active) }
        let ids = state.tasks.map(\.id)
        state.moveTask(ids[2], to: .active, before: ids[0])
        assert(state.tasks.map(\.name) == ["C", "A", "B"])
        state.moveTask(ids[2], to: .active)
        assert(state.tasks.map(\.name) == ["A", "B", "C"])
        state.moveTask(ids[1], to: .backlog)
        assert(state.tasks.filter { $0.section == .active }.map(\.name) == ["A", "C"])
        assert(state.tasks.filter { $0.section == .backlog }.map(\.name) == ["B"])
        state.moveTask(ids[1], to: .active, before: ids[2])
        assert(state.tasks.map(\.name) == ["A", "B", "C"])
        state.moveTask(ids[1], to: .active, before: ids[1])
        assert(state.tasks.map(\.name) == ["A", "B", "C"])
    }

    func testArchiveRestoreAndInboxCopy() throws {
        var state = FocusState()
        state.addIdea("Draft proposal", at: Date())
        try state.addTask(name: state.ideas[0].text, areaID: nil, section: .next)
        let id = state.tasks[0].id
        state.setTaskArchived(id, true)
        assert(state.tasks.filter { !$0.isArchived }.count == 0)
        state.moveTask(id, to: .backlog)
        assert(state.tasks[0].section == .next)
        state.setTaskArchived(id, false)
        assert(!state.tasks[0].isArchived)
        assert(state.tasks[0].section == .next)
        assert(state.ideas.count == 1)
    }

    func testFocusTaskSelection() throws {
        var state = FocusState()
        let area = try state.addArea(name: "Work", lane: .primary)
        let other = try state.addArea(name: "Home", lane: .maintenance)
        let backlog = try state.addTask(name: "Later", areaID: area, section: .backlog)
        let active = try state.addTask(name: "Now", areaID: area, section: .active)
        let next = try state.addTask(name: "Next", areaID: area, section: .next)
        let unrelated = try state.addTask(name: "Other Area", areaID: other, section: .active)
        let unassigned = try state.addTask(name: "No Area", areaID: nil, section: .active)
        assert(state.focusTasks(areaID: area).map(\.id) == [active, next, backlog])
        assert(state.focusTasks(areaID: nil).map(\.id) == [unassigned])
        do { try state.selectTask(unrelated, areaID: area); assertionFailure("Wrong Area must be rejected") } catch {}
        try state.selectTask(active, areaID: area)
        state.start(lane: .primary, at: Date())
        assert(state.selectedTask(areaID: state.session?.areaID)?.id == active)
        let decoded = try JSONDecoder().decode(FocusState.self, from: JSONEncoder().encode(state))
        assert(decoded.selectedTask(areaID: area)?.id == active)
        assert(decoded.selectedTask(areaID: other) == nil)
        state.setTaskArchived(active, true)
        assert(state.selectedTaskID == nil)
        assert(state.focusTasks(areaID: area).map(\.id) == [next, backlog])
        do { try state.selectTask(active, areaID: area); assertionFailure("Archived task must be rejected") } catch {}
        try state.selectTask(next, areaID: area)
        try state.selectTask(nil, areaID: area)
        assert(state.selectedTask(areaID: area) == nil)
    }

    func testEmptyTaskRejected() {
        var state = FocusState()
        do { try state.addTask(name: " \n ", areaID: nil, section: .active); assertionFailure("Expected empty task to be rejected") } catch {}
        assert(state.tasks.isEmpty)
    }
}
