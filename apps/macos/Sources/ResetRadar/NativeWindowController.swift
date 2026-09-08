import AppKit
import SwiftUI
import Combine

struct RadarWindowAction {
    var handler: @MainActor (String) -> Void = { _ in }
    @MainActor func callAsFunction(id: String) { handler(id) }
}
private struct RadarWindowActionKey: EnvironmentKey {
    static let defaultValue = RadarWindowAction()
}
private struct NativeWindowMaterialKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var radarOpenWindow: RadarWindowAction {
        get { self[RadarWindowActionKey.self] }
        set { self[RadarWindowActionKey.self] = newValue }
    }
    var nativeWindowMaterial: Bool {
        get { self[NativeWindowMaterialKey.self] }
        set { self[NativeWindowMaterialKey.self] = newValue }
    }
}

/// The actual window root owns the material. There is no SwiftUI popup container
/// or NSVisualEffectView between Clear Glass and the desktop on macOS 26.
@MainActor final class NativeWindowSurface: NSView {
    private let host: NSView
    private var material: NSView?
    private(set) var materialName = ""
    private var observer: NSObjectProtocol?
    override var isOpaque: Bool { false }

    init(host: NSView, size: NSSize) {
        self.host = host
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        rebuildMaterial()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildMaterial() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func rebuildMaterial() {
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            glass.contentView = nil
        }
        host.removeFromSuperview()
        material?.removeFromSuperview()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let backdrop = NSView(frame: bounds)
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            backdrop.addSubview(host)
            material = backdrop
            materialName = "system opaque (Reduce Transparency)"
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .clear
            glass.cornerRadius = 20
            glass.tintColor = nil
            glass.contentView = host
            material = glass
            materialName = "NSGlassEffectView.clear"
        } else {
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 20
            blur.layer?.masksToBounds = true
            blur.addSubview(host)
            material = blur
            materialName = "NSVisualEffectView.behindWindow"
        }
        if let material {
            material.autoresizingMask = [.width, .height]
            addSubview(material)
        }
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
    }
    override func layout() {
        super.layout()
        material?.frame = bounds
        host.frame = bounds
    }
}

@MainActor private final class ClearHostingView: NSHostingView<AnyView> {
    override var isOpaque: Bool { false }
}
@MainActor private final class RadarFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

private struct MenuPanelContent: View {
    @ObservedObject var model: DemoModel
    @ObservedObject var connections: ConnectionModel
    var body: some View {
        if connections.showRealFeed { WebFeedView(connections: connections) }
        else { RadarPanel(model: model) }
    }
}

/// Own the NSStatusItem and its borderless panel rather than inheriting the
/// material-filled window used by MenuBarExtra.window.
@MainActor final class NativeWindowController: NSObject {
    let model: DemoModel
    let connections: ConnectionModel
    private let statusItem: NSStatusItem
    private(set) var panel: NSPanel!
    private var windows: [String: NSWindow] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitor: Any?
    private var localMonitor: Any?

