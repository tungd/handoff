import AgentCore
import Darwin
import Foundation
import TUIkit

private struct AgentTUIRuntime: @unchecked Sendable {
    var task: TaskRecord
    var storeOptions: StoreOptions
    var repoURL: URL
    var snapshot: RepositorySnapshot
    var store: any AgentTaskStore
    var model: AgentTUIModel
    var fullAuto: Bool
    var sandbox: String?
}

@MainActor
private enum AgentTUIRuntimeBox {
    static var current: AgentTUIRuntime?
}

func runTUIkitInteractiveLoop(
    task: TaskRecord,
    storeOptions: StoreOptions,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    store: any AgentTaskStore,
    fullAuto: Bool,
    sandbox: String?
) async throws {
    let initialEntries = try await tuiEntries(for: task.id, store: store)
    let runtime = AgentTUIRuntime(
        task: task,
        storeOptions: storeOptions,
        repoURL: repoURL,
        snapshot: snapshot,
        store: store,
        model: AgentTUIModel(task: task, entries: initialEntries.isEmpty ? [
            TUITranscriptEntry(role: .system, text: "Ready.")
        ] : initialEntries),
        fullAuto: fullAuto,
        sandbox: sandbox
    )

    await MainActor.run {
        AgentTUIRuntimeBox.current = runtime
        AgentTUIApp.main()
        AgentTUIRuntimeBox.current = nil
    }
}

struct AgentTUIApp: App {
    var body: some Scene {
        WindowGroup {
            AgentTUIView()
        }
    }
}

private enum TUITranscriptRole: String, Sendable {
    case user
    case codex
    case tool
    case system
    case error
}

private struct TUITranscriptEntry: Identifiable, Sendable {
    var id = UUID()
    var role: TUITranscriptRole
    var text: String
}

private struct TUITranscriptLine: Identifiable, Sendable {
    var id: Int
    var role: TUITranscriptRole
    var text: String
    var isLabel: Bool
}

private struct AgentTUISnapshot: Sendable {
    var task: TaskRecord
    var entries: [TUITranscriptEntry]
    var status: String
    var scrollOffset: Int
    var showRawEvents: Bool
    var isRunning: Bool
    var revision: Int
}

