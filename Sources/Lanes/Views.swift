import AppKit
import LanesCore
import SwiftUI

enum Page: Equatable { case focus, settings, areas, inbox, history, websites, addArea }

struct LanesPanel: View {
    @ObservedObject var store: AppStore
    let popoverID: ObjectIdentifier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Page = .focus
    @State private var presentationID = UUID()
    @State private var areaName = ""
    @State private var areaLane: Lane = .primary
    @State private var ideaText = ""
    @State private var websiteText = ""
    @State private var proposedDomain: String?
    @State private var editingArea: UUID?
    @State private var showClearConfirmation = false
    var dismiss: () -> Void

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    switch page {
                    case .focus: focus
                    case .settings: settings
                    case .areas: areas
                    case .inbox: inbox
                    case .history: history
                    case .websites: websites
                    case .addArea: addArea
                    }
                }
                .id(page)
                .transition(.opacity)
            }
            .padding(12)
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: page)
        }
        .id(presentationID)
        .scrollIndicators(.hidden)
        .frame(width: 310)
        .frame(maxHeight: min(690, (NSScreen.main?.visibleFrame.height ?? 800) - 55))
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13))
        .controlSize(.small)
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { notification in
            guard let closedPopover = notification.object as? NSPopover,
                  ObjectIdentifier(closedPopover) == popoverID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                page = .focus
                presentationID = UUID()
            }
        }
        .onExitCommand { if page == .focus { dismiss() } else { page = .focus } }
        .alert("Lanes", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var focus: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = store.state.session {
                HStack {
                    Text(session.lane.rawValue).fontWeight(.semibold)
                    Spacer()
                    Menu("Switch lane") {
                        ForEach(Lane.allCases) { lane in Button(lane.rawValue) { store.start(lane) } }
                    }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(Color.accentColor)
                }.padding(.bottom, 9)
            } else {
                Text("Enter Focus Mode").fontWeight(.semibold).padding(.bottom, 8)
                ForEach(Lane.allCases) { lane in
                    MenuRow(action: { store.change { $0.selectedLane = lane } }, selected: store.currentLane == lane) {
                        Image(systemName: "checkmark").opacity(store.currentLane == lane ? 1 : 0).foregroundStyle(Color.accentColor).frame(width: 13)
                        Image(systemName: lane.symbol).frame(width: 17)
                        Text(lane.rawValue)
                        Spacer()
                    }.accessibilityLabel(lane.rawValue)
                }
                rule()
            }
            HStack(spacing: 8) {
                Text("Area").foregroundStyle(.secondary)
                Menu {
                    if store.state.areas(in: store.currentLane).count != 1 {
                        Button("No Area") { store.selectArea(nil) }
                    }
                    ForEach(store.state.areas(in: store.currentLane)) { area in
                        Button(area.name) { store.selectArea(area.id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(store.currentArea?.name ?? "No Area").font(.system(size: 13)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                    }
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.regular).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
            }.frame(height: 24)
            Button("Add New Area…") { areaName = ""; areaLane = .primary; editingArea = nil; page = .addArea }
                .buttonStyle(.link).padding(.leading, 35).padding(.top, 1)

            if let session = store.state.session {
                VStack(spacing: 1) {
                    Text(TimeText.clock(store.state.sessionDuration))
                        .font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.identity)
                    Text(session.isPaused ? "Paused" : "Elapsed").foregroundStyle(.secondary).font(.system(size: 12))
                }.frame(maxWidth: .infinity).padding(.vertical, 10)
            } else { Spacer().frame(height: 8) }

            if store.currentLane == .sandbox && store.state.preferences.sandboxBudgetEnabled {
                Label(store.budgetText, systemImage: "hourglass")
                    .font(.system(size: 12)).foregroundStyle(store.sandboxRemaining <= 0 ? Color.orange : .secondary)
                    .padding(.vertical, 6)
            }
            HStack(spacing: 8) {
                Image(systemName: store.blocker.active ? "shield.lefthalf.filled" : "shield")
                    .foregroundStyle(.secondary).frame(width: 17)
                Text(store.state.preferences.blockingEnabled ? store.blocker.message : "Website blocking off")
                    .lineLimit(2)
            }.padding(.vertical, 5)
            HStack(spacing: 8) {
                if let session = store.state.session {
                    Button(session.isPaused ? "Resume" : "Pause") { session.isPaused ? store.resume() : store.pause() }
                    Button("End focus") { store.end() }
                } else {
                    Spacer(minLength: 0)
                    Button { store.start(store.currentLane) } label: {
                        Text("Start Focus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 140)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Spacer(minLength: 0)
                }
            }.padding(.top, 4)
            if let text = store.recoveryMessage { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6) }
            rule()
            HStack {
                section("Today")
                Spacer()
                Button { page = .history } label: { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Session history").accessibilityLabel("Session history")
            }
            ForEach(Lane.allCases) { lane in valueRow(lane.rawValue, TimeText.duration(store.todayTotal(lane))) }
            if store.state.preferences.showProjects {
                rule()
                section("Focused projects")
                Text("Last 30 days").font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 3)
                let totals = store.state.projectTotals(at: store.now, count: store.state.preferences.projectCount)
                if totals.isEmpty {
                    Text("Your project time will appear here.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(totals, id: \.area.id) { item in valueRow(item.area.name, TimeText.duration(item.duration)) }
            }
            rule()
            MenuRow(action: { page = .inbox }) {
                Image(systemName: "tray").frame(width: 17)
                Text("Curiosity Inbox")
                Spacer()
                if !store.state.ideas.isEmpty {
                    Text("\(store.state.ideas.count)").font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.primary.opacity(0.07), in: Capsule())
                }
            }
            MenuRow(action: { page = .settings }) { Image(systemName: "gearshape").frame(width: 17); Text("Settings…"); Spacer() }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Settings")
            section("Focus")
            settingToggle("Block websites", value: Binding(get: { store.state.preferences.blockingEnabled }, set: { store.setBlocking($0) }))
            if !store.blocker.ready {
                Button(store.blocker.busy ? "Setting up…" : (store.blocker.installed ? "Repair website blocking…" : "Set up website blocking…")) { store.blocker.install() }
                    .disabled(store.blocker.busy).padding(.vertical, 3)
                Text(store.blocker.installed ? "Approve the repaired network setup once. Focus sessions then run automatically." : "Approve network setup once. Blocking stays on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Local blocker ready · no browser extension needed")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.blocker.setupError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
            }
            if store.blocker.installed {
                Button("Remove blocking setup…") { store.blocker.remove() }.buttonStyle(.link).disabled(store.blocker.busy).padding(.vertical, 3)
            }
            link("Edit blocked websites…", to: .websites)
            rule()
            section("Area limits")
            ForEach(Lane.allCases) { lane in
                HStack {
                    Text(lane.rawValue); Spacer()
                    Menu {
                        Button("No limit") { store.change { try $0.setLimit(nil, lane: lane) } }
                        ForEach(1...20, id: \.self) { number in Button("\(number)") { store.change { try $0.setLimit(number, lane: lane) } } }
                    } label: { Text(store.state.limit(for: lane).map(String.init) ?? "No limit") }
                        .menuStyle(.borderlessButton).fixedSize()
                }.frame(height: 25)
            }
            link("Manage Areas…", to: .areas)
            rule()
            section("Sandbox")
            settingToggle("Daily time budget", value: preference(\.sandboxBudgetEnabled))
            HStack {
                Text("Daily limit"); Spacer()
                Stepper(value: preference(\.sandboxMinutes), in: 5...720, step: 5) {
                    Text("\(store.state.preferences.sandboxMinutes) min").monospacedDigit().frame(minWidth: 47, alignment: .trailing)
                }.fixedSize()
            }.frame(height: 26).disabled(!store.state.preferences.sandboxBudgetEnabled)
            Text("Across all Sandbox sessions").font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 4)
            settingToggle("Notify at daily limit", value: Binding(get: { store.state.preferences.budgetNotifications }, set: store.enableNotifications))
                .disabled(!store.state.preferences.sandboxBudgetEnabled)
            rule()
            section("Menu bar")
            settingToggle("Show active Area", value: preference(\.showActiveArea))
            rule()
            section("Focused projects")
            settingToggle("Show below Today", value: preference(\.showProjects))
            HStack {
                Text("Number of Areas"); Spacer()
                Picker("", selection: preference(\.projectCount)) { ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }
                    .labelsHidden().fixedSize()
            }.frame(height: 25).disabled(!store.state.preferences.showProjects)
            rule()
            settingToggle("Launch at login", value: Binding(get: { store.state.preferences.launchAtLogin }, set: store.setLaunchAtLogin))
            HStack { Image(systemName: "internaldrive"); Text("Saved on this Mac"); Spacer() }.foregroundStyle(.secondary).padding(.vertical, 5)
            Button("Quit Lanes") { store.end(); NSApp.terminate(nil) }.buttonStyle(.plain).padding(.top, 4)
        }
    }

    private var areas: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Manage Areas", back: .settings)
            if store.state.areas.isEmpty { empty("No Areas yet", "You can focus using just a lane.") }
            ForEach(store.state.areas) { area in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(area.name).lineLimit(2); Spacer()
                        Button { editingArea = area.id; areaName = area.name; page = .addArea } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).help("Rename Area")
                    }
                    HStack {
                        Text("Lane").foregroundStyle(.secondary); Spacer()
                        Menu {
                            Button("Unassigned") { store.moveArea(area.id, to: nil) }
                            ForEach(Lane.allCases) { lane in Button(lane.rawValue) { store.moveArea(area.id, to: lane) } }
                        } label: { Text(area.lane?.rawValue ?? "Unassigned") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }.padding(.vertical, 7)
                Divider()
            }
            Button("Add New Area…") { editingArea = nil; areaName = ""; areaLane = .primary; page = .addArea }.buttonStyle(.link).padding(.top, 10)
            Text("Moving an Area keeps its time history.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
    private var addArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(editingArea == nil ? "Add New Area" : "Rename Area", back: .areas)
            TextField("Area name", text: $areaName).textFieldStyle(.roundedBorder).onSubmit(saveArea)
            if editingArea == nil {
                HStack {
                    Text("Lane"); Spacer()
                    Menu {
                        ForEach(Lane.allCases) { lane in Button(lane.rawValue) { areaLane = lane } }
                    } label: { Text(areaLane.rawValue).font(.system(size: 13)) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Lane, \(areaLane.rawValue)")
                }
                if let limit = store.state.limit(for: areaLane) {
                    Text("\(store.state.areas(in: areaLane).count) of \(limit) Areas assigned")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Cancel") { page = .focus }
                Button("Save Area", action: saveArea).buttonStyle(.borderedProminent).disabled(areaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func saveArea() {
        let lane = areaLane
        let saved = store.change {
            if let id = editingArea { try $0.renameArea(id, name: areaName) }
            else { _ = try $0.addArea(name: areaName, lane: lane) }
        }
        if saved { areaName = ""; page = .focus }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Curiosity Inbox")
            Text("Save the thought. Keep your place.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 10)
            HStack {
                TextField("An idea for later…", text: $ideaText).textFieldStyle(.roundedBorder).onSubmit(saveIdea)
                Button(action: saveIdea) { Image(systemName: "plus") }.disabled(ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help("Save idea")
            }
            rule()
            if store.state.ideas.isEmpty { empty("Nothing parked yet", "Capture a thought without switching tasks.") }
            ForEach(store.state.ideas) { idea in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(idea.text).fixedSize(horizontal: false, vertical: true)
                        Text(idea.created, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { store.change { $0.ideas.removeAll { $0.id == idea.id } } } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Delete idea")
                }.padding(.vertical, 8)
                Divider()
            }
        }
    }
    private func saveIdea() {
        store.change { $0.addIdea(ideaText, at: store.now) }; ideaText = ""
    }

    private var websites: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Blocked websites", back: .settings)
            Text("Whole domains and their subdomains.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 10)
            HStack {
                TextField("example.com", text: $websiteText).textFieldStyle(.roundedBorder).onSubmit(proposeWebsite)
                Button("Add", action: proposeWebsite)
            }
            if let domain = proposedDomain {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Block all of \(domain), including subdomains?").font(.system(size: 12))
                    HStack {
                        Button("Cancel") { proposedDomain = nil }
                        Button("Add domain") {
                            store.updateDomains(Array(Set(store.state.preferences.blockedDomains + [domain])).sorted())
                            proposedDomain = nil; websiteText = ""
                        }
                    }
                }.padding(.vertical, 8)
            }
            rule()
            ForEach(store.state.preferences.blockedDomains, id: \.self) { domain in
                HStack {
                    Text(domain); Spacer()
                    Button { store.updateDomains(store.state.preferences.blockedDomains.filter { $0 != domain }) } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Remove domain")
                }.frame(height: 26)
            }
            if store.state.preferences.blockedDomains.isEmpty {
                Text("No websites selected.").foregroundStyle(.secondary).padding(.vertical, 5)
                ForEach(["youtube.com", "x.com", "instagram.com"], id: \.self) { domain in
                    Button("Add \(domain)") { proposedDomain = domain }.buttonStyle(.link).padding(.vertical, 4)
                }
            }
            rule()
            Text("Applies during Focus in browsers using this Mac’s proxy settings. HTTPS stays encrypted.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func proposeWebsite() {
        do { proposedDomain = try DomainRule.normalize(websiteText) } catch { store.error = error.localizedDescription }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Session history")
            if store.state.segments.filter({ $0.duration > 0 }).isEmpty { empty("No focus time yet", "Your sessions will appear here.") }
            ForEach(store.state.segments.filter { $0.duration > 0 }.reversed().prefix(100).map { $0 }) { record in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(store.state.area(record.areaID)?.name ?? record.lane.rawValue).lineLimit(1)
                        Spacer()
                        Text(TimeText.duration(record.duration)).monospacedDigit()
                    }
                    HStack {
                        Text(record.lane.rawValue)
                        Spacer()
                        Text(record.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.vertical, 7)
                Divider()
            }
            Text("Most recent 100 segments · all time is saved.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
            Button("Clear time history…") { showClearConfirmation = true }.buttonStyle(.link).padding(.top, 8)
                .disabled(store.state.session != nil)
                .confirmationDialog("Delete all saved time history? Areas and ideas will stay.", isPresented: $showClearConfirmation) {
                    Button("Delete history", role: .destructive) { store.change { $0.segments = [] } }
                }
        }
    }

    private func preference<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { store.state.preferences[keyPath: key] }, set: { value in store.change { $0.preferences[keyPath: key] = value } })
    }
    private func header(_ title: String, back: Page = .focus) -> some View {
        HStack(spacing: 6) {
            Button { page = back } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).help("Back").accessibilityLabel("Back")
            Text(title).fontWeight(.semibold)
            Spacer()
        }.padding(.bottom, 12)
    }
    private func link(_ text: String, to destination: Page) -> some View {
        Button(text) { page = destination }.buttonStyle(.link).padding(.vertical, 4)
    }
    private func section(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
    }
    private func rule() -> some View { Divider().padding(.vertical, 9) }
    private func valueRow(_ name: String, _ value: String) -> some View {
        HStack { Text(name).lineLimit(1); Spacer(minLength: 8); Text(value).monospacedDigit().foregroundStyle(.primary) }.frame(height: 23)
    }
    private func settingToggle(_ name: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(name)
            Spacer(minLength: 8)
            Toggle(name, isOn: value).labelsHidden().toggleStyle(.switch).fixedSize()
        }.frame(maxWidth: .infinity, minHeight: 26)
    }
    private func empty(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.vertical, 10)
    }
}

struct MenuRow<Content: View>: View {
    var action: () -> Void
    var selected = false
    @ViewBuilder var content: () -> Content
    @State private var hovered = false
    var body: some View {
        Button(action: action) { HStack(spacing: 8, content: content).padding(.horizontal, 5).frame(height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .background((selected || hovered) ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}
