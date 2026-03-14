#if canImport(AppKit)
import AppKit
import GhosttyKit

extension Ghostty {
    enum TerminalHierarchy {
        struct Snapshot {
            struct Window {
                let id: String
                let title: String
                let tabIDs: [String]
                let terminalIDs: [String]
                let selectedTabID: String?
                let isFocused: Bool
                let window: NSWindow
                let preferredController: BaseTerminalController
            }

            struct Tab {
                let id: String
                let windowID: String
                let title: String
                let index: Int
                let isSelected: Bool
                let terminalIDs: [String]
                let focusedTerminalID: String?
                let controller: BaseTerminalController
                let window: NSWindow
            }

            struct Terminal {
                let id: String
                let uuid: UUID
                let tabID: String
                let windowID: String
                let title: String
                let workingDirectory: String?
                let tty: String?
                let isFocused: Bool
                let isQuickTerminal: Bool
                let surfaceView: Ghostty.SurfaceView
                let controller: BaseTerminalController
            }

            let windows: [Window]
            let tabs: [Tab]
            let terminals: [Terminal]

            private let windowsByID: [String: Window]
            private let tabsByID: [String: Tab]
            private let terminalsByID: [String: Terminal]
            private let terminalsByUUID: [UUID: Terminal]

            init(windows: [Window], tabs: [Tab], terminals: [Terminal]) {
                self.windows = windows
                self.tabs = tabs
                self.terminals = terminals
                self.windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
                self.tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
                self.terminalsByID = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, $0) })
                self.terminalsByUUID = Dictionary(uniqueKeysWithValues: terminals.map { ($0.uuid, $0) })
            }

            func window(id: String) -> Window? {
                windowsByID[id]
            }

            func tab(id: String) -> Tab? {
                tabsByID[id]
            }

            func terminal(id: String) -> Terminal? {
                terminalsByID[id]
            }

            func terminal(id: UUID) -> Terminal? {
                terminalsByUUID[id]
            }
        }

        @MainActor
        static func snapshot(app: NSApplication? = nil) -> Snapshot {
            let app = app ?? NSApplication.shared
            let orderedControllers = app.orderedWindows.compactMap {
                $0.windowController as? BaseTerminalController
            }

            var seenWindowIDs: Set<String> = []
            var windows: [Snapshot.Window] = []
            var tabs: [Snapshot.Tab] = []
            var terminals: [Snapshot.Terminal] = []

            for controller in orderedControllers {
                let windowID = windowID(for: controller)
                guard seenWindowIDs.insert(windowID).inserted else { continue }

                let tabControllers = tabControllers(for: controller)
                guard let preferredController = selectedTabController(for: controller) ?? tabControllers.first,
                      let window = preferredController.window else {
                    continue
                }

                let selectedTabID = selectedTabController(for: controller).map(tabID(for:))
                var windowTabIDs: [String] = []
                var windowTerminalIDs: [String] = []

                for (index, tabController) in tabControllers.enumerated() {
                    guard let tabWindow = tabController.window else { continue }

                    let tabIDValue = tabID(for: tabController)
                    let surfaceViews = tabController.surfaceTree.root?.leaves() ?? []
                    let focusedTerminalID = tabController.focusedSurface.flatMap { focusedSurface in
                        surfaceViews
                            .first(where: { $0 === focusedSurface })
                            .map(surfaceID(for:))
                    }

                    var tabTerminalIDs: [String] = []

                    for surfaceView in surfaceViews {
                        let terminalID = surfaceID(for: surfaceView)
                        tabTerminalIDs.append(terminalID)
                        windowTerminalIDs.append(terminalID)
                        terminals.append(.init(
                            id: terminalID,
                            uuid: surfaceView.id,
                            tabID: tabIDValue,
                            windowID: windowID,
                            title: surfaceView.title,
                            workingDirectory: surfaceView.pwd,
                            tty: tty(for: surfaceView),
                            isFocused: tabController.focusedSurface === surfaceView,
                            isQuickTerminal: tabController is QuickTerminalController,
                            surfaceView: surfaceView,
                            controller: tabController
                        ))
                    }

                    windowTabIDs.append(tabIDValue)
                    tabs.append(.init(
                        id: tabIDValue,
                        windowID: windowID,
                        title: tabWindow.title,
                        index: index + 1,
                        isSelected: selectedTabID == tabIDValue,
                        terminalIDs: tabTerminalIDs,
                        focusedTerminalID: focusedTerminalID,
                        controller: tabController,
                        window: tabWindow
                    ))
                }

                windows.append(.init(
                    id: windowID,
                    title: window.title,
                    tabIDs: windowTabIDs,
                    terminalIDs: windowTerminalIDs,
                    selectedTabID: selectedTabID,
                    isFocused: app.keyWindow === window || app.mainWindow === window,
                    window: window,
                    preferredController: preferredController
                ))
            }

            return .init(windows: windows, tabs: tabs, terminals: terminals)
        }

        static func surfaceID(for surfaceView: Ghostty.SurfaceView) -> String {
            surfaceView.id.uuidString
        }

        static func tabID(for controller: BaseTerminalController) -> String {
            "tab-\(ObjectIdentifier(controller).hexString)"
        }

        static func windowID(for controller: BaseTerminalController) -> String {
            guard let window = controller.window else {
                return "controller-\(ObjectIdentifier(controller).hexString)"
            }

            if let tabGroup = window.tabGroup {
                return windowID(for: tabGroup)
            }

            return windowID(for: window)
        }

        static func windowID(for window: NSWindow) -> String {
            "window-\(ObjectIdentifier(window).hexString)"
        }

        static func windowID(for tabGroup: NSWindowTabGroup) -> String {
            "tab-group-\(ObjectIdentifier(tabGroup).hexString)"
        }

        @MainActor
        static func controller(
            for surfaceView: Ghostty.SurfaceView,
            app: NSApplication? = nil
        ) -> BaseTerminalController? {
            let app = app ?? NSApplication.shared
            return app.windows
                .compactMap { $0.windowController as? BaseTerminalController }
                .first { controller in
                    controller.surfaceTree.contains(where: { $0 === surfaceView })
                }
        }

        static func tty(for surfaceView: Ghostty.SurfaceView) -> String? {
            guard let surface = surfaceView.surface else { return nil }

            let bufSize = 256
            var buf = [CChar](repeating: 0, count: bufSize)
            let len = ghostty_surface_pty_name(surface, &buf, UInt(bufSize))
            guard len > 0 else { return nil }
            buf[min(Int(len), bufSize - 1)] = 0
            return String(cString: buf)
        }

        private static func tabControllers(for controller: BaseTerminalController) -> [BaseTerminalController] {
            guard let window = controller.window else { return [controller] }

            if let tabGroup = window.tabGroup {
                let groupControllers = tabGroup.windows.compactMap {
                    $0.windowController as? BaseTerminalController
                }
                if !groupControllers.isEmpty {
                    return groupControllers
                }
            }

            return [controller]
        }

        private static func selectedTabController(for controller: BaseTerminalController) -> BaseTerminalController? {
            guard let window = controller.window else { return controller }

            if let tabGroup = window.tabGroup,
               let selectedController = tabGroup.selectedWindow?.windowController as? BaseTerminalController {
                return selectedController
            }

            return tabControllers(for: controller).first
        }
    }
}
#endif