private final class AgentTUIModel: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AgentTUISnapshot
    private var cacheClearedRevision = 0

    init(task: TaskRecord, entries: [TUITranscriptEntry]) {
        state = AgentTUISnapshot(
            task: task,
            entries: entries,
            status: "ready",
            scrollOffset: 0,
            showRawEvents: false,
            isRunning: false,
            revision: 0
        )
    }

    func snapshot() -> AgentTUISnapshot {
        lock.withLock { state }
    }

    func clearRenderCacheIfNeeded(for revision: Int) {
        let shouldClear = lock.withLock { () -> Bool in
            guard revision > cacheClearedRevision else {
                return false
            }
            cacheClearedRevision = revision
            return true
        }
        if shouldClear {
            RenderCache.shared.clearAll()
        }
    }

    func append(_ role: TUITranscriptRole, _ text: String) {
        update { state in
            append(role, text, to: &state)
        }
    }

    func startTurn(prompt: String) -> TaskRecord? {
        var task: TaskRecord?
        update { state in
            guard !state.isRunning else {
                append(.error, "A Codex turn is already running.", to: &state)
                return
            }
            append(.user, prompt, to: &state)
            state.isRunning = true
            state.status = "running Codex turn..."
            task = state.task
        }
        return task
    }

    func finishTurn() {
        update { state in
            state.status = "ready"
            state.isRunning = false
        }
    }

    func failTurn(_ error: Error) {
        update { state in
            state.status = "turn failed"
            state.isRunning = false
            append(.error, String(describing: error), to: &state)
        }
    }

    func setStatus(_ status: String) {
        update { state in
            state.status = status
        }
    }

    func commandFailed(_ error: Error) {
        update { state in
            state.status = "command failed"
            append(.error, String(describing: error), to: &state)
        }
    }

    func toggleRawEvents() -> Bool {
        var enabled = false
        update { state in
            state.showRawEvents.toggle()
            enabled = state.showRawEvents
            append(.system, enabled ? "Raw event rendering enabled." : "Raw event rendering disabled.", to: &state)
        }
        return enabled
    }

    func setTask(_ task: TaskRecord, entries: [TUITranscriptEntry], message: String) {
        update { state in
            state.task = task
            state.entries = entries
            state.scrollOffset = 0
            append(.system, message, to: &state)
            state.status = "ready"
        }
    }

    func adjustScroll(_ delta: Int) {
        update { state in
            state.scrollOffset = max(0, state.scrollOffset + delta)
        }
    }

    func render(_ update: AgentSessionUpdate) {
        self.update { state in
            switch update {
            case let .event(event):
                switch event.kind {
                case .assistantDone:
                    if let text = event.payload["text"]?.stringValue {
                        append(.codex, text, to: &state)
                    }
                case .toolStarted:
                    append(.tool, "start  \(compactPayload(event.payload))", to: &state)
                case .toolFinished:
                    append(.tool, "done   \(compactPayload(event.payload))", to: &state)
                case .userMessage:
                    break
                case .backendSessionUpdated, .backendEvent:
                    if state.showRawEvents {
                        append(.system, "\(event.kind.rawValue) \(compactPayload(event.payload))", to: &state)
                    }
                default:
                    if state.showRawEvents {
                        append(.system, "\(event.kind.rawValue) \(compactPayload(event.payload))", to: &state)
                    }
                }
            case let .session(session):
                state.status = "session \(session.state.rawValue)"
            }
        }
    }

    private func update(_ body: (inout AgentTUISnapshot) -> Void) {
        lock.withLock {
            body(&state)
            state.revision += 1
        }
        AppState.shared.setNeedsRender()
        // TUIkit's runner owns a private AppState; SIGWINCH is its process-wide render wake-up.
        Darwin.raise(SIGWINCH)
    }

    private func append(_ role: TUITranscriptRole, _ text: String, to state: inout AgentTUISnapshot) {
        state.entries.append(TUITranscriptEntry(role: role, text: text))
        state.scrollOffset = 0
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private struct TerminalSize {
    var rows: Int
    var columns: Int
}

private struct AgentTUIView: View {
    private let model: AgentTUIModel
    @State private var input = ""

    init() {
        guard let runtime = AgentTUIRuntimeBox.current else {
            fatalError("AgentTUIView launched without runtime")
        }
        model = runtime.model
    }

    var body: some View {
        let snapshot = model.snapshot()
        let _ = model.clearRenderCacheIfNeeded(for: snapshot.revision)
        let size = terminalSize()
        let transcriptHeight = max(3, size.rows - 7)
        let lines = transcriptLines(snapshot.entries, width: max(40, size.columns - 2))
        let visibleLines = visibleLines(lines, height: transcriptHeight, scrollOffset: snapshot.scrollOffset)

        VStack(alignment: .leading, spacing: 0) {
            header(snapshot)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ViewArray(visibleLines.map(transcriptLine))
            }
            Spacer(minLength: 0)
            Divider()
            statusLine(snapshot, totalLines: lines.count, visibleHeight: transcriptHeight)
            composer(snapshot)
        }
        .padding(.horizontal, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onKeyPress { event in
            handleKey(event, pageSize: transcriptHeight)
        }
        .agentStatusBarConfiguration()
        .statusBarItems {
            StatusBarItem(shortcut: "Esc", label: "quit", key: .escape) {
                Darwin.raise(SIGINT)
            }
            StatusBarItem(shortcut: "PgUp/PgDn", label: "scroll")
            StatusBarItem(shortcut: "^U/^D", label: "scroll")
            StatusBarItem(shortcut: "/help", label: "commands")
        }
    }

    private func header(_ snapshot: AgentTUISnapshot) -> some View {
        HStack(spacing: 1) {
            Text("agentctl").foregroundStyle(.palette.accent).bold()
            Text(snapshot.task.slug).foregroundStyle(.palette.foregroundSecondary)
            Spacer()
            Text(snapshot.task.backendPreference.rawValue).foregroundStyle(.palette.success)
            Text(storeName).foregroundStyle(.palette.foregroundSecondary)
        }
    }

    private func statusLine(_ snapshot: AgentTUISnapshot, totalLines: Int, visibleHeight: Int) -> some View {
        HStack(spacing: 1) {
            Text(snapshot.status).foregroundStyle(statusColor(snapshot))
            if snapshot.showRawEvents {
                Text("raw").foregroundStyle(.palette.warning)
            }
            if snapshot.scrollOffset > 0 {
                Text("scroll \(snapshot.scrollOffset)").foregroundStyle(.palette.foregroundSecondary)
            }
            Spacer()
            Text("\(min(totalLines, visibleHeight))/\(totalLines)").dim()
        }
    }

    private func composer(_ snapshot: AgentTUISnapshot) -> some View {
        HStack(spacing: 1) {
            Text(">").foregroundStyle(.palette.accent).bold()
            TextField("message", text: $input, prompt: Text(snapshot.isRunning ? "turn running..." : "message or /command"))
                .focusID("composer")
                .onSubmit {
                    submitInput()
                }
        }
    }

    private func transcriptLine(_ line: TUITranscriptLine) -> AnyView {
        switch line.role {
        case .user:
            AnyView(Text(line.text).foregroundStyle(.palette.accent).bold())
        case .codex:
            AnyView(Text(line.text).foregroundStyle(.palette.success))
        case .tool:
            AnyView(Text(line.text).foregroundStyle(.palette.warning))
        case .error:
            AnyView(Text(line.text).foregroundStyle(.palette.error).bold())
        case .system:
            if line.isLabel {
                AnyView(Text(line.text).foregroundStyle(.palette.foregroundSecondary).bold())
            } else {
                AnyView(Text(line.text).dim())
            }
        }
    }

    private func statusColor(_ snapshot: AgentTUISnapshot) -> Color {
        if snapshot.status.hasPrefix("turn failed") {
            return .palette.error
        }
        if snapshot.isRunning {
            return .palette.warning
        }
        return .palette.foregroundSecondary
    }

    private var storeName: String {
        guard let runtime = AgentTUIRuntimeBox.current else {
            return "-"
        }
        return shortStoreName(storeDescription(options: runtime.storeOptions, repoURL: runtime.repoURL, snapshot: runtime.snapshot))
    }

    private func submitInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        guard !text.isEmpty else {
            return
        }

        if let command = SlashCommand(text) {
            handle(command)
            return
        }

        guard let currentTask = model.startTurn(prompt: text) else {
            return
        }

        guard let runtime = AgentTUIRuntimeBox.current else {
            model.failTurn(RuntimeError("TUI runtime is not available."))
            return
        }

        let model = model
        _Concurrency.Task.detached {
            do {
                _ = try await runCodexTurn(
                    task: currentTask,
                    prompt: text,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    store: runtime.store,
                    fullAuto: runtime.fullAuto,
                    sandbox: runtime.sandbox,
                    showStatus: false
                ) { update in
                    model.render(update)
                }
                model.finishTurn()
            } catch {
                model.failTurn(error)
            }
        }
    }

    private func handle(_ command: SlashCommand) {
        guard let runtime = AgentTUIRuntimeBox.current else {
            model.append(.error, "TUI runtime is not available.")
            return
        }

        switch command.name {
        case "exit", "quit":
            Darwin.raise(SIGINT)
        case "help":
            model.append(.system, "/help /info /tasks /new [title] /resume <task> /events /raw /exit")
        case "raw":
            _ = model.toggleRawEvents()
        case "info", "task", "repo":
            let task = model.snapshot().task
            runCommand(status: "loading task info...") {
                let summary = try await runtime.store.summary(for: task)
                model.append(.system, tuiInfo(task: task, summary: summary, runtime: runtime))
                model.setStatus("ready")
            }
        case "tasks":
            runCommand(status: "loading tasks...") {
                let tasks = try await runtime.store.listTasks()
                model.append(.system, tuiTasks(tasks))
                model.setStatus("ready")
            }
        case "events":
            let task = model.snapshot().task
            runCommand(status: "loading events...") {
                let events = try await runtime.store.events(for: task.id)
                model.append(.system, tuiEvents(events))
                model.setStatus("ready")
            }
        case "new":
            runCommand(status: "creating task...") {
                let newTask = try await resolveInteractiveTask(
                    identifier: nil,
                    title: command.argument?.isEmpty == false ? command.argument : nil,
                    snapshot: runtime.snapshot,
                    repoURL: runtime.repoURL,
                    store: runtime.store
                )
                model.setTask(newTask, entries: [], message: "Created task \(newTask.slug).")
            }
        case "resume":
            guard let identifier = command.argument, !identifier.isEmpty else {
                model.append(.error, "usage: /resume <task>")
                return
            }
            runCommand(status: "resuming task...") {
                let resumedTask = try await runtime.store.findTask(identifier)
                let loadedEntries = try await tuiEntries(for: resumedTask.id, store: runtime.store)
                model.setTask(resumedTask, entries: loadedEntries, message: "Resumed task \(resumedTask.slug).")
            }
        default:
            model.append(.error, "unknown command: /\(command.name)")
        }
    }

    private func runCommand(status newStatus: String, operation: @escaping @Sendable () async throws -> Void) {
        model.setStatus(newStatus)
        let model = model
        _Concurrency.Task.detached {
            do {
                try await operation()
            } catch {
                model.commandFailed(error)
            }
        }
    }

    private func handleKey(_ event: KeyEvent, pageSize: Int) -> Bool {
        switch event.key {
        case .pageUp:
            model.adjustScroll(pageSize)
            return true
        case .pageDown:
            model.adjustScroll(-pageSize)
            return true
        case .up where event.ctrl:
            model.adjustScroll(1)
            return true
        case .down where event.ctrl:
            model.adjustScroll(-1)
            return true
        case .character("u") where event.ctrl:
            model.adjustScroll(pageSize)
            return true
        case .character("d") where event.ctrl:
            model.adjustScroll(-pageSize)
            return true
        default:
            return false
        }
    }

    private func visibleLines(_ lines: [TUITranscriptLine], height: Int, scrollOffset: Int) -> [TUITranscriptLine] {
        guard lines.count > height else {
            return lines
        }
        let maxOffset = max(0, lines.count - height)
        let offset = min(scrollOffset, maxOffset)
        let start = max(0, lines.count - height - offset)
        return Array(lines.dropFirst(start).prefix(height))
    }
}

