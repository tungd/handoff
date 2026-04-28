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
        setTerminalAlternateScrollMode(enabled: true)
        defer { setTerminalAlternateScrollMode(enabled: false) }
        AgentTUIRuntimeBox.current = runtime
        AgentTUIApp.main()
        AgentTUIRuntimeBox.current = nil
    }
}

private func setTerminalAlternateScrollMode(enabled: Bool) {
    // xterm alternate-scroll mode turns wheel events into Up/Down keys in alternate screen.
    let sequence = enabled ? "\u{1B}[?1007h" : "\u{1B}[?1007l"
    FileHandle.standardOutput.write(Data(sequence.utf8))
}

struct AgentTUIApp: App {
    var body: some Scene {
        WindowGroup {
            AgentTUIView()
        }
    }
}

private struct AgentTUIPalette: Palette {
    let id = "agentctl-amber"
    let name = "Agentctl Amber"

    let background = Color.rgb(12, 12, 11)
    let statusBarBackground = Color.rgb(12, 12, 11)
    let appHeaderBackground = Color.rgb(12, 12, 11)
    let overlayBackground = Color.rgb(12, 12, 11)

    let foreground = Color.rgb(232, 226, 214)
    let foregroundSecondary = Color.rgb(159, 151, 136)
    let foregroundTertiary = Color.rgb(107, 101, 92)
    let foregroundQuaternary = Color.rgb(67, 64, 59)

    let accent = Color.rgb(214, 171, 93)
    let success = Color.rgb(232, 226, 214)
    let warning = Color.rgb(201, 157, 74)
    let error = Color.rgb(211, 109, 95)
    let info = Color.rgb(149, 168, 174)

    let border = Color.rgb(183, 170, 143)
    let focusBackground = Color.rgb(28, 27, 24)
    let cursorColor = Color.default
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
    @State private var inputCursor = 0

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
        let lines = transcriptLines(snapshot.entries, width: max(40, size.columns - 4))
        let visibleLines = visibleLines(lines, height: transcriptHeight, scrollOffset: snapshot.scrollOffset)

