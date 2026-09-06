import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }

    /// The model for the tab sidebar. This is nil for terminals that can never
    /// show a sidebar, in which case `tabsLocation` is always `top`.
    var sideTabs: SideTabsViewModel? { get }

    /// Where the tabs of this terminal are shown. This can change at runtime so
    /// implementations must publish changes to it.
    var tabsLocation: Ghostty.Config.MacOSTabsLocation { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            if let sideTabs = viewModel.sideTabs {
                // Terminals that can show a sidebar always lay out in an HStack,
                // even while the sidebar is hidden. The terminal content stays
                // at the same position in the view tree that way, so moving the
                // sidebar at runtime doesn't tear down the surfaces.
                HStack(spacing: 0) {
                    if viewModel.tabsLocation == .left {
                        SideTabsView(viewModel: sideTabs)
                        Divider()
                    }

                    terminalContent

                    if viewModel.tabsLocation == .right {
                        Divider()
                        SideTabsView(viewModel: sideTabs)
                    }
                }
            } else {
                terminalContent
            }
        }
    }

    private var terminalContent: some View {
        ZStack {
            VStack(spacing: 0) {
                // If we're running in debug mode we show a warning so that users
                // know that performance will be degraded.
                if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                    DebugBuildWarningView()
                }

                TerminalSplitTreeView(
                    tree: viewModel.surfaceTree,
                    action: { delegate?.performSplitAction($0) })
                    .environmentObject(ghostty)
                    .ghosttyLastFocusedSurface(lastFocusedSurface)
                    .focused($focused)
                    .onAppear { self.focused = true }
                    .onChange(of: focusedSurface) { newValue in
                        // We want to keep track of our last focused surface so even if
                        // we lose focus we keep this set to the last non-nil value.
                        if newValue != nil {
                            lastFocusedSurface = .init(newValue)
                            self.delegate?.focusedSurfaceDidChange(to: newValue)
                        }
                    }
                    .onChange(of: pwdURL) { newValue in
                        self.delegate?.pwdDidChange(to: newValue)
                    }
                    .onChange(of: cellSize) { newValue in
                        guard let size = newValue else { return }
                        self.delegate?.cellSizeDidChange(to: size)
                    }
                    .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                           idealHeight: lastFocusedSurface?.value?.initialSize?.height)
            }
            // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
            .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])

            if let surfaceView = lastFocusedSurface?.value {
                TerminalCommandPaletteView(
                    surfaceView: surfaceView,
                    isPresented: $viewModel.commandPaletteIsShowing,
                    ghosttyConfig: ghostty.config,
                    updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                    self.delegate?.performAction(action, on: surfaceView)
                }
            }

            // Show update information above all else.
            if viewModel.updateOverlayIsVisible {
                UpdateOverlay()
            }
        }
        .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
    }
}

