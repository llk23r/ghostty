import AppKit
import AppIntents
import GhosttyKit
import SwiftUI

struct TerminalEntity: AppEntity {
    let id: UUID

    @Property(title: "Surface ID")
    var surfaceID: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Working Directory")
    var workingDirectory: String?

    @Property(title: "TTY")
    var tty: String?

    @Property(title: "Tab ID")
    var tabID: String?

    @Property(title: "Window ID")
    var windowID: String?

    @Property(title: "Kind")
    var kind: Kind

    var screenshot: NSImage?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Terminal")
    }

    @MainActor
    var displayRepresentation: DisplayRepresentation {
        var rep = DisplayRepresentation(title: "\(title)")
        if let screenshot,
           let data = screenshot.tiffRepresentation {
            rep.image = .init(data: data)
        }

        return rep
    }

    /// Returns the view associated with this entity. This may no longer exist.
    @MainActor
    var surfaceView: Ghostty.SurfaceView? {
        Self.defaultQuery.all.first { $0.id == self.id }
    }

    @MainActor
    var surfaceModel: Ghostty.Surface? {
        surfaceView?.surfaceModel
    }

    static var defaultQuery = TerminalQuery()

    @MainActor
    init(_ view: Ghostty.SurfaceView) {
        let controller = NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .first { controller in
                controller.surfaceTree.contains(where: { $0 === view })
            }

        self.id = view.id
        self.surfaceID = view.id.uuidString
        self.title = view.title
        self.workingDirectory = view.pwd
        if let surface = view.surface {
            let bufSize = 256
            var buf = [CChar](repeating: 0, count: bufSize)
            let len = ghostty_surface_pty_name(surface, &buf, UInt(bufSize))
            if len > 0 {
                buf[min(Int(len), bufSize - 1)] = 0
                self.tty = String(cString: buf)
            } else {
                self.tty = nil
            }
        } else {
            self.tty = nil
        }

        if let controller {
            self.tabID = ScriptTab.stableID(controller: controller)
            self.windowID = ScriptWindow.stableID(primaryController: controller)
        } else {
            self.tabID = nil
            self.windowID = nil
        }

        if let nsImage = ImageRenderer(content: view.screenshot()).nsImage {
            self.screenshot = nsImage
        }

        // Determine the kind based on the window controller type
        if controller is QuickTerminalController {
            self.kind = .quick
        } else {
            self.kind = .normal
        }
    }
}

extension TerminalEntity {
    enum Kind: String, AppEnum {
        case normal
        case quick

        static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Kind")

        static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
            .normal: .init(title: "Normal"),
            .quick: .init(title: "Quick")
        ]
    }
}

struct TerminalQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    func entities(for identifiers: [TerminalEntity.ID]) async throws -> [TerminalEntity] {
        return all.filter {
            identifiers.contains($0.id)
        }.map {
            TerminalEntity($0)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TerminalEntity] {
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(string)
        }.map {
            TerminalEntity($0)
        }
    }

    @MainActor
    func allEntities() async throws -> [TerminalEntity] {
        return all.map { TerminalEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TerminalEntity] {
        return try await allEntities()
    }

    @MainActor
    var all: [Ghostty.SurfaceView] {
        // Find all of our terminal windows. This will include the quick terminal
        // but only if it was previously opened.
        let controllers = NSApp.windows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        // Get all our surfaces
        return controllers.flatMap {
            $0.surfaceTree.root?.leaves() ?? []
        }
    }
}