        VStack(alignment: .leading, spacing: 0) {
            header(snapshot)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ViewArray(visibleLines.map(transcriptLine))
            }
            .frame(height: transcriptHeight, alignment: .topLeading)
            Spacer(minLength: 0)
            composer(snapshot, totalLines: lines.count, visibleHeight: transcriptHeight, terminalWidth: size.columns)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .palette(AgentTUIPalette())
        .appearance(.line)
        .onKeyPress { event in
            handleKey(event, pageSize: transcriptHeight)
        }
        .agentStatusBarConfiguration()
    }

    private func header(_ snapshot: AgentTUISnapshot) -> some View {
        HStack(spacing: 1) {
            Text("agentctl").foregroundStyle(.palette.accent)
            Text(snapshot.task.slug).foregroundStyle(.palette.foregroundTertiary)
            Spacer()
            Text(storeName).foregroundStyle(.palette.foregroundTertiary)
        }
    }

    private func composer(
        _ snapshot: AgentTUISnapshot,
        totalLines: Int,
        visibleHeight: Int,
        terminalWidth: Int
    ) -> some View {
        Panel(modelLabel(snapshot), borderStyle: .line, borderColor: .palette.border, titleColor: .palette.accent) {
            VStack(alignment: .leading, spacing: 0) {
                inputLine(snapshot, width: max(20, terminalWidth - 4))
                composerStatus(snapshot, totalLines: totalLines, visibleHeight: visibleHeight)
                    .frame(width: max(20, terminalWidth - 4))
            }
        }
    }

    private func inputLine(_ snapshot: AgentTUISnapshot, width: Int) -> some View {
        let visible = visibleInputParts(width: width)
        let prompt = snapshot.isRunning ? "turn running..." : "message or /command"

        return HStack(spacing: 0) {
            Text("> ").foregroundStyle(.palette.accent)
            if !visible.before.isEmpty {
                Text(visible.before).foregroundStyle(.palette.foreground)
            }
            Text("█").foregroundStyle(.default)
            if !visible.after.isEmpty {
                Text(visible.after).foregroundStyle(.palette.foreground)
            } else if input.isEmpty {
                Text(prompt).foregroundStyle(.palette.foregroundTertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width)
    }

    private func composerStatus(_ snapshot: AgentTUISnapshot, totalLines: Int, visibleHeight: Int) -> some View {
        HStack(spacing: 1) {
            Text(snapshot.status).foregroundStyle(statusColor(snapshot))
            if snapshot.showRawEvents {
                Text("raw").foregroundStyle(.palette.warning)
            }
            if snapshot.scrollOffset > 0 {
                Text("scroll \(snapshot.scrollOffset)").foregroundStyle(.palette.foregroundSecondary)
            }
            Spacer()
            Text("\(lineProgress(totalLines: totalLines, visibleHeight: visibleHeight, scrollOffset: snapshot.scrollOffset)) \(repoName)")
                .foregroundStyle(.palette.foregroundTertiary)
        }
    }

    private func transcriptLine(_ line: TUITranscriptLine) -> AnyView {
        if line.isLabel {
            return AnyView(Text(line.text).foregroundStyle(labelColor(line.role)))
        }

        switch line.role {
        case .user:
            return AnyView(Text(line.text).foregroundStyle(.palette.foreground))
        case .codex:
            return AnyView(Text(line.text).foregroundStyle(.palette.foreground))
        case .tool:
            return AnyView(Text(line.text).foregroundStyle(.palette.foregroundSecondary))
        case .error:
            return AnyView(Text(line.text).foregroundStyle(.palette.error).bold())
        case .system:
            return AnyView(Text(line.text).foregroundStyle(.palette.foregroundSecondary))
        }
    }

    private func labelColor(_ role: TUITranscriptRole) -> Color {
        switch role {
        case .user:
            return .palette.accent
        case .codex:
            return .palette.foregroundSecondary
        case .tool:
            return .palette.warning
        case .system:
            return .palette.foregroundTertiary
        case .error:
            return .palette.error
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

    private var repoName: String {
        guard let runtime = AgentTUIRuntimeBox.current else {
            return "-"
        }
        let path = runtime.snapshot.rootPath ?? runtime.repoURL.path
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func modelLabel(_ snapshot: AgentTUISnapshot) -> String {
        snapshot.task.backendPreference.rawValue
    }

    private func lineProgress(totalLines: Int, visibleHeight: Int, scrollOffset: Int) -> String {
        guard totalLines > 0 else {
            return "0/0"
        }
        if scrollOffset > 0 {
            return "-\(scrollOffset) \(min(totalLines, visibleHeight))/\(totalLines)"
        }
        return "\(min(totalLines, visibleHeight))/\(totalLines)"
    }

    private func submitInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        inputCursor = 0
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
        case .enter:
            submitInput()
            return true
        case .escape:
            Darwin.raise(SIGINT)
            return true
        case .backspace:
            deleteInputBackward()
            return true
        case .delete:
            deleteInputForward()
            return true
        case .left:
            inputCursor = max(0, inputCursor - 1)
            return true
        case .right:
            inputCursor = min(input.count, inputCursor + 1)
            return true
        case .home:
            inputCursor = 0
            return true
        case .end:
            inputCursor = input.count
            return true
        case .space where !event.ctrl && !event.alt:
            insertInput(" ")
            return true
        case .paste(let text):
            insertInput(text.replacingOccurrences(of: "\n", with: " "))
            return true
        case .character(let character) where !event.ctrl && !event.alt:
            insertInput(String(character))
            return true
        case .up:
            model.adjustScroll(3)
            return true
        case .down:
            model.adjustScroll(-3)
            return true
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

    private func insertInput(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        let safeText = text.sanitizedForTerminal
        let cursor = min(inputCursor, input.count)
        let index = input.index(input.startIndex, offsetBy: cursor)
        input.insert(contentsOf: safeText, at: index)
        inputCursor = cursor + safeText.count
    }

    private func deleteInputBackward() {
        guard inputCursor > 0 else {
            return
        }
        let cursor = min(inputCursor, input.count)
        let index = input.index(input.startIndex, offsetBy: cursor - 1)
        input.remove(at: index)
        inputCursor = cursor - 1
    }

    private func deleteInputForward() {
        guard inputCursor < input.count else {
            return
        }
        let cursor = min(inputCursor, input.count)
        let index = input.index(input.startIndex, offsetBy: cursor)
        input.remove(at: index)
        inputCursor = cursor
    }

    private func visibleInputParts(width: Int) -> (before: String, after: String) {
        let textWidth = max(1, width - 2)
        let visibleTextCount = max(0, textWidth - 1)
        let characters = Array(input)
        let cursor = min(inputCursor, characters.count)
        let start = max(0, min(cursor, characters.count) - visibleTextCount)
        let end = min(characters.count, start + visibleTextCount)
        let before = start < cursor ? String(characters[start..<cursor]) : ""
        let after = cursor < end ? String(characters[cursor..<end]) : ""
        return (before, after)
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
