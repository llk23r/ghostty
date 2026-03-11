import AppKit
import GhosttyKit

/// Handler for the `read turns` AppleScript command defined in `Ghostty.sdef`.
///
/// Reads N command turns (prompt + input + output) from a terminal.
/// Requires shell integration for semantic prompt markers.
@MainActor
@objc(GhosttyScriptReadTurnsCommand)
final class ScriptReadTurnsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        let n: UInt32 = {
            if let param = directParameter as? Int, param > 0 {
                return UInt32(param)
            }
            return 1
        }()

        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return nil
        }

        guard let surface = terminal.surfaceView?.surface else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        let first: Bool = {
            if let code = evaluatedArguments?["position"] as? UInt32 {
                return code == "GTpf".fourCharCode
            }
            return false
        }()

        var text = ghostty_text_s()
        let ok = first
            ? ghostty_surface_read_first_turns(surface, n, &text)
            : ghostty_surface_read_last_turns(surface, n, &text)
        guard ok else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "No prompt data found. Is shell integration active?"
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }

        return String(cString: ptr)
    }
}
