import AppKit
import Combine
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var statusContent: StatusContent!
    private let popover = NSPopover()
    private var store: AppStore!
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditingMenu()
        store = AppStore()
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusContent = StatusContent(frame: button.bounds)
        statusContent.autoresizingMask = [.width, .height]
        button.addSubview(statusContent)
        button.setAccessibilityLabel("Lanes")

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let controller = NSHostingController(rootView: LanesPanel(store: store, popoverID: ObjectIdentifier(popover)) { [weak self] in self?.popover.performClose(nil) })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        subscription = store.$state.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatus() }
        updateStatus()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.togglePanel() }
        }
    }
    private func installEditingMenu() {
        // Accessory apps still need a responder-chain Edit menu for native Command-A/C/V/Z.
        let menu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Lanes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = applicationMenu; menu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    private func updateStatus() {
        let text = store.statusText
        let working = store.state.session != nil
        let font = NSFont.menuBarFont(ofSize: 13)
        let width = text.map { min(220, ($0 as NSString).size(withAttributes: [.font: font]).width) } ?? 0
        statusItem.length = text == nil ? 28 : width + 37
        statusContent.setLabel(text, working: working)
        statusItem.button?.toolTip = text ?? "Lanes — enter Focus Mode"
        statusItem.button?.setAccessibilityLabel(text ?? "Lanes — enter Focus Mode")
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            // Resolve SwiftUI's actual height before AppKit positions the popover.
            if let controller = popover.contentViewController as? NSHostingController<LanesPanel> {
                popover.contentSize = controller.sizeThatFits(in: NSSize(width: 310, height: 690))
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return false
    }
    func applicationDidResignActive(_ notification: Notification) { popover.performClose(nil) }
    func applicationDidHide(_ notification: Notification) { popover.performClose(nil) }
    func applicationWillTerminate(_ notification: Notification) { store.end() }
}

/// The button owns interaction; this clipped view only draws the logo, shield and bounded text.
@MainActor final class StatusContent: NSView {
    private var label: String?
    private var working = false
    private var animation: Timer?
    private var start = ProcessInfo.processInfo.systemUptime
    private let font = NSFont.menuBarFont(ofSize: 13)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func setLabel(_ value: String?, working: Bool) {
        guard label != value || self.working != working else { return }
        label = value; self.working = working
        start = ProcessInfo.processInfo.systemUptime
        animation?.invalidate(); animation = nil
        let width = value.map { ($0 as NSString).size(withAttributes: [.font: font]).width } ?? 0
        if width > 220 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.needsDisplay = true }
            }
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.labelColor
        let centerY = bounds.midY
        if working {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(.init(paletteColors: [color]))
            let image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)!
                .withSymbolConfiguration(configuration)!
            image.isTemplate = false
            image.draw(in: NSRect(x: 7, y: centerY - 8, width: 16, height: 16))
        } else {
            color.setFill()
            for (index, height) in [12.0, 16.0, 12.0].enumerated() {
                NSBezierPath(roundedRect: NSRect(x: 7 + Double(index) * 5, y: centerY - height / 2, width: 3, height: height), xRadius: 1.4, yRadius: 1.4).fill()
            }
        }
        guard let label else { return }
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        let rect = NSRect(x: 29, y: 0, width: min(220, bounds.width - 35), height: bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let y = centerY - font.boundingRectForFont.height / 2 - font.descender / 2
        if textWidth > rect.width && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Rightward, looping marquee. The menu bar item's width stays constant.
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - start - 1.5)
            let period = textWidth + 36
            let offset = (elapsed * 24).truncatingRemainder(dividingBy: period)
            (label as NSString).draw(at: NSPoint(x: rect.minX + offset, y: y), withAttributes: attributes)
            (label as NSString).draw(at: NSPoint(x: rect.minX + offset - period, y: y), withAttributes: attributes)
        } else {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (label as NSString).draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: 18), withAttributes: attributes.merging([.paragraphStyle: paragraph]) { _, new in new })
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