    init(model: DemoModel, connections: ConnectionModel) {
        self.model = model
        self.connections = connections
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        panel = RadarFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        configure(panel, content: AnyView(MenuPanelContent(model: model, connections: connections)), size: NSSize(width: 380, height: 640))
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        connections.objectWillChange.merge(with: model.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }.store(in: &cancellables)
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.updateStatus() }.store(in: &cancellables)
        updateStatus()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Keep our popovers and menus interactive; clicks on other app windows close the panel.
            if let self, let window = event.window, self.windows.values.contains(where: { $0 === window }) {
                self.panel.orderOut(nil)
            }
            return event
        }
    }

    private func configure(_ window: NSWindow, content: AnyView, size: NSSize) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let root = content
            .environment(\.nativeWindowMaterial, true)
            .environment(\.radarOpenWindow, RadarWindowAction { [weak self] id in self?.showWindow(id) })
        let host = ClearHostingView(rootView: AnyView(root))
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = NativeWindowSurface(host: host, size: size)
        window.setContentSize(size)
    }

    private func updateStatus() {
        let forecast = connections.currentProbability(asOf: Date())
        let indicator = MenuProbabilityAppearance(forecast?.probabilities.first)
        let real = connections.showRealFeed
        let description = real ? indicator.description : "Reset Radar · 离线演示"
        let button = statusItem.button
        button?.title = real ? " \(indicator.value) · 12h" : " \(model.values[0]) · Demo"
        button?.image = NSImage(systemSymbolName: real ? indicator.symbol : "play.circle", accessibilityDescription: description)
        button?.image?.isTemplate = true
        button?.toolTip = description
        button?.setAccessibilityLabel("Reset Radar，" + description)
    }
    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { showPanel() }
    }
    func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, anchor.minY - panel.frame.height - 6)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--surface-report"), args.count > index + 1 {
            let report: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "panel_visible": panel.isVisible,
                "material": (panel.contentView as? NativeWindowSurface)?.materialName ?? "unknown",
                "window_opaque": panel.isOpaque,
                "window_background_alpha": panel.backgroundColor.alphaComponent,
                "reduce_transparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
            }
        }
    }
    func showWindow(_ id: String, present: Bool = true) {
        if id == "web-feed" { connections.useRealFeed(); if present { showPanel() }; return }
        if present { panel.orderOut(nil) }
        if id == "rehearsal" { windows["onboarding"]?.orderOut(nil) }
        if let window = windows[id] {
            if present { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            return
        }
        let content: AnyView
        let size: NSSize
        let title: String
        switch id {
        case "settings":
            content = AnyView(RadarSettings(model: model, connections: connections))
            size = NSSize(width: 660, height: 780); title = "Reset Radar · 设置"
        case "reset-history":
            content = AnyView(CommunityHistoryView(connections: connections))
            size = NSSize(width: 540, height: 680); title = "Reset Radar · 历史 Reset"
        case "rehearsal":
            content = AnyView(RadarPanel(model: model))
            size = NSSize(width: 380, height: 640); title = "Reset Radar · 离线演示"
            windows["onboarding"]?.orderOut(nil)
        case "onboarding":
            content = AnyView(OnboardingView())
            size = NSSize(width: 500, height: 400); title = "Reset Radar · 开始使用"
        default: return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        configure(window, content: content, size: size)
        windows[id] = window
        window.center()
        if present {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// App-owned hierarchy checks only: no desktop capture, credentials or network.
    func validateSurface() throws {
        guard let root = panel.contentView as? NativeWindowSurface,
              !panel.isOpaque, panel.backgroundColor.alphaComponent == 0,
              root.subviews.count == 1 else { throw CocoaError(.validationMissingMandatoryProperty) }
        if #available(macOS 26.0, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            guard let glass = root.subviews.first as? NSGlassEffectView,
                  glass.style == .clear, glass.tintColor == nil,
                  glass.contentView is ClearHostingView,
                  glass.contentView?.isOpaque == false else { throw CocoaError(.validationMissingMandatoryProperty) }
        }
        print("PASS: borderless panel, opaque=false, window alpha=0, root material=\(root.materialName)")
        print("PASS: content is inside the native material; no MenuBarExtra or second backdrop")
        print("SYSTEM: reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
        for id in ["settings", "reset-history", "rehearsal", "onboarding"] {
            showWindow(id, present: false)
            guard let window = windows[id], !window.isOpaque,
                  window.contentView is NativeWindowSurface else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            window.layoutIfNeeded()
            print("PASS: window route \(id), content=\(Int(window.contentView!.bounds.width))x\(Int(window.contentView!.bounds.height))")
        }
        guard statusItem.button?.action == #selector(togglePanel), statusItem.button?.target === self else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let real = connections.showRealFeed
        connections.showRealFeed = false
        updateStatus()
        guard statusItem.button?.title.contains("Demo") == true else { throw CocoaError(.validationMissingMandatoryProperty) }
        connections.showRealFeed = true
        updateStatus()
        guard statusItem.button?.title.contains("12h") == true else { throw CocoaError(.validationMissingMandatoryProperty) }
        connections.showRealFeed = real
        updateStatus()
        print("PASS: status button target/action and real/demo indicator updates")
    }
}
