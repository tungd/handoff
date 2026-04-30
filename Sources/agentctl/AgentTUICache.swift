import AgentCore
import Foundation

final class AgentTUIANSICache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [ANSIKey: String] = [:]
    private var maxSize = 256

    struct ANSIKey: Hashable {
        var text: String
        var colorValue: Int
        var isBold: Bool
        var isItalic: Bool
        var isUnderlined: Bool
        var isReversed: Bool
    }

    static let shared = AgentTUIANSICache()

    private init() {}

    func get(
        text: String,
        colorValue: Int,
        isBold: Bool,
        isItalic: Bool,
        isUnderlined: Bool,
        isReversed: Bool,
        compute: () -> String
    ) -> String {
        let key = ANSIKey(
            text: text,
            colorValue: colorValue,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isReversed: isReversed
        )

        return lock.withLock {
            if let cached = cache[key] {
                return cached
            }

            let result = compute()
            if cache.count >= maxSize {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = result
            return result
        }
    }

    func clear() {
        lock.withLock {
            cache.removeAll(keepingCapacity: true)
        }
    }
}

final class AgentTUIMarkdownCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [MarkdownKey: [[AgentTUIStyledTextSpan]]] = [:]
    private var maxSize = 64

    struct MarkdownKey: Hashable {
        var text: String
        var width: Int
    }

    static let shared = AgentTUIMarkdownCache()

    private init() {}

    func get(text: String, width: Int, compute: () -> [[AgentTUIStyledTextSpan]]) -> [[AgentTUIStyledTextSpan]] {
        let key = MarkdownKey(text: text, width: width)

        return lock.withLock {
            if let cached = cache[key] {
                return cached
            }

            let result = compute()
            if cache.count >= maxSize {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = result
            return result
        }
    }

    func clear() {
        lock.withLock {
            cache.removeAll(keepingCapacity: true)
        }
    }
}

struct AgentTUISuggestion: Equatable, Sendable {
    var text: String
    var display: String
    var kind: SuggestionKind

    enum SuggestionKind: Equatable, Sendable {
        case slashCommand
        case filePath
        case taskResume
    }
}

final class AgentTUISuggestionPicker: @unchecked Sendable {
    private let lock = NSLock()
    private var suggestions: [AgentTUISuggestion] = []
    private var selectedIndex = 0
    private var isVisible = false
    private var triggerOffset = 0
    private var triggerKind: SuggestionTriggerKind?

    enum SuggestionTriggerKind: Equatable, Sendable {
        case slashCommand
        case filePath
        case taskResume
    }

    static let shared = AgentTUISuggestionPicker()

