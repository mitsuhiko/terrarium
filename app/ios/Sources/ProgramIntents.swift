import AppIntents
import Foundation

// Running a program from outside the app (D38): the "Run Python Program"
// action for the Shortcuts app (which is also how a program gets an icon on
// the Home Screen) and terrarium://run?path=<path> links. Both end in
// `LaunchRouter`, which hands the request to the app once it is ready.

/// What the app is asked to do from outside.
enum LaunchAction: Equatable, Sendable {
    case run(String) // app path, as the file browser has it ("Examples/Todo App.py")
    case open(String)

    static let scheme = "terrarium"

    /// terrarium://run?path=Examples/Todo%20App.py (or open?path=…).
    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else { return nil }
        switch url.host() {
        case "run": self = .run(path)
        case "open": self = .open(path)
        default: return nil
        }
    }

    var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .run(let path): c.host = "run"; c.queryItems = [URLQueryItem(name: "path", value: path)]
        case .open(let path): c.host = "open"; c.queryItems = [URLQueryItem(name: "path", value: path)]
        }
        return c.url!
    }
}

/// Requests wait here until the app model takes them (a cold launch from a
/// Home Screen shortcut arrives before the engine page is ready).
@MainActor
enum LaunchRouter {
    private static var pending: [LaunchAction] = []
    private static var handler: ((LaunchAction) -> Void)?

    static func send(_ action: LaunchAction) {
        if let handler { handler(action) } else { pending.append(action) }
    }

    /// The app model is ready: it gets what waited and what comes later.
    static func attach(_ handle: @escaping (LaunchAction) -> Void) {
        handler = handle
        let waiting = pending
        pending = []
        for action in waiting { handle(action) }
    }
}

/// A Python file in Documents or a linked folder, for the Shortcuts app.
struct ProgramEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Python Program"
    static let defaultQuery = ProgramQuery()

    let id: String // app path

    var name: String { (id as NSString).lastPathComponent.replacingOccurrences(of: ".py", with: "") }
    var folder: String {
        let dir = (id as NSString).deletingLastPathComponent
        return dir.isEmpty ? "Files" : dir.replacingOccurrences(of: "@", with: "")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(folder)", image: .init(systemName: "chevron.left.forwardslash.chevron.right"))
    }
}

struct ProgramQuery: EntityStringQuery {
    private static let skipped: Set<String> = ["__pycache__", "node_modules"]

    /// Every .py file in Documents (not linked folders: listing them may download files).
    static func programs() -> [ProgramEntity] {
        let store = FileStore(locations: Locations())
        guard let walker = FileManager.default.enumerator(at: store.root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [ProgramEntity] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "py" else { continue }
            let path = url.standardizedFileURL.path.dropFirst(store.root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            out.append(ProgramEntity(id: path))
            if out.count >= 500 { break }
        }
        return out.sorted { ($0.folder, $0.name) < ($1.folder, $1.name) }
    }

    func entities(for identifiers: [String]) async throws -> [ProgramEntity] {
        let store = FileStore(locations: Locations())
        return identifiers.filter { (try? store.exists($0)) == true }.map(ProgramEntity.init(id:))
    }

    func entities(matching string: String) async throws -> [ProgramEntity] {
        Self.programs().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ProgramEntity] {
        Self.programs()
    }
}

struct RunProgramIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Python Program"
    static let description = IntentDescription(
        "Opens Terrarium and runs a program, like its Run button. A ui app opens full screen. Add this shortcut to the Home Screen to start the program with one tap."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Program")
    var program: ProgramEntity

    init() {}

    init(program: ProgramEntity) {
        self.program = program
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$program)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.send(.run(program.id))
        return .result()
    }
}

struct TerrariumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunProgramIntent(),
            phrases: ["Run \(\.$program) in \(.applicationName)", "Start \(\.$program) in \(.applicationName)"],
            shortTitle: "Run Program",
            systemImageName: "play.fill"
        )
    }
}