/// The model behind the tab sidebar that is shown when `macos-tabs-location` is
/// `left` or `right`.
///
/// Tabs on macOS are windows in an `NSWindowTabGroup`, so this mirrors the tab
/// group of the window it belongs to. Every tab has its own controller and
/// therefore its own model, but only the selected tab's sidebar is on screen.
final class SideTabsViewModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        enum Kind: Equatable {
            case terminal
            case agent
        }

        enum Activity: Equatable {
            case idle
            case working
            case done
        }

        /// A tab is a window and windows have no identifier of their own, so we
        /// identify a tab by the window that backs it.
        let id: ObjectIdentifier
        let title: String
        let path: String
        let shortcut: String?
        let color: TerminalTabColor
        let isSelected: Bool
        let kind: Kind
        let activity: Activity
    }

    /// Title / path tokens that mark a tab as an agent session.
    private static let agentTitleTokens = [
        "claude", "codex", "cursor", "opencode", "aider", "gemini", "agent", "chatgpt",
    ]
    private static let agentPathTokens = [
        "/.claude/", "/.codex/", "/.cursor/", "/.opencode/",
    ]

    private static let titleWorkingWindow: TimeInterval = 2
    private static let doneDuration: TimeInterval = 3

    @Published private(set) var tabs: [Tab] = []

    private weak var controller: TerminalController?

    /// True while we're mirroring the tab group. We track this so that we only
    /// tear our observations down (and restore the tab bar) once.
    private var mirroring: Bool = false

    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var observedWindows: [ObjectIdentifier] = []

    private var lastTitleChange: [ObjectIdentifier: Date] = [:]
    private var doneUntil: [ObjectIdentifier: Date] = [:]
    private var doneClearWork: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var commandFinishedObserver: NSObjectProtocol?
    private var activityTimer: Timer?

    init(controller: TerminalController) {
        self.controller = controller
        commandFinishedObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyCommandDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleCommandFinished(note)
        }
    }

    deinit {
        tabGroupObservations.forEach { $0.invalidate() }
        titleObservations.forEach { $0.invalidate() }
        activityTimer?.invalidate()
        if let commandFinishedObserver {
            NotificationCenter.default.removeObserver(commandFinishedObserver)
        }
        doneClearWork.values.forEach { $0.cancel() }
    }

    // MARK: Tab List

    /// Resync our tab list with the window's tab group. This is safe to call as
    /// often as needed and does nothing while the sidebar is hidden.
    func refresh() {
        // Reading `window.tabGroup` materializes AppKit's tab group machinery,
        // which is expensive (see TerminalController.windowDidLoad), so don't
        // touch it at all unless the sidebar is (or was) showing.
        guard let controller, controller.tabsLocation != .top else {
            if mirroring { stopMirroring() }
            return
        }
        guard let hostWindow = controller.window else { return }

        mirroring = true

        // Every tab owns a model, but only the selected tab's sidebar is on
        // screen. Background models still watch selection/membership so they
        // can pick up when they become visible; they skip title observation and
        // the expensive list/accessory rebuilds that shells would otherwise fan
        // out across N² refreshes.
        let selectedWindow = hostWindow.tabGroup?.selectedWindow ?? hostWindow
        let isSelected = hostWindow === selectedWindow
        observe(hostWindow, observeTitles: isSelected)

        guard isSelected else {
            clearTitleObservations()
            stopActivityTimer()

            // Selecting a tab fans `selectedWindow` KVO out to *every* tab's
            // model, so a full rebuild here costs O(N) per background tab and
            // O(N²) per click. Background models only need a list that's
            // structurally right (the macOS tab overview renders their
            // sidebars), so rebuild when membership changes and otherwise just
            // move the highlight, which needs none of the per-window work.
            let windows = hostWindow.tabGroup?.windows ?? [hostWindow]
            if tabs.map(\.id) != windows.map(ObjectIdentifier.init) {
                refreshTabs(hostWindow)
            } else {
                updateSelection(to: ObjectIdentifier(selectedWindow))
            }
            return
        }

        syncNativeTabBar(hostWindow)
        startActivityTimer()
        refreshTabs(hostWindow)
    }

    /// Stop mirroring the tab group and undo everything we changed for the
    /// sidebar.
    private func stopMirroring() {
        mirroring = false
        refreshPending = false

        if let hostWindow = controller?.window {
            syncNativeTabBar(hostWindow)
        }

        tabGroupObservations.forEach { $0.invalidate() }
        tabGroupObservations = []
        observedTabGroup = nil
        clearTitleObservations()
        stopActivityTimer()
        tabs = []
    }

    private func clearTitleObservations() {
        titleObservations.forEach { $0.invalidate() }
        titleObservations = []
        observedWindows = []
    }

    private func observe(_ hostWindow: NSWindow, observeTitles: Bool) {
        let tabGroup = hostWindow.tabGroup

        if observedTabGroup !== tabGroup {
            observedTabGroup = tabGroup
            tabGroupObservations.forEach { $0.invalidate() }

            tabGroupObservations = [
                // Tabs added, removed, or reordered.
                tabGroup?.observe(\.windows, options: [.new]) { [weak self] _, _ in
                    self?.refreshLater()
                },

                // Which tab is selected, which is the row we highlight. We can't
                // rely on our controller becoming key for this since a tab can
                // be selected without that happening. Background models also use
                // this to start doing real work when they become selected.
                tabGroup?.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                    self?.refreshLater()
                },
            ].compactMap { $0 }
        }

        guard observeTitles else { return }

        // The tab titles are what we render, and AppKit gives us no single
        // notification for "some tab's title changed", so observe each window.
        // Only the selected (visible) sidebar needs this.
        let windows = tabGroup?.windows ?? [hostWindow]
        let windowIDs = windows.map(ObjectIdentifier.init)
        guard observedWindows != windowIDs else { return }
        observedWindows = windowIDs
        titleObservations.forEach { $0.invalidate() }
        titleObservations = windows.map { window in
            let id = ObjectIdentifier(window)
            return window.observe(\.title, options: [.new]) { [weak self] _, _ in
                self?.lastTitleChange[id] = Date()
                self?.refreshLater()
            }
        }
    }

    /// Refresh on the next main queue turn. Our observations rebind themselves,
    /// and replacing an observation from inside its own callback leaves the
    /// observed object retained, so we never refresh directly from one.
    /// Coalesce bursts (shell retitles, multi-window KVO) into a single pass.
    private var refreshPending = false
    private func refreshLater() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    /// Cheap poll for `progressReport` / title-based working / done expiry while
    /// the selected sidebar is visible. Title KVO still drives most updates.
    private func startActivityTimer() {
        guard activityTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let hostWindow = self.controller?.window else { return }
            self.refreshTabs(hostWindow)
        }
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
    }

    private func stopActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    /// The sidebar replaces the macOS tab bar, so the tab bar is hidden while the
    /// sidebar is shown and restored when it isn't. Each tab has its own tab bar,
    /// so the whole group is synced: a tab that joins the group can't hide its
    /// own tab bar until it knows where the group shows its tabs.
    private func syncNativeTabBar(_ hostWindow: NSWindow) {
        for window in hostWindow.tabGroup?.windows ?? [hostWindow] {
            (window as? TerminalWindow)?.syncNativeTabBarVisibility()
        }
    }

    private func refreshTabs(_ hostWindow: NSWindow) {
        let tabGroup = hostWindow.tabGroup
        let windows = tabGroup?.windows ?? [hostWindow]
        let selectedWindow = tabGroup?.selectedWindow ?? hostWindow
        let now = Date()

        let tabs = windows.enumerated().map { index, window in
            let id = ObjectIdentifier(window)
            let title = window.title.isEmpty ? "Terminal \(index + 1)" : window.title
            let path = Self.displayPath(for: window)
            let kind = Self.detectKind(title: title, path: path)
            return Tab(
                id: id,
                title: title,
                path: path,
                shortcut: shortcut(forTabAt: index),
                color: (window as? TerminalWindow)?.tabColor ?? .none,
                isSelected: window === selectedWindow,
                kind: kind,
                activity: activity(for: window, id: id, kind: kind, now: now))
        }

        // We refresh on every title change and shells retitle constantly, so
        // don't redraw the sidebar unless something it shows actually changed.
        guard tabs != self.tabs else { return }
        self.tabs = tabs
    }

    /// Move the selection highlight without redoing the per-window work
    /// (`pwd`, surface tree walks, kind detection) that `refreshTabs` does.
    private func updateSelection(to selectedID: ObjectIdentifier) {
        guard tabs.contains(where: { $0.isSelected != ($0.id == selectedID) }) else { return }
        tabs = tabs.map { tab in
            Tab(
                id: tab.id,
                title: tab.title,
                path: tab.path,
                shortcut: tab.shortcut,
                color: tab.color,
                isSelected: tab.id == selectedID,
                kind: tab.kind,
                activity: tab.activity)
        }
    }

    private func activity(
        for window: NSWindow,
        id: ObjectIdentifier,
        kind: Tab.Kind,
        now: Date
    ) -> Tab.Activity {
        if Self.isWorking(window) {
            return .working
        }

        if kind == .agent,
           let changed = lastTitleChange[id],
           now.timeIntervalSince(changed) < Self.titleWorkingWindow
        {
            return .working
        }

        if let until = doneUntil[id], until > now {
            return .done
        }

        return .idle
    }

    private func handleCommandFinished(_ note: Notification) {
        // Every terminal owns one of these models and this notification isn't
        // filtered by object, so all of them run this. Bail before touching
        // `window.tabGroup`, which materializes AppKit's tab group machinery
        // (see `refresh()`): a top-tabs window must not pay for a sidebar it
        // never draws.
        guard mirroring,
              let surface = note.object as? Ghostty.SurfaceView,
              let hostWindow = controller?.window
        else { return }

        // The surface knows the window it lives in, so we don't have to walk
        // every tab's surface tree looking for it.
        let windows = hostWindow.tabGroup?.windows ?? [hostWindow]
        guard let window = surface.window, windows.contains(window) else { return }

        let id = ObjectIdentifier(window)
        doneUntil[id] = Date().addingTimeInterval(Self.doneDuration)
        doneClearWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.doneUntil.removeValue(forKey: id)
            self.doneClearWork.removeValue(forKey: id)
            if let hostWindow = self.controller?.window {
                self.refreshTabs(hostWindow)
            }
        }
        doneClearWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doneDuration, execute: work)
        refreshTabs(hostWindow)
    }

    /// The keyboard shortcut that activates the tab at the given index. Only the
    /// first nine tabs get one, matching the labels we put on native tabs (see
    /// `TerminalController.relabelTabs`).
    private func shortcut(forTabAt index: Int) -> String? {
        guard index < 9 else { return nil }
        guard let config = controller?.ghostty.config else { return nil }
        guard let shortcut = config.keyboardShortcut(for: "goto_tab:\(index + 1)") else { return nil }
        return "\(shortcut)"
    }

    /// True if any surface in the window is reporting progress. A `.remove`
    /// report means the shell asked us to *stop* showing progress, and the
    /// report itself lingers for up to 15s after that (see `SurfaceView`), so
    /// treating every non-nil report as "working" leaves the spinner stuck.
    private static func isWorking(_ window: NSWindow) -> Bool {
        guard let controller = window.windowController as? TerminalController else { return false }
        return controller.surfaceTree.contains { surface in
            guard let report = surface.progressReport else { return false }
            return report.state != .remove
        }
    }

    private static func pwd(for window: NSWindow) -> String? {
        guard let controller = window.windowController as? TerminalController else { return nil }
        if let pwd = controller.focusedSurface?.pwd, !pwd.isEmpty {
            return pwd
        }
        return controller.surfaceTree.first?.pwd
    }

    private static func displayPath(for window: NSWindow) -> String {
        guard let pwd = pwd(for: window), !pwd.isEmpty else { return "" }
        let home = NSHomeDirectory()
        if pwd == home { return "~" }
        if pwd.hasPrefix(home + "/") {
            return "~" + String(pwd.dropFirst(home.count))
        }
        return pwd
    }

    private static func detectKind(title: String, path: String) -> Tab.Kind {
        let titleLower = title.lowercased()
        let pathLower = path.lowercased()
        let basename = (path as NSString).lastPathComponent.lowercased()

        if agentTitleTokens.contains(where: { titleLower.contains($0) }) {
            return .agent
        }
        if agentPathTokens.contains(where: { pathLower.contains($0) }) {
            return .agent
        }
        if agentTitleTokens.contains(where: { basename == $0 || basename.contains($0) }) {
            return .agent
        }
        return .terminal
    }

    // MARK: Actions

    func select(_ id: ObjectIdentifier) {
        // Making a tabbed window key selects its tab, the same way the
        // `goto_tab` action switches tabs.
        tabWindow(for: id)?.makeKeyAndOrderFront(nil)
    }

    private var lastClick: (id: ObjectIdentifier, at: Date)?

    /// Recognize a double-click on a row ourselves. A SwiftUI `count: 2` tap
    /// gesture would make selection wait out the whole double-click interval
    /// (half a second by default) on *every* click before it could fire, which
    /// is what made clicking a tab feel laggy. A button fires on each click, so
    /// we pair them up here instead: the first click selects immediately and
    /// the second one renames.
    func registerClick(on id: ObjectIdentifier) -> Bool {
        let now = Date()
        if let last = lastClick,
           last.id == id,
           now.timeIntervalSince(last.at) <= NSEvent.doubleClickInterval {
            lastClick = nil
            return true
        }

        lastClick = (id, now)
        return false
    }

    func newTab() {
        // Our controller is the selected tab because the sidebar is only ever
        // on screen for the selected tab.
        controller?.newTab(nil)
    }

    func close(_ id: ObjectIdentifier) {
        tabController(for: id)?.closeTab(nil)
    }

    func promptTitle(_ id: ObjectIdentifier) {
        tabController(for: id)?.promptTabTitle()
    }

    func closeOtherTabs(_ id: ObjectIdentifier) {
        tabController(for: id)?.closeOtherTabs(nil)
    }

    func closeTabsOnTheRight(_ id: ObjectIdentifier) {
        tabController(for: id)?.closeTabsOnTheRight(nil)
    }

    func setColor(_ color: TerminalTabColor, for id: ObjectIdentifier) {
        guard let window = tabWindow(for: id) as? TerminalWindow else { return }
        window.tabColor = color
        refresh()
    }

    func hasTabsOnTheRight(of id: ObjectIdentifier) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return index < tabs.count - 1
    }

    private func tabController(for id: ObjectIdentifier) -> TerminalController? {
        tabWindow(for: id)?.windowController as? TerminalController
    }

    private func tabWindow(for id: ObjectIdentifier) -> NSWindow? {
        guard let hostWindow = controller?.window else { return nil }
        return (hostWindow.tabGroup?.windows ?? [hostWindow]).first {
            ObjectIdentifier($0) == id
        }
    }
}

