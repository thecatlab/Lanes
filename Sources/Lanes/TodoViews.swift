import AppKit
import LanesCore
import SwiftUI
import UniformTypeIdentifiers

struct CountBadge: View {
    let count: Int
    var fontSize: CGFloat = 11
    var body: some View {
        Text("\(count)").font(.system(size: fontSize)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.primary.opacity(0.07), in: Capsule())
    }
}

struct AreaBadge: View {
    let area: Area
    var body: some View {
        Text(area.name.count > 10 ? String(area.name.prefix(10)) + ".." : area.name)
            .font(.system(size: 11)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.color(for: area).opacity(0.2), in: Capsule())
            .fixedSize().help(area.name).accessibilityLabel("Area: \(area.name)")
    }
    static func color(for area: Area) -> Color {
        if let hex = area.badgeColor, let value = UInt32(hex, radix: 16) {
            return Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
        }
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]
        let index = area.id.uuidString.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
        return palette[index]
    }
    static func hex(_ color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

private enum TodoScreen: Equatable {
    case list, archive, inbox(TodoSection), editor(TodoTask, isNew: Bool)
}

struct TodoPage: View {
    @ObservedObject var store: AppStore
    let maximumHeight: CGFloat
    let back: () -> Void
    @State private var screen: TodoScreen = .list
    @State private var draggedTask: UUID?
    private let rowHeight: CGFloat = 30
    private var visibleRows: Int { max(5, min(30, store.state.preferences.todoVisibleRows ?? 10)) }
    private var openTasks: [TodoTask] { store.state.tasks.filter { !$0.isArchived } }
    private var archivedTasks: [TodoTask] { store.state.tasks.filter(\.isArchived) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch screen {
            case .list: list
            case .archive: archive
            case .inbox(let section): inbox(section)
            case .editor(let task, let isNew):
                header(isNew ? "Add Task" : "Edit Task")
                TodoEditor(store: store, task: task, isNew: isNew) { screen = .list }
                    .id(task.id)
            }
        }
        .padding(12)
        .onExitCommand { if screen == .list { back() } else { screen = .list } }
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 6) {
            Button { if screen == .list { back() } else { screen = .list } } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }.buttonStyle(.plain).help("Back").accessibilityLabel("Back")
            Text(title).fontWeight(.semibold)
            Spacer()
            if screen == .list {
                Menu {
                    Text("Visible tasks")
                    ForEach([5, 10, 15, 20, 30], id: \.self) { count in
                        Button { store.change { $0.preferences.todoVisibleRows = count } } label: {
                            if count == visibleRows { Label("\(count) tasks", systemImage: "checkmark") }
                            else { Text("\(count) tasks") }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Maximum visible tasks").accessibilityLabel("Maximum visible tasks")
            }
        }.padding(.bottom, 12)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("To-do")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(TodoSection.allCases) { section in
                        taskSection(section)
                        if section != .backlog { Divider().padding(.vertical, 9) }
                    }
                }
            }
            .frame(height: listHeight)
            Divider().padding(.vertical, 9)
            MenuRow(action: { screen = .archive }) {
                Image(systemName: "archivebox").frame(width: 17)
                Text("Archive")
                CountBadge(count: archivedTasks.count, fontSize: 13)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var listHeight: CGFloat {
        // Count rows in priority order so Active and Next stay visible before Backlog scrolls.
        var remaining = visibleRows
        var height: CGFloat = 0
        for section in TodoSection.allCases {
            if remaining == 0 { break }
            if section != .active { height += 19 }
            height += 26
            let count = openTasks.filter { $0.section == section }.count
            height += CGFloat(max(1, min(count, remaining))) * rowHeight
            remaining -= min(count, remaining)
        }
        return min(height, max(80, maximumHeight - 96))
    }

    private func taskSection(_ section: TodoSection) -> some View {
        let tasks = openTasks.filter { $0.section == section }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(section.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                CountBadge(count: tasks.count)
                Spacer()
                Menu {
                    Button("New task…") { screen = .editor(TodoTask(name: "", areaID: nil, section: section), isNew: true) }
                    Button("From Curiosity Inbox…") { screen = .inbox(section) }
                } label: { Image(systemName: "plus").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Add task to \(section.rawValue)").accessibilityLabel("Add task to \(section.rawValue)")
            }.frame(height: 26)
            ForEach(tasks) { task in
                taskRow(task)
                    .onDrag {
                        draggedTask = task.id
                        return NSItemProvider(object: "lanes-task:\(task.id.uuidString)" as NSString)
                    }
                    .modifier(TaskDropTarget(store: store, draggedTask: $draggedTask, section: section, taskID: task.id))
            }
            if tasks.isEmpty {
                Text("Add a task or drop one here")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .modifier(TaskDropTarget(store: store, draggedTask: $draggedTask, section: section, taskID: nil))
    }

    private func taskRow(_ task: TodoTask) -> some View {
        HStack(spacing: 7) {
            Toggle("Complete \(task.name)", isOn: Binding(get: { task.isArchived }, set: { value in store.change { $0.setTaskArchived(task.id, value) } }))
                .toggleStyle(.checkbox).labelsHidden().fixedSize()
                .help(task.isArchived ? "Restore task to \(task.section.rawValue)" : "Complete task and move to Archive")
            Text(task.name).lineLimit(1).help(task.name)
            Spacer(minLength: 2)
            if let area = store.state.area(task.areaID) { AreaBadge(area: area) }
        }
        .padding(.horizontal, 3).frame(height: rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            if !task.isArchived {
                Button("Edit task…") { screen = .editor(task, isNew: false) }
                Menu("Move to") {
                    ForEach(TodoSection.allCases) { section in
                        Button(section.rawValue) { store.change { $0.moveTask(task.id, to: section) } }
                    }
                }
            }
            Button(task.isArchived ? "Restore task" : "Complete task") { store.change { $0.setTaskArchived(task.id, !task.isArchived) } }
        }
    }

    private var archive: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Archive")
            if archivedTasks.isEmpty {
                Text("Completed tasks will appear here.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                Text("Uncheck a task to restore it.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
                ScrollView { VStack(spacing: 0) { ForEach(archivedTasks) { taskRow($0) } } }
                    .frame(height: min(CGFloat(min(visibleRows, archivedTasks.count)) * rowHeight, max(80, maximumHeight - 100)))
            }
        }
    }

    private func inbox(_ section: TodoSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header("From Curiosity Inbox")
            Text("Choose an idea. The original stays in your Inbox.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            if store.state.ideas.isEmpty {
                Text("No ideas yet.").foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.state.ideas) { idea in
                            Button {
                                screen = .editor(TodoTask(name: idea.text, areaID: nil, section: section), isNew: true)
                            } label: {
                                HStack {
                                    Text(idea.text).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "plus").foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(idea.text)
                            Divider()
                        }
                    }
                }.frame(height: min(CGFloat(store.state.ideas.count) * 48, max(80, maximumHeight - 110), 300))
            }
        }
    }
}

