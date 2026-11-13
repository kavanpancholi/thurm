import AppKit

struct RecentPath: Codable, Equatable {
    let host: HostId
    let cwd: String
    let path: String
    let isDirectory: Bool
}

final class PathHistory {
    private let defaults: UserDefaults
    private let key = "insertPathHistory"
    private(set) var entries: [RecentPath]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RecentPath].self, from: $0) } ?? []
    }

    func paths(host: HostId, cwd: String, query: String) -> [RecentPath] {
        entries.filter { $0.host == host && $0.cwd == cwd
            && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)) }
    }

    func record(_ path: RecentPath) {
        entries.removeAll { $0.host == path.host && $0.cwd == path.cwd && $0.path == path.path }
        entries.insert(path, at: 0)
        entries = Array(entries.prefix(50))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}

/// Search on the pane's host. Keep results tied to the pane and folder that supplied them.
final class InsertPathPicker {
    static let shared = InsertPathPicker()
    private let history: PathHistory
    private let palette: CommandPalette
    private let requestPaths: (PaneKey, String, @escaping (Any?) -> Void) -> Void

    init(history: PathHistory = PathHistory(), palette: CommandPalette = .shared,
         requestPaths: @escaping (PaneKey, String, @escaping (Any?) -> Void) -> Void = { pane, query, reply in
             Core.shared.requestAsync(object: ["SearchPaths": ["pane": pane.number, "query": query]],
                                      host: pane.host, timeout: 3, completion: reply)
         }) {
        self.history = history
        self.palette = palette
        self.requestPaths = requestPaths
    }
    private weak var terminal: TerminalView?
    private var generation = 0
    private var refresh: DispatchWorkItem?
    private var active = false

    /// Escape a complete path for insertion as one shell word. Never send control characters.
    static func shellText(_ path: String) -> String? {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        // Prevent option parsing, tilde expansion, and assignment syntax for relative names.
        let path = path.hasPrefix("/") || path.hasPrefix("./") || path.hasPrefix("../") ? path : "./" + path
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        return path.unicodeScalars.map { safe.contains($0) ? String($0) : "\\" + String($0) }.joined() + " "
    }

    func show(for terminal: TerminalView) {
        guard !terminal.isOffline, let window = terminal.window else { return }
        self.terminal = terminal
        active = true
        generation += 1
        palette.show(items: [], over: window,
            placeholder: terminal.pane.isRemote ? "Insert Path on \(terminal.pane.host)…" : "Insert Path: search files and folders…",
            footer: "Searching…", onQuery: { [weak self] query in self?.search(query) },
            onCancel: { [weak self] in self?.cancel() })
        // Opening another palette can cancel an earlier Insert Path session.
        active = true
        search("")
    }

    private func cancel() {
        active = false
        generation += 1
        refresh?.cancel()
    }

    private func search(_ query: String) {
        refresh?.cancel()
        generation += 1
        let request = generation
        palette.updateSearch(items: [], hint: "Searching…")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, let terminal = self.terminal, !terminal.isOffline else { return }
            let pane = terminal.pane
            self.requestPaths(pane, query) { [weak self, weak terminal] response in
                guard let self, self.active, self.generation == request,
                      let terminal, terminal === self.terminal, self.palette.isVisible else { return }
                guard let value = JSON.variant(response), value.name == "PathMatches",
                      let payload = value.payload as? [String: Any] else {
                    let error = (response as? [String: Any])?["error"] as? String
                    self.palette.updateSearch(items: [], hint: error ?? "Cannot search this terminal. Check its connection.")
                    return
                }
                guard let cwd = jsonString(payload["cwd"]) else {
                    self.palette.updateSearch(items: [], hint: "Update Thurm on this host to use Insert Path.")
                    return
                }
                let recent = self.history.paths(host: pane.host, cwd: cwd, query: query)
                var paths = recent
                for item in payload["items"] as? [[String: Any]] ?? [] {
                    guard let path = jsonString(item["text"]), Self.shellText(path) != nil,
                          !paths.contains(where: { $0.path == path }) else { continue }
                    paths.append(RecentPath(host: pane.host, cwd: cwd, path: path,
                                            isDirectory: jsonString(item["kind"]) == "Directory"))
                }
                let items = paths.filter { Self.shellText($0.path) != nil }.map { path in
                    CommandPalette.Item(title: path.path,
                        detail: recent.contains(path) ? "Recent" : path.isDirectory ? "Folder" : "File",
                        navigate: path.isDirectory ? { [weak self] in
                            guard let self, self.active else { return }
                            let query = path.path.hasPrefix("/") ? path.path : "./" + path.path
                            self.palette.setSearchQuery(query)
                        } : nil) { [weak self, weak terminal] in
                            guard let self, let terminal else { return }
                            self.cancel()
                            guard terminal.insertPickedPath(path.path, cwd: cwd) else { return }
                            self.history.record(path)
                        }
                }
                let place = pane.isRemote ? "\(pane.host):\(cwd)" : cwd
                let status = items.isEmpty ? "No matching paths" : "Return: insert · Tab: open folder"
                let limited = jsonBool(payload["truncated"]) == true ? " · More paths: narrow the search" : ""
                self.palette.updateSearch(items: items, hint: "\(status)\(limited) · \(place)")
            }
        }
        refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }
}
