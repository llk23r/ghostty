import AppKit

/// AppleScript-facing wrapper around a logical Ghostty window.
///
/// In AppKit, each tab is often its own `NSWindow`. AppleScript users, however,
/// expect a single window object containing a list of tabs.
///
/// `ScriptWindow` is that compatibility layer:
/// - It presents one object per tab group.
/// - It translates tab-group state into `tabs` and `selected tab`.
/// - It exposes stable IDs that Cocoa scripting can resolve later.
@MainActor
@objc(GhosttyScriptWindow)
final class ScriptWindow: NSObject {
    /// Stable identifier used by AppleScript `window id "..."` references.
    ///
    /// We precompute this once so the object keeps a consistent ID for its whole
    /// lifetime, even if AppKit window bookkeeping changes after creation.
    let stableID: String

    /// Canonical representative for this scripting window's tab group.
    ///
    /// We intentionally keep only one controller reference; full tab membership
    /// is derived lazily from current AppKit state whenever needed.
    private weak var primaryController: BaseTerminalController?

    init(stableID: String, primaryController: BaseTerminalController? = nil) {
        self.stableID = stableID
        self.primaryController = primaryController
    }

    /// `scriptWindows` in `AppDelegate+AppleScript` constructs these objects.
    ///
    /// `stableID` must match the same identity scheme used by
    /// `valueInScriptWindowsWithUniqueID:` so Cocoa can re-resolve object
    /// specifiers produced earlier in a script.
    convenience init(primaryController: BaseTerminalController) {
        self.init(
            stableID: Ghostty.TerminalHierarchy.windowID(for: primaryController),
            primaryController: primaryController
        )
    }

    private var hierarchyWindow: Ghostty.TerminalHierarchy.Snapshot.Window? {
        Ghostty.TerminalHierarchy.snapshot().window(id: stableID)
    }

