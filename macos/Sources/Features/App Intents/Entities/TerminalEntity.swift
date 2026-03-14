import AppKit
import AppIntents
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
        Ghostty.TerminalHierarchy.snapshot().terminal(id: id)?.surfaceView
    }

    @MainActor
    var surfaceModel: Ghostty.Surface? {
        surfaceView?.surfaceModel
    }

    static var defaultQuery = TerminalQuery()

    private init(
        id: UUID,
        surfaceID: String,
        title: String,
        workingDirectory: String?,
        tty: String?,
        tabID: String?,
        windowID: String?,
        kind: Kind,
        screenshot: NSImage?
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.title = title
        self.workingDirectory = workingDirectory
        self.tty = tty
        self.tabID = tabID
        self.windowID = windowID
        self.kind = kind
        self.screenshot = screenshot
    }

    @MainActor
    init(_ terminal: Ghostty.TerminalHierarchy.Snapshot.Terminal) {
        self.init(
            id: terminal.uuid,
            surfaceID: terminal.id,
            title: terminal.title,
            workingDirectory: terminal.workingDirectory,
            tty: terminal.tty,
            tabID: terminal.tabID,
            windowID: terminal.windowID,
            kind: terminal.isQuickTerminal ? .quick : .normal,
            screenshot: ImageRenderer(content: terminal.surfaceView.screenshot()).nsImage
        )
    }

    @MainActor
    init(_ view: Ghostty.SurfaceView) {
        if let terminal = Ghostty.TerminalHierarchy.snapshot().terminal(id: view.id) {
            self = .init(terminal)
            return
        }

        let controller = Ghostty.TerminalHierarchy.controller(for: view)
        self.init(
            id: view.id,
            surfaceID: Ghostty.TerminalHierarchy.surfaceID(for: view),
            title: view.title,
            workingDirectory: view.pwd,
            tty: Ghostty.TerminalHierarchy.tty(for: view),
            tabID: controller.map(Ghostty.TerminalHierarchy.tabID(for:)),
            windowID: controller.map(Ghostty.TerminalHierarchy.windowID(for:)),
            kind: controller is QuickTerminalController ? .quick : .normal,
            screenshot: ImageRenderer(content: view.screenshot()).nsImage
        )
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
            identifiers.contains($0.uuid)
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
    var all: [Ghostty.TerminalHierarchy.Snapshot.Terminal] {
        Ghostty.TerminalHierarchy.snapshot().terminals
    }
}