/// The tab sidebar shown on the left or right of a terminal window.
struct SideTabsView: View {
    /// The width of the sidebar.
    static let width: CGFloat = 260

    /// The width the sidebar takes from the window content, including the
    /// divider that separates it from the terminal.
    static let totalWidth: CGFloat = width + 1

    @ObservedObject var viewModel: SideTabsViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.tabs) { tab in
                        SideTabRow(tab: tab, viewModel: viewModel)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }

            Divider()

            Button(action: viewModel.newTab) {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Side Tabs New Tab")
        }
        .frame(width: Self.width)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Side Tabs")
        .onAppear(perform: viewModel.refresh)
    }
}

private struct SideTabRow: View {
    let tab: SideTabsViewModel.Tab
    @ObservedObject var viewModel: SideTabsViewModel

    var body: some View {
        Button {
            viewModel.select(tab.id)
            if viewModel.registerClick(on: tab.id) {
                viewModel.promptTitle(tab.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                SideTabIcon(kind: tab.kind, activity: tab.activity, color: tab.color)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        if !tab.path.isEmpty {
                            Text(tab.path)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        if tab.activity == .done {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                                .transition(.opacity)
                        }

                        if let shortcut = tab.shortcut {
                            Text(shortcut)
                                .font(.system(size: 9).monospaced())
                                .foregroundStyle(.tertiary)
                        }

                        // Reserve the space that the close button is drawn in.
                        Color.clear.frame(width: 16, height: 16)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Side Tab")
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.path)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tab.isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    tab.isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        )
        .overlay(alignment: .bottomTrailing) {
            Button { viewModel.close(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .padding(.bottom, 7)
            .help("Close Tab")
            .accessibilityIdentifier("Side Tab Close")
            .accessibilityLabel("Close \(tab.title)")
        }
        .contextMenu {
            Button("Rename Tab...") { viewModel.promptTitle(tab.id) }
            Divider()
            Button("Close Tab") { viewModel.close(tab.id) }
            Button("Close Other Tabs") { viewModel.closeOtherTabs(tab.id) }
                .disabled(viewModel.tabs.count < 2)
            Button("Close Tabs to the Right") { viewModel.closeTabsOnTheRight(tab.id) }
                .disabled(!viewModel.hasTabsOnTheRight(of: tab.id))
            Divider()
            Menu("Tab Color") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button(color.localizedName) { viewModel.setColor(color, for: tab.id) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.activity)
        .animation(.easeInOut(duration: 0.15), value: tab.isSelected)
    }
}

private struct SideTabIcon: View {
    let kind: SideTabsViewModel.Tab.Kind
    let activity: SideTabsViewModel.Tab.Activity
    let color: TerminalTabColor

    @State private var spinning = false

    private var fill: Color {
        switch kind {
        case .agent:
            return Color.orange.opacity(0.9)
        case .terminal:
            if let ns = color.displayColor {
                return Color(nsColor: ns)
            }
            return Color(nsColor: .tertiaryLabelColor).opacity(0.4)
        }
    }

    private var symbol: String {
        kind == .agent ? "sparkles" : "terminal"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 22, height: 22)

            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(kind == .agent ? Color.white : Color.primary.opacity(0.9))
                .rotationEffect(.degrees(kind == .agent && activity == .working && spinning ? 360 : 0))
                .opacity(kind == .agent && activity == .working ? (spinning ? 1.0 : 0.55) : 1.0)
        }
        .onAppear { updateSpin() }
        .onChange(of: activity) { _ in updateSpin() }
        .onChange(of: kind) { _ in updateSpin() }
    }

    private func updateSpin() {
        let shouldSpin = kind == .agent && activity == .working
        if shouldSpin {
            spinning = false
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                spinning = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                spinning = false
            }
        }
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