private struct AgentStatusBarConfiguration<Content: View>: View, Renderable {
    let content: Content

    var body: Never {
        fatalError("AgentStatusBarConfiguration renders via Renderable")
    }

    func renderToBuffer(context: RenderContext) -> FrameBuffer {
        context.environment.statusBar.showSystemItems = false
        return TUIkit.renderToBuffer(content, context: context)
    }
}

private extension View {
    func agentStatusBarConfiguration() -> some View {
        AgentStatusBarConfiguration(content: self)
    }
}

private func tuiEntries(for taskID: UUID, store: any AgentTaskStore) async throws -> [TUITranscriptEntry] {
    try await store.events(for: taskID).compactMap { event in
        switch event.kind {
        case .userMessage:
            return event.payload["text"]?.stringValue.map { TUITranscriptEntry(role: .user, text: $0) }
        case .assistantDone:
            return event.payload["text"]?.stringValue.map { TUITranscriptEntry(role: .codex, text: $0) }
        case .toolStarted:
            return TUITranscriptEntry(role: .tool, text: "start  \(compactPayload(event.payload))")
        case .toolFinished:
            return TUITranscriptEntry(role: .tool, text: "done   \(compactPayload(event.payload))")
        default:
            return nil
        }
    }
}

private func tuiInfo(task: TaskRecord, summary: TaskRunSummary, runtime: AgentTUIRuntime) -> String {
    var lines = [
        "id: \(task.id.uuidString)",
        "title: \(task.title)",
        "state: \(task.state.rawValue)",
        "backend: \(task.backendPreference.rawValue)",
        "store: \(storeDescription(options: runtime.storeOptions, repoURL: runtime.repoURL, snapshot: runtime.snapshot))",
        "repo: \(runtime.snapshot.rootPath ?? runtime.repoURL.path)",
        "branch: \(runtime.snapshot.currentBranch ?? "-")"
    ]

    if let session = summary.sessions.first {
        lines.append("thread: \(session.backendSessionID ?? "-")")
        lines.append("cwd: \(session.cwd)")
    }

    return lines.joined(separator: "\n")
}

private func tuiTasks(_ tasks: [TaskRecord]) -> String {
    if tasks.isEmpty {
        return "No tasks found."
    }

    return tasks
        .map { "\($0.slug)  \($0.title)  \($0.state.rawValue)" }
        .joined(separator: "\n")
}

private func tuiEvents(_ events: [AgentEvent]) -> String {
    if events.isEmpty {
        return "No events found."
    }

    return events.map { event in
        let sequence = event.sequence.map(String.init) ?? "-"
        return "\(sequence) \(event.kind.rawValue) \(compactPayload(event.payload))"
    }
    .joined(separator: "\n")
}

private func transcriptLines(_ entries: [TUITranscriptEntry], width: Int) -> [TUITranscriptLine] {
    var lines: [TUITranscriptLine] = []
    let bodyWidth = max(20, width - 2)

    func append(role: TUITranscriptRole, text: String, isLabel: Bool) {
        lines.append(TUITranscriptLine(id: lines.count, role: role, text: text, isLabel: isLabel))
    }

    for entry in entries {
        if !lines.isEmpty {
            append(role: .system, text: "", isLabel: false)
        }

        append(role: entry.role, text: entry.role.rawValue, isLabel: true)
        for rawLine in entry.text.split(separator: "\n", omittingEmptySubsequences: false) {
            for wrapped in wrapText(String(rawLine), width: bodyWidth) {
                append(role: entry.role, text: "  \(wrapped)", isLabel: false)
            }
        }
    }

    return lines
}

private func wrapText(_ text: String, width: Int) -> [String] {
    guard !text.isEmpty else {
        return [""]
    }

    var lines: [String] = []
    var current = ""

    func flush() {
        if !current.isEmpty {
            lines.append(current)
            current = ""
        }
    }

    for word in text.split(separator: " ", omittingEmptySubsequences: false) {
        let piece = String(word)
        if piece.count > width {
            flush()
            var remainder = piece
            while remainder.count > width {
                let end = remainder.index(remainder.startIndex, offsetBy: width)
                lines.append(String(remainder[..<end]))
                remainder = String(remainder[end...])
            }
            current = remainder
            continue
        }

        if current.count + piece.count + 1 > width, !current.isEmpty {
            flush()
        }
        current += current.isEmpty ? piece : " \(piece)"
    }

    flush()
    return lines.isEmpty ? [""] : lines
}

private func terminalSize() -> TerminalSize {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
        return TerminalSize(rows: 24, columns: 80)
    }
    return TerminalSize(rows: Int(size.ws_row), columns: Int(size.ws_col))
}