    /// Exposed as the AppleScript `id` property.
    ///
    /// This is what scripts read with `id of window ...`.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    ///
    /// Returns the title of the window (from the selected/primary controller's NSWindow).
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return hierarchyWindow?.title ?? selectedController?.window?.title ?? ""
    }

    /// Exposed as the AppleScript `tabs` element.
    ///
    /// Cocoa asks for this collection when a script evaluates `tabs of window ...`
    /// or any tab-filter expression. We build wrappers from live controller state
    /// so tab additions/removals are reflected immediately.
    @objc(tabs)
    var tabs: [ScriptTab] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        let snapshot = Ghostty.TerminalHierarchy.snapshot()
        if let hierarchyWindow {
            return hierarchyWindow.tabIDs.map {
                ScriptTab(window: self, stableID: $0, controller: snapshot.tab(id: $0)?.controller)
            }
        }

        return controllers.map { ScriptTab(window: self, controller: $0) }
    }

    /// Exposed as the AppleScript `selected tab` property.
    ///
    /// This powers expressions like `selected tab of window 1`.
    @objc(selectedTab)
    var selectedTab: ScriptTab? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        let snapshot = Ghostty.TerminalHierarchy.snapshot()
        if let selectedTabID = hierarchyWindow?.selectedTabID {
            return ScriptTab(
                window: self,
                stableID: selectedTabID,
                controller: snapshot.tab(id: selectedTabID)?.controller
            )
        }

        guard let selectedController else { return nil }
        return ScriptTab(window: self, controller: selectedController)
    }

    /// Enables unique-ID lookup for `tabs` references.
    ///
    /// Required selector pattern for the `tabs` element key:
    /// `valueInTabsWithUniqueID:`.
    ///
    /// Cocoa uses this when a script resolves `tab id "..." of window ...`.
    @objc(valueInTabsWithUniqueID:)
    func valueInTabs(uniqueID: String) -> ScriptTab? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        let snapshot = Ghostty.TerminalHierarchy.snapshot()
        if hierarchyWindow?.tabIDs.contains(uniqueID) == true {
            return ScriptTab(window: self, stableID: uniqueID, controller: snapshot.tab(id: uniqueID)?.controller)
        }

        guard let controller = controller(tabID: uniqueID) else { return nil }
        return ScriptTab(window: self, controller: controller)
    }

    /// Exposed as the AppleScript `terminals` element on a window.
    ///
    /// Returns all terminal surfaces across every tab in this window.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        if let hierarchyWindow {
            return hierarchyWindow.terminalIDs.map(ScriptTerminal.init)
        }

        return controllers
            .flatMap { $0.surfaceTree.root?.leaves() ?? [] }
            .map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a window.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        if hierarchyWindow?.terminalIDs.contains(uniqueID) == true {
            return ScriptTerminal(stableID: uniqueID)
        }

        return controllers
            .flatMap { $0.surfaceTree.root?.leaves() ?? [] }
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// AppleScript tab indexes are 1-based, so we add one to Swift's 0-based
    /// array index.
    func tabIndex(for controller: BaseTerminalController) -> Int? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        if let hierarchyWindow {
            let tabID = Ghostty.TerminalHierarchy.tabID(for: controller)
            return hierarchyWindow.tabIDs.firstIndex(of: tabID).map { $0 + 1 }
        }

        return controllers.firstIndex(where: { $0 === controller }).map { $0 + 1 }
    }

    /// Reports whether a given controller maps to this window's selected tab.
    func tabIsSelected(_ controller: BaseTerminalController) -> Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        if let selectedTabID = hierarchyWindow?.selectedTabID {
            return selectedTabID == Ghostty.TerminalHierarchy.tabID(for: controller)
        }

        return selectedController === controller
    }

    /// Best-effort native window to use as a tab parent for AppleScript commands.
    var preferredParentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return hierarchyWindow?.window ?? selectedController?.window ?? controllers.first?.window
    }

    /// Best-effort controller to use for window-scoped AppleScript commands.
    var preferredController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return hierarchyWindow?.preferredController ?? selectedController ?? controllers.first
    }

    /// Resolves a previously generated tab ID back to a live controller.
    private func controller(tabID: String) -> BaseTerminalController? {
        let snapshot = Ghostty.TerminalHierarchy.snapshot()
        return snapshot.tab(id: tabID)?.controller ??
            controllers.first(where: { ScriptTab.stableID(controller: $0) == tabID })
    }

    /// Live controller list for this scripting window.
    ///
    /// We recalculate on every access so AppleScript immediately sees tab-group
    /// changes (new tabs, closed tabs, tab moves) without rebuilding all objects.
    private var controllers: [BaseTerminalController] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        let snapshot = Ghostty.TerminalHierarchy.snapshot()
        if let hierarchyWindow {
            return hierarchyWindow.tabIDs.compactMap { snapshot.tab(id: $0)?.controller }
        }

        guard let primaryController else { return [] }
        guard let window = primaryController.window else { return [primaryController] }

        if let tabGroup = window.tabGroup {
            let groupControllers = tabGroup.windows.compactMap {
                $0.windowController as? BaseTerminalController
            }
            if !groupControllers.isEmpty {
                return groupControllers
            }
        }

        return [primaryController]
    }

    /// Live selected controller for this scripting window.
    ///
    /// AppKit tracks selected tab on `NSWindowTabGroup.selectedWindow`; for
    /// non-tabbed windows we fall back to the primary controller.
    private var selectedController: BaseTerminalController? {
        let snapshot = Ghostty.TerminalHierarchy.snapshot()
        if let selectedTabID = hierarchyWindow?.selectedTabID {
            return snapshot.tab(id: selectedTabID)?.controller ?? hierarchyWindow?.preferredController
        }

        guard let primaryController else { return nil }
        guard let window = primaryController.window else { return primaryController }

        if let tabGroup = window.tabGroup,
           let selectedController = tabGroup.selectedWindow?.windowController as? BaseTerminalController {
            return selectedController
        }

        return controllers.first
    }

    /// Handler for `activate window <window>`.
    @objc(handleActivateWindowCommand:)
    func handleActivateWindow(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let windowContainer = preferredParentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Window is no longer available."
            return nil
        }

        windowContainer.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }

    /// Handler for `close window <window>`.
    @objc(handleCloseWindowCommand:)
    func handleCloseWindow(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        if let managedTerminalController = preferredController as? TerminalController {
            managedTerminalController.closeWindowImmediately()
            return nil
        }

        guard let windowContainer = preferredParentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Window is no longer available."
            return nil
        }

        windowContainer.close()
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    ///
    /// Without this, Cocoa can return data but cannot reliably build object
    /// references for later script statements. This specifier encodes:
    /// `application -> scriptWindows[id]`.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "scriptWindows",
            uniqueID: stableID
        )
    }
}

extension ScriptWindow {
    /// Produces the window-level stable ID from the primary controller.
    ///
    /// - Tabbed windows are keyed by tab-group identity.
    /// - Standalone windows are keyed by window identity.
    /// - Detached controllers fall back to controller identity.
    static func stableID(primaryController: BaseTerminalController) -> String {
        Ghostty.TerminalHierarchy.windowID(for: primaryController)
    }

    /// Stable ID for a standalone native window.
    static func stableID(window: NSWindow) -> String {
        Ghostty.TerminalHierarchy.windowID(for: window)
    }

    /// Stable ID for a native AppKit tab group.
    static func stableID(tabGroup: NSWindowTabGroup) -> String {
        Ghostty.TerminalHierarchy.windowID(for: tabGroup)
    }
}
