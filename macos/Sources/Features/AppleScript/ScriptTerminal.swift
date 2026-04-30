import AppKit

/// AppleScript-facing wrapper around a live Ghostty terminal surface.
///
/// This class is intentionally ObjC-visible because Cocoa scripting resolves
/// AppleScript objects through Objective-C runtime names/selectors, not Swift
/// protocol conformance.
///
/// Mapping from `Ghostty.sdef`:
/// - `class terminal` -> this class (`@objc(GhosttyAppleScriptTerminal)`).
/// - `property id` -> `@objc(id)` getter below.
/// - `property title` -> `@objc(title)` getter below.
/// - `property working directory` -> `@objc(workingDirectory)` getter below.
/// - `property pid` -> `@objc(pid)` getter below.
/// - `property tty` -> `@objc(tty)` getter below.
///
/// We keep a weak fallback reference to the underlying `SurfaceView`, while
/// resolving current state through the shared terminal hierarchy snapshot.
@MainActor
@objc(GhosttyScriptTerminal)
final class ScriptTerminal: NSObject {
    private let terminalID: String
    private weak var fallbackSurfaceView: Ghostty.SurfaceView?

    init(stableID: String, surfaceView: Ghostty.SurfaceView? = nil) {
        self.terminalID = stableID
        self.fallbackSurfaceView = surfaceView
    }

    convenience init(_ stableID: String) {
        self.init(stableID: stableID)
    }

    convenience init(surfaceView: Ghostty.SurfaceView) {
        self.init(
            stableID: Ghostty.TerminalHierarchy.surfaceID(for: surfaceView),
            surfaceView: surfaceView
        )
    }

    /// Package-visible so other AppleScript command handlers can access the
    /// live surface without exposing it to ObjC/AppleScript.
    var surfaceView: Ghostty.SurfaceView? {
        hierarchyTerminal?.surfaceView ?? fallbackSurfaceView
    }

    private var hierarchyTerminal: Ghostty.TerminalHierarchy.Snapshot.Terminal? {
        Ghostty.TerminalHierarchy.snapshot().terminal(id: terminalID)
    }

    private var controller: BaseTerminalController? {
        if let hierarchyTerminal {
            return hierarchyTerminal.controller
        }

        guard let surfaceView else { return nil }
        return Ghostty.TerminalHierarchy.controller(for: surfaceView)
    }

    /// Exposed as the AppleScript `id` property.
    ///
    /// This is a stable UUID string for the life of a surface and is also used
    /// by `NSUniqueIDSpecifier` to re-identify a terminal object in scripts.
    @objc(id)
    var stableID: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return terminalID
    }

    /// Exposed as the AppleScript `title` property.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return hierarchyTerminal?.title ?? surfaceView?.title ?? ""
    }

    /// Exposed as the AppleScript `working directory` property.
    ///
    /// The `sdef` uses a spaced name, but Cocoa scripting maps that to the
    /// camel-cased selector name `workingDirectory`.
    @objc(workingDirectory)
    var workingDirectory: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return hierarchyTerminal?.workingDirectory ?? surfaceView?.pwd ?? ""
    }

    /// Exposed as the AppleScript `tab` property.
    @objc(scriptTab)
    var scriptTab: ScriptTab? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        if let hierarchyTerminal {
            let scriptWindow = ScriptWindow(
                stableID: hierarchyTerminal.windowID,
                primaryController: hierarchyTerminal.controller
            )
            return ScriptTab(
                window: scriptWindow,
                stableID: hierarchyTerminal.tabID,
                controller: hierarchyTerminal.controller
            )
        }

        guard let controller else { return nil }
        guard let scriptWindow else { return nil }
        return ScriptTab(window: scriptWindow, controller: controller)
    }

    /// Exposed as the AppleScript `window` property.
    @objc(scriptWindow)
    var scriptWindow: ScriptWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        if let hierarchyTerminal {
            return ScriptWindow(
                stableID: hierarchyTerminal.windowID,
                primaryController: hierarchyTerminal.controller
            )
        }

        guard let controller else { return nil }
        return ScriptWindow(primaryController: controller)
    }

    /// Exposed as the AppleScript `tty` property.
    ///
    /// Returns the slave PTY device path (e.g. "/dev/ttys004") for this
    /// terminal surface.
    @objc(tty)
    var tty: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return hierarchyTerminal?.tty ?? surfaceView.flatMap(Ghostty.TerminalHierarchy.tty(for:)) ?? ""
    }

    /// Exposed as the AppleScript `pid` property.
    @objc(pid)
    var pid: Int {
        guard NSApp.isAppleScriptEnabled else { return 0 }
        return hierarchyTerminal?.pid ?? surfaceView?.surfaceModel?.foregroundPID ?? 0
    }

    /// Used by command handling (`perform action ... on <terminal>`).
    func perform(action: String) -> Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        guard let surfaceModel = surfaceView?.surfaceModel else { return false }
        return surfaceModel.perform(action: action)
    }

    /// Handler for `split <terminal> direction <dir>`.
    @objc(handleSplitCommand:)
    func handleSplit(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let directionCode = command.evaluatedArguments?["direction"] as? UInt32 else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing or unknown split direction."
            return nil
        }

        guard let direction = ScriptSplitDirection(code: directionCode)?.splitDirection else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing or unknown split direction."
            return nil
        }

        let baseConfig: Ghostty.SurfaceConfiguration?
        if let scriptRecord = command.evaluatedArguments?["configuration"] as? NSDictionary {
            do {
                baseConfig = try Ghostty.SurfaceConfiguration(scriptRecord: scriptRecord)
            } catch {
                command.scriptErrorNumber = errAECoercionFail
                command.scriptErrorString = error.localizedDescription
                return nil
            }
        } else {
            baseConfig = nil
        }

        guard let controller else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a splittable window."
            return nil
        }

        guard let newView = controller.newSplit(
            at: surfaceView,
            direction: direction,
            baseConfig: baseConfig
        ) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Failed to create split."
            return nil
        }

        return ScriptTerminal(surfaceView: newView)
    }

    /// Handler for `focus <terminal>`.
    @objc(handleFocusCommand:)
    func handleFocus(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a window."
            return nil
        }

        controller.focusSurface(surfaceView)
        return nil
    }

    /// Handler for `close <terminal>`.
    @objc(handleCloseCommand:)
    func handleClose(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a window."
            return nil
        }

        controller.closeSurface(surfaceView, withConfirmation: false)
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    ///
    /// Without an object specifier, returned terminal objects can't be reliably
    /// referenced in follow-up script statements because AppleScript cannot
    /// express where the object came from (`application.terminals[id]`).
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "terminals",
            uniqueID: stableID
        )
    }
}

/// Converts four-character codes from the `split direction` enumeration in `Ghostty.sdef`
/// to `SplitTree.NewDirection` values.
enum ScriptSplitDirection {
    case right
    case left
    case down
    case up

    init?(code: UInt32) {
        switch code {
        case "GSrt".fourCharCode: self = .right
        case "GSlf".fourCharCode: self = .left
        case "GSdn".fourCharCode: self = .down
        case "GSup".fourCharCode: self = .up
        default: return nil
        }
    }

    var splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection {
        switch self {
        case .right: .right
        case .left: .left
        case .down: .down
        case .up: .up
        }
    }
}