    private init() {}

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                suggestions: suggestions,
                selectedIndex: selectedIndex,
                isVisible: isVisible,
                triggerOffset: triggerOffset
            )
        }
    }

    struct Snapshot: Equatable, Sendable {
        var suggestions: [AgentTUISuggestion]
        var selectedIndex: Int
        var isVisible: Bool
        var triggerOffset: Int
    }

    func showSlashCommands(prefix: String, offset: Int) {
        lock.withLock {
            let commands = slashCommandSuggestions.filter { $0.text.hasPrefix(prefix) }
            suggestions = commands
            selectedIndex = 0
            isVisible = !commands.isEmpty
            triggerOffset = offset
            triggerKind = .slashCommand
        }
    }

    func showFiles(prefix: String, offset: Int, repoRoot: String?) {
        lock.withLock {
            let files = fileSuggestions(repoRoot: repoRoot, prefix: prefix)
            suggestions = files
            selectedIndex = 0
            isVisible = !files.isEmpty
            triggerOffset = offset
            triggerKind = .filePath
        }
    }

    func showTasks(tasks: [TaskRecord], prefix: String, offset: Int) {
        lock.withLock {
            let taskSuggestions = tasks.compactMap { task -> AgentTUISuggestion? in
                guard task.slug.hasPrefix(prefix) || task.id.uuidString.hasPrefix(prefix) else { return nil }
                let stateIcon = task.state == .open ? "○" : task.state == .completed ? "●" : "◐"
                return AgentTUISuggestion(
                    text: task.slug,
                    display: "\(stateIcon) \(task.slug)  \(task.title)",
                    kind: .taskResume
                )
            }
            suggestions = taskSuggestions
            selectedIndex = 0
            isVisible = !taskSuggestions.isEmpty
            triggerOffset = offset
            triggerKind = .taskResume
        }
    }

    func hide() {
        lock.withLock {
            suggestions = []
            selectedIndex = 0
            isVisible = false
            triggerKind = nil
        }
    }

    func moveUp() -> Bool {
        lock.withLock {
            guard isVisible, suggestions.count > 1 else { return false }
            selectedIndex = max(0, selectedIndex - 1)
            return true
        }
    }

    func moveDown() -> Bool {
        lock.withLock {
            guard isVisible, suggestions.count > 1 else { return false }
            selectedIndex = min(suggestions.count - 1, selectedIndex + 1)
            return true
        }
    }

    func accept() -> AgentTUISuggestion? {
        lock.withLock {
            guard isVisible, suggestions.indices.contains(selectedIndex) else { return nil }
            return suggestions[selectedIndex]
        }
    }

    func updateFilter(prefix: String) {
        lock.withLock {
            guard let kind = triggerKind, isVisible else { return }
            switch kind {
            case .slashCommand:
                suggestions = slashCommandSuggestions.filter { $0.text.hasPrefix(prefix) }
            case .filePath:
                suggestions = fileSuggestions(repoRoot: nil, prefix: prefix)
            case .taskResume:
                // Task filter is handled externally via showTasks refresh
                break
            }
            selectedIndex = 0
            isVisible = !suggestions.isEmpty
        }
    }

    private let slashCommandSuggestions: [AgentTUISuggestion] = [
        AgentTUISuggestion(text: "help", display: "/help          Show available commands", kind: .slashCommand),
        AgentTUISuggestion(text: "info", display: "/info          Show current task details", kind: .slashCommand),
        AgentTUISuggestion(text: "tasks", display: "/tasks         List all tasks", kind: .slashCommand),
        AgentTUISuggestion(text: "new", display: "/new [title]   Create a new task", kind: .slashCommand),
        AgentTUISuggestion(text: "resume", display: "/resume <task> Resume a task", kind: .slashCommand),
        AgentTUISuggestion(text: "rename", display: "/rename <title> Rename current task", kind: .slashCommand),
        AgentTUISuggestion(text: "checkpoint", display: "/checkpoint    Create a checkpoint", kind: .slashCommand),
        AgentTUISuggestion(text: "checkpoints", display: "/checkpoints   List checkpoints", kind: .slashCommand),
        AgentTUISuggestion(text: "artifacts", display: "/artifacts     List artifacts", kind: .slashCommand),
        AgentTUISuggestion(text: "continue", display: "/continue      Export continuation bundle", kind: .slashCommand),
        AgentTUISuggestion(text: "release", display: "/release       Release task claim", kind: .slashCommand),
        AgentTUISuggestion(text: "export", display: "/export        Export transcript", kind: .slashCommand),
        AgentTUISuggestion(text: "events", display: "/events        Show events", kind: .slashCommand),
        AgentTUISuggestion(text: "raw", display: "/raw           Toggle raw event display", kind: .slashCommand),
        AgentTUISuggestion(text: "exit", display: "/exit          Exit session", kind: .slashCommand),
        AgentTUISuggestion(text: "quit", display: "/quit          Exit session", kind: .slashCommand)
    ]

    private func fileSuggestions(repoRoot: String?, prefix: String) -> [AgentTUISuggestion] {
        guard !prefix.isEmpty else { return [] }
        let lowerPrefix = prefix.lowercased()

        return cachedFileList(repoRoot: repoRoot)
            .filter { $0.lowercased().contains(lowerPrefix) }
            .prefix(12)
            .map { path in
                AgentTUISuggestion(text: path, display: path, kind: .filePath)
            }
    }

    private var cachedFiles: [String]?
    private var cachedFilesRepoRoot: String?

    private func cachedFileList(repoRoot: String?) -> [String] {
        lock.withLock {
            if let cached = cachedFiles, cachedFilesRepoRoot == repoRoot {
                return cached
            }

            guard let root = repoRoot else { return [] }

            let files = collectFiles(repoRoot: root)
            cachedFiles = files
            cachedFilesRepoRoot = repoRoot
            return files
        }
    }

    private func collectFiles(repoRoot: String) -> [String] {
        let rootURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
        var files: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let item = enumerator?.nextObject() as? URL {
            guard item.hasDirectoryPath == false else { continue }
            let relative = item.path.replacingOccurrences(of: repoRoot + "/", with: "")
            if !relative.isEmpty {
                files.append(relative)
            }
        }

        return files.sorted()
    }

    func invalidateFileCache() {
        lock.withLock {
            cachedFiles = nil
            cachedFilesRepoRoot = nil
        }
    }
}