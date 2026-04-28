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
    var initialEntries: [TUITranscriptEntry]
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
        initialEntries: initialEntries.isEmpty ? [
            TUITranscriptEntry(role: .system, text: "Ready.")
        ] : initialEntries,
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

private struct TerminalSize {
    var rows: Int
    var columns: Int
}

private struct AgentTUIView: View {
    @State private var task: TaskRecord
    @State private var entries: [TUITranscriptEntry]
    @State private var input = ""
    @State private var status = "ready"
    @State private var scrollOffset = 0
    @State private var showRawEvents = false
    @State private var isRunning = false

    init() {
        guard let runtime = AgentTUIRuntimeBox.current else {
            fatalError("AgentTUIView launched without runtime")
        }
        _task = State(wrappedValue: runtime.task)
        _entries = State(wrappedValue: runtime.initialEntries)
    }

    var body: some View {
        let size = terminalSize()
        let transcriptHeight = max(3, size.rows - 7)
        let lines = transcriptLines(entries, width: max(40, size.columns - 2))
        let visibleLines = visibleLines(lines, height: transcriptHeight)

        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ViewArray(visibleLines.map(transcriptLine))
            }
            Spacer(minLength: 0)
            Divider()
            statusLine(totalLines: lines.count, visibleHeight: transcriptHeight)
            composer
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

    private var header: some View {
        HStack(spacing: 1) {
            Text("agentctl").foregroundStyle(.palette.accent).bold()
            Text(task.slug).foregroundStyle(.palette.foregroundSecondary)
            Spacer()
            Text(task.backendPreference.rawValue).foregroundStyle(.palette.success)
            Text(storeName).foregroundStyle(.palette.foregroundSecondary)
        }
    }

    private func statusLine(totalLines: Int, visibleHeight: Int) -> some View {
        HStack(spacing: 1) {
            Text(status).foregroundStyle(statusColor)
            if showRawEvents {
                Text("raw").foregroundStyle(.palette.warning)
            }
            if scrollOffset > 0 {
                Text("scroll \(scrollOffset)").foregroundStyle(.palette.foregroundSecondary)
            }
            Spacer()
            Text("\(min(totalLines, visibleHeight))/\(totalLines)").dim()
        }
    }

    private var composer: some View {
        HStack(spacing: 1) {
            Text(">").foregroundStyle(.palette.accent).bold()
            TextField("message", text: $input, prompt: Text(isRunning ? "turn running..." : "message or /command"))
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

    private var statusColor: Color {
        if status.hasPrefix("turn failed") {
            return .palette.error
        }
        if isRunning {
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

        guard !isRunning else {
            append(.error, "A Codex turn is already running.")
            return
        }

        guard let runtime = AgentTUIRuntimeBox.current else {
            append(.error, "TUI runtime is not available.")
            return
        }

        let currentTask = task
        append(.user, text)
        isRunning = true
        status = "running Codex turn..."

        _Concurrency.Task {
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
                    await MainActor.run {
                        render(update)
                    }
                }
                await MainActor.run {
                    status = "ready"
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    status = "turn failed"
                    isRunning = false
                    append(.error, String(describing: error))
                }
            }
        }
    }

    private func handle(_ command: SlashCommand) {
        guard let runtime = AgentTUIRuntimeBox.current else {
            append(.error, "TUI runtime is not available.")
            return
        }

        switch command.name {
        case "exit", "quit":
            Darwin.raise(SIGINT)
        case "help":
            append(.system, "/help /info /tasks /new [title] /resume <task> /events /raw /exit")
        case "raw":
            showRawEvents.toggle()
            append(.system, showRawEvents ? "Raw event rendering enabled." : "Raw event rendering disabled.")
        case "info", "task", "repo":
            runCommand(status: "loading task info...") {
                let summary = try await runtime.store.summary(for: task)
                await MainActor.run {
                    append(.system, tuiInfo(task: task, summary: summary, runtime: runtime))
                    status = "ready"
                }
            }
        case "tasks":
            runCommand(status: "loading tasks...") {
                let tasks = try await runtime.store.listTasks()
                await MainActor.run {
                    append(.system, tuiTasks(tasks))
                    status = "ready"
                }
            }
        case "events":
            runCommand(status: "loading events...") {
                let events = try await runtime.store.events(for: task.id)
                await MainActor.run {
                    append(.system, tuiEvents(events))
                    status = "ready"
                }
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
                await MainActor.run {
                    task = newTask
                    entries = []
                    scrollOffset = 0
                    append(.system, "Created task \(newTask.slug).")
                    status = "ready"
                }
            }
        case "resume":
            guard let identifier = command.argument, !identifier.isEmpty else {
                append(.error, "usage: /resume <task>")
                return
            }
            runCommand(status: "resuming task...") {
                let resumedTask = try await runtime.store.findTask(identifier)
                let loadedEntries = try await tuiEntries(for: resumedTask.id, store: runtime.store)
                await MainActor.run {
                    task = resumedTask
                    entries = loadedEntries
                    append(.system, "Resumed task \(resumedTask.slug).")
                    scrollOffset = 0
                    status = "ready"
                }
            }
        default:
            append(.error, "unknown command: /\(command.name)")
        }
    }

    private func runCommand(status newStatus: String, operation: @escaping @Sendable () async throws -> Void) {
        status = newStatus
        _Concurrency.Task {
            do {
                try await operation()
            } catch {
                await MainActor.run {
                    status = "command failed"
                    append(.error, String(describing: error))
                }
            }
        }
    }

    private func render(_ update: AgentSessionUpdate) {
        switch update {
        case let .event(event):
            switch event.kind {
            case .assistantDone:
                if let text = event.payload["text"]?.stringValue {
                    append(.codex, text)
                }
            case .toolStarted:
                append(.tool, "start  \(compactPayload(event.payload))")
            case .toolFinished:
                append(.tool, "done   \(compactPayload(event.payload))")
            case .userMessage:
                break
            case .backendSessionUpdated, .backendEvent:
                if showRawEvents {
                    append(.system, "\(event.kind.rawValue) \(compactPayload(event.payload))")
                }
            default:
                if showRawEvents {
                    append(.system, "\(event.kind.rawValue) \(compactPayload(event.payload))")
                }
            }
        case let .session(session):
            status = "session \(session.state.rawValue)"
        }
    }

    private func append(_ role: TUITranscriptRole, _ text: String) {
        entries.append(TUITranscriptEntry(role: role, text: text))
        scrollOffset = 0
    }

    private func handleKey(_ event: KeyEvent, pageSize: Int) -> Bool {
        switch event.key {
        case .pageUp:
            scrollOffset += pageSize
            return true
        case .pageDown:
            scrollOffset = max(0, scrollOffset - pageSize)
            return true
        case .up where event.ctrl:
            scrollOffset += 1
            return true
        case .down where event.ctrl:
            scrollOffset = max(0, scrollOffset - 1)
            return true
        case .character("u") where event.ctrl:
            scrollOffset += pageSize
            return true
        case .character("d") where event.ctrl:
            scrollOffset = max(0, scrollOffset - pageSize)
            return true
        default:
            return false
        }
    }

    private func visibleLines(_ lines: [TUITranscriptLine], height: Int) -> [TUITranscriptLine] {
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