struct TodoEditor: View {
    @ObservedObject var store: AppStore
    @State var task: TodoTask
    let isNew: Bool
    var locksArea = false
    var onSave: (UUID) -> Void = { _ in }
    let done: () -> Void
    @SwiftUI.FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Task name", text: $task.name).textFieldStyle(.roundedBorder).focused($nameFocused).onSubmit(save)
            HStack {
                Text("Area"); Spacer()
                if locksArea {
                    Text(store.state.area(task.areaID)?.name ?? "No Area").lineLimit(1)
                } else {
                    Menu {
                        Button("No Area") { task.areaID = nil }
                        ForEach(store.state.areas) { area in Button(area.name) { task.areaID = area.id } }
                    } label: {
                        Text(store.state.area(task.areaID)?.name ?? "No Area").lineLimit(1)
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            HStack {
                Text("Section"); Spacer()
                Picker("Section", selection: $task.section) {
                    ForEach(TodoSection.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
            }
            HStack {
                Button("Cancel", action: done)
                Button(isNew ? "Add Task" : "Save Task", action: save)
                    .buttonStyle(.borderedProminent).disabled(task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.onAppear { nameFocused = true }
    }
    private func save() {
        let saved = store.change { state in
            if isNew { task.id = try state.addTask(name: task.name, areaID: task.areaID, section: task.section) }
            else if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
                let name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw FocusError.message("Give this task a name.") }
                task.name = name
                state.tasks[index] = task
            }
        }
        if saved { onSave(task.id); done() }
    }
}

private struct TaskDropTarget: ViewModifier {
    @ObservedObject var store: AppStore
    @Binding var draggedTask: UUID?
    let section: TodoSection
    let taskID: UUID?
    @State private var edge: VerticalEdge?
    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .bottom ? .bottom : .top) {
            if edge != nil && draggedTask != nil { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) }
        }
        .onDrop(of: [.text], delegate: TaskDropDelegate(store: store, draggedTask: $draggedTask, edge: $edge, section: section, taskID: taskID))
    }
}

private struct TaskDropDelegate: DropDelegate {
    let store: AppStore
    @Binding var draggedTask: UUID?
    @Binding var edge: VerticalEdge?
    let section: TodoSection
    let taskID: UUID?
    func validateDrop(info: DropInfo) -> Bool { draggedTask != nil && info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { updateEdge(info) }
    func dropExited(info: DropInfo) { edge = nil }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateEdge(info)
        return DropProposal(operation: .move)
    }
    private func updateEdge(_ info: DropInfo) { edge = taskID != nil && info.location.y < 15 ? .top : .bottom }
    func performDrop(info: DropInfo) -> Bool {
        defer { edge = nil; draggedTask = nil }
        guard let draggedTask, let provider = info.itemProviders(for: [.text]).first else { return false }
        if draggedTask == taskID { return true }
        var target = taskID
        if edge == .bottom, let taskID {
            let tasks = store.state.tasks.filter { !$0.isArchived && $0.section == section && $0.id != draggedTask }
            if let index = tasks.firstIndex(where: { $0.id == taskID }) { target = tasks.dropFirst(index + 1).first?.id }
        }
        let destination = target
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard value as? String == "lanes-task:\(draggedTask.uuidString)" else { return }
            Task { @MainActor in
                store.change { $0.moveTask(draggedTask, to: section, before: destination) }
            }
        }
        return true
    }
}
