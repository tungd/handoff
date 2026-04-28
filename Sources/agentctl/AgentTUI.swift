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
    var modelDisplayName: String
    var modelContextWindowTokens: Int64?
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
    let modelMetadata = resolvedCodexModelMetadata()
    let runtime = AgentTUIRuntime(
        task: task,
        storeOptions: storeOptions,
        repoURL: repoURL,
        snapshot: snapshot,
        store: store,
        model: AgentTUIModel(task: task, entries: initialEntries.isEmpty ? [
            TUITranscriptEntry(role: .system, text: "Ready.")
        ] : initialEntries),
        modelDisplayName: modelMetadata.displayName,
        modelContextWindowTokens: modelMetadata.contextWindowTokens,
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
    var style: TUITranscriptStyle = .message
    var toolKey: String?
}

private struct TUITranscriptLine: Identifiable, Sendable {
    var id: Int
    var role: TUITranscriptRole
    var text: String
    var spans: [AgentTUIStyledTextSpan]
    var isLabel: Bool
}

private enum TUITranscriptStyle: Sendable, Equatable {
    case message
    case userQuote
    case toolCall(AgentTUIToolStatus)
    case toolOutput
}

private struct AgentTUISnapshot: Sendable {
    var task: TaskRecord
    var entries: [TUITranscriptEntry]
    var status: String
    var tokenUsage: TUITokenUsage?
    var scrollOffset: Int
    var showRawEvents: Bool
    var isRunning: Bool
    var revision: Int
}

private struct TUITokenUsage: Sendable, Equatable {
    var inputTokens: Int64
    var outputTokens: Int64
    var reasoningTokens: Int64
    var contextWindowTokens: Int64?
}

private struct CodexModelMetadata: Sendable, Equatable {
    var displayName: String
    var contextWindowTokens: Int64?
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
            tokenUsage: nil,
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

    func adjustScroll(_ delta: Int, maxOffset: Int) {
        update { state in
            state.scrollOffset = min(max(0, state.scrollOffset + delta), max(0, maxOffset))
        }
    }

    func render(_ update: AgentSessionUpdate) {
        self.update { state in
            switch update {
            case let .event(event):
                if let tokenUsage = tuiTokenUsage(from: event.payload) {
                    state.tokenUsage = tokenUsage
                }

                switch event.kind {
                case .assistantDone:
                    if let text = event.payload["text"]?.stringValue {
                        append(.codex, text, to: &state)
                    }
                case .toolStarted:
                    appendToolCall(event.payload, status: .running, to: &state)
                case .toolFinished:
                    finishToolCall(event.payload, to: &state)
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

    private func append(
        _ role: TUITranscriptRole,
        _ text: String,
        style: TUITranscriptStyle? = nil,
        toolKey: String? = nil,
        to state: inout AgentTUISnapshot
    ) {
        let resolvedStyle = style ?? (role == .user ? .userQuote : .message)
        state.entries.append(TUITranscriptEntry(
            role: role,
            text: text,
            style: resolvedStyle,
            toolKey: toolKey
        ))
        state.scrollOffset = 0
    }

    private func appendToolCall(
        _ payload: [String: JSONValue],
        status: AgentTUIToolStatus,
        to state: inout AgentTUISnapshot
    ) {
        append(
            .tool,
            agentTUIToolCallText(from: payload),
            style: .toolCall(status),
            toolKey: agentTUIToolCallKey(from: payload),
            to: &state
        )
    }

    private func finishToolCall(_ payload: [String: JSONValue], to state: inout AgentTUISnapshot) {
        let key = agentTUIToolCallKey(from: payload)
        let status: AgentTUIToolStatus
        if case let .int(exitCode) = payload["exitCode"], exitCode != 0 {
            status = .failed
        } else {
            status = .succeeded
        }

        if let index = state.entries.lastIndex(where: { entry in
            entry.toolKey == key && entry.style == .toolCall(.running)
        }) {
            state.entries[index].text = agentTUIToolCallText(from: payload)
            state.entries[index].style = .toolCall(status)
        } else {
            appendToolCall(payload, status: status, to: &state)
        }

        if let output = agentTUIToolOutputText(from: payload) {
            append(.tool, output, style: .toolOutput, toolKey: key, to: &state)
        }
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
        let transcriptHeight = max(3, size.rows - 9)
        let lines = transcriptLines(snapshot.entries, width: max(40, size.columns - 4))
        let maxScrollOffset = max(0, lines.count - transcriptHeight)
        let scrollOffset = clampedScrollOffset(snapshot.scrollOffset, maxOffset: maxScrollOffset)
        let visibleLines = visibleLines(lines, height: transcriptHeight, scrollOffset: scrollOffset)

        VStack(alignment: .leading, spacing: 0) {
            header(snapshot)
            dividerLine(label: nil, width: max(20, size.columns))
            VStack(alignment: .leading, spacing: 0) {
                ViewArray(visibleLines.map(transcriptLine))
            }
            .frame(height: transcriptHeight, alignment: .topLeading)
            Spacer(minLength: 0)
            composer(
                snapshot,
                terminalWidth: size.columns
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .palette(AgentTUIPalette())
        .appearance(.line)
        .onKeyPress { event in
            handleKey(event, pageSize: transcriptHeight, maxScrollOffset: maxScrollOffset)
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
        terminalWidth: Int
    ) -> some View {
        let width = max(20, terminalWidth)

        return VStack(alignment: .leading, spacing: 0) {
            Text("").frame(width: width)
            activityLine(snapshot, width: width)
            Text("").frame(width: width)
            dividerLine(label: modelDisplayName, width: width)
            inputLine(width: width)
            dividerLine(label: nil, width: width)
            composerStatus(snapshot, width: width).frame(width: width)
        }
    }

    private func activityLine(_ snapshot: AgentTUISnapshot, width: Int) -> some View {
        HStack(spacing: 1) {
            Text(" ")
            if shouldSpinActivity(snapshot) {
                Spinner(activityText(snapshot), style: .dots, color: .palette.info)
            } else if shouldShowActivity(snapshot) {
                Text(activityText(snapshot)).foregroundStyle(activityColor(snapshot))
            } else {
                Text("")
            }
            Spacer(minLength: 0)
        }
        .frame(width: width)
    }

    private func dividerLine(label: String?, width: Int) -> some View {
        Text(agentTUIHorizontalDivider(label: label, width: width))
            .foregroundStyle(.palette.foregroundTertiary)
            .frame(width: width)
    }

    private func inputLine(width: Int) -> some View {
        let visible = visibleInputParts(width: width)

        return HStack(spacing: 0) {
            if !visible.before.isEmpty {
                Text(visible.before).foregroundStyle(.palette.foreground)
            }
            Text("█").foregroundStyle(.default)
            if !visible.after.isEmpty {
                Text(visible.after).foregroundStyle(.palette.foreground)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width)
    }

    private func composerStatus(
        _ snapshot: AgentTUISnapshot,
        width: Int
    ) -> some View {
        Text(statusLine(snapshot, width: width))
            .foregroundStyle(.palette.foregroundTertiary)
    }

    private func transcriptLine(_ line: TUITranscriptLine) -> AnyView {
        if line.isLabel {
            return AnyView(Text(line.text).foregroundStyle(labelColor(line.role)))
        }

        if !line.spans.isEmpty {
            return AnyView(HStack(spacing: 0) {
                ViewArray(line.spans.map { span in
                    transcriptSpan(span, role: line.role)
                })
            })
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

    private func transcriptSpan(_ span: AgentTUIStyledTextSpan, role: TUITranscriptRole) -> AnyView {
        var text = Text(span.text).foregroundStyle(spanColor(span.tone, role: role))
        if span.isBold {
            text = text.bold()
        }
        if span.isItalic {
            text = text.italic()
        }
        if span.isUnderlined {
            text = text.underline()
        }
        return AnyView(text)
    }

    private func spanColor(_ tone: AgentTUIStyledTextTone, role: TUITranscriptRole) -> Color {
        switch tone {
        case .base:
            switch role {
            case .user, .codex:
                return .palette.foreground
            case .tool, .system:
                return .palette.foregroundSecondary
            case .error:
                return .palette.error
            }
        case .secondary:
            return .palette.foregroundTertiary
        case .accent:
            return .palette.accent
        case .success:
            return .palette.success
        case .failure:
            return .palette.error
        case .quote:
            return .palette.warning
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

    private func shouldShowActivity(_ snapshot: AgentTUISnapshot) -> Bool {
        snapshot.isRunning || snapshot.status != "ready"
    }

    private func shouldSpinActivity(_ snapshot: AgentTUISnapshot) -> Bool {
        snapshot.isRunning || snapshot.status.hasSuffix("...")
    }

    private func activityText(_ snapshot: AgentTUISnapshot) -> String {
        if snapshot.status.hasPrefix("turn failed") {
            return "Turn failed."
        }
        if snapshot.status.hasPrefix("command failed") {
            return "Command failed."
        }
        if snapshot.isRunning {
            return "Working..."
        }
        return snapshot.status
    }

    private func activityColor(_ snapshot: AgentTUISnapshot) -> Color {
        if snapshot.status.hasPrefix("turn failed") || snapshot.status.hasPrefix("command failed") {
            return .palette.error
        }
        return .palette.foregroundTertiary
    }

    private var storeName: String {
        guard let runtime = AgentTUIRuntimeBox.current else {
            return "-"
        }
        return shortStoreName(storeDescription(options: runtime.storeOptions, repoURL: runtime.repoURL, snapshot: runtime.snapshot))
    }

    private var repoBranchText: String {
        guard let runtime = AgentTUIRuntimeBox.current else {
            return "- (-)"
        }
        let path = runtime.snapshot.rootPath ?? runtime.repoURL.path
        let branch = runtime.snapshot.currentBranch ?? "-"
        return "\(abbreviatedHomePath(path)) (\(branch))"
    }

    private var modelDisplayName: String {
        AgentTUIRuntimeBox.current?.modelDisplayName ?? "codex"
    }

    private func tokenStatus(_ snapshot: AgentTUISnapshot) -> String {
        let usage = snapshot.tokenUsage ?? TUITokenUsage(
            inputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            contextWindowTokens: nil
        )
        let contextWindow = usage.contextWindowTokens
            ?? AgentTUIRuntimeBox.current?.modelContextWindowTokens
            ?? defaultContextWindowTokens(modelDisplayName: modelDisplayName)
        let percent = contextWindow > 0 ? (Double(max(0, usage.inputTokens)) / Double(contextWindow)) * 100 : 0
        var parts = [
            "↑\(formatTokenCount(usage.inputTokens))",
            "↓\(formatTokenCount(usage.outputTokens))"
        ]
        if usage.reasoningTokens > 0 {
            parts.append("R\(formatTokenCount(usage.reasoningTokens))")
        }
        parts.append("\(formatPercent(percent))%/\(formatTokenCount(contextWindow))")
        return parts.joined(separator: " ")
    }

    private func statusLine(_ snapshot: AgentTUISnapshot, width: Int) -> String {
        var leftParts = [repoBranchText]
        if snapshot.showRawEvents {
            leftParts.append("raw")
        }

        return agentTUIStatusLine(
            repoBranchText: repoBranchText,
            badges: Array(leftParts.dropFirst()),
            tokenStatus: tokenStatus(snapshot),
            width: width
        )
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

    private func handleKey(_ event: KeyEvent, pageSize: Int, maxScrollOffset: Int) -> Bool {
        switch event.key {
        case .enter:
            submitInput()
            return true
        case .escape:
            Darwin.raise(SIGINT)
            return true
        case .character("c") where event.ctrl:
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
        case .up where event.ctrl:
            model.adjustScroll(1, maxOffset: maxScrollOffset)
            return true
        case .down where event.ctrl:
            model.adjustScroll(-1, maxOffset: maxScrollOffset)
            return true
        case .up:
            model.adjustScroll(3, maxOffset: maxScrollOffset)
            return true
        case .down:
            model.adjustScroll(-3, maxOffset: maxScrollOffset)
            return true
        case .pageUp:
            model.adjustScroll(pageSize, maxOffset: maxScrollOffset)
            return true
        case .pageDown:
            model.adjustScroll(-pageSize, maxOffset: maxScrollOffset)
            return true
        case .character("u") where event.ctrl:
            model.adjustScroll(pageSize, maxOffset: maxScrollOffset)
            return true
        case .character("d") where event.ctrl:
            model.adjustScroll(-pageSize, maxOffset: maxScrollOffset)
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
        let textWidth = max(1, width)
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
        let offset = clampedScrollOffset(scrollOffset, maxOffset: maxOffset)
        let start = max(0, lines.count - height - offset)
        return Array(lines.dropFirst(start).prefix(height))
    }

    private func clampedScrollOffset(_ scrollOffset: Int, maxOffset: Int) -> Int {
        min(max(0, scrollOffset), max(0, maxOffset))
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
    var entries: [TUITranscriptEntry] = []

    func append(
        _ role: TUITranscriptRole,
        _ text: String,
        style: TUITranscriptStyle? = nil,
        toolKey: String? = nil
    ) {
        entries.append(TUITranscriptEntry(
            role: role,
            text: text,
            style: style ?? (role == .user ? .userQuote : .message),
            toolKey: toolKey
        ))
    }

    for event in try await store.events(for: taskID) {
        switch event.kind {
        case .userMessage:
            if let text = event.payload["text"]?.stringValue {
                append(.user, text)
            }
        case .assistantDone:
            if let text = event.payload["text"]?.stringValue {
                append(.codex, text)
            }
        case .toolStarted:
            append(
                .tool,
                agentTUIToolCallText(from: event.payload),
                style: .toolCall(.running),
                toolKey: agentTUIToolCallKey(from: event.payload)
            )
        case .toolFinished:
            let key = agentTUIToolCallKey(from: event.payload)
            let status: AgentTUIToolStatus
            if case let .int(exitCode) = event.payload["exitCode"], exitCode != 0 {
                status = .failed
            } else {
                status = .succeeded
            }

            if let index = entries.lastIndex(where: { entry in
                entry.toolKey == key && entry.style == .toolCall(.running)
            }) {
                entries[index].text = agentTUIToolCallText(from: event.payload)
                entries[index].style = .toolCall(status)
            } else {
                append(.tool, agentTUIToolCallText(from: event.payload), style: .toolCall(status), toolKey: key)
            }

            if let output = agentTUIToolOutputText(from: event.payload) {
                append(.tool, output, style: .toolOutput, toolKey: key)
            }
        default:
            break
        }
    }

    return entries
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
        lines.append(TUITranscriptLine(
            id: lines.count,
            role: role,
            text: text,
            spans: isLabel ? [] : [AgentTUIStyledTextSpan(text)],
            isLabel: isLabel
        ))
    }

    func append(role: TUITranscriptRole, spans: [AgentTUIStyledTextSpan]) {
        lines.append(TUITranscriptLine(
            id: lines.count,
            role: role,
            text: agentTUIPlainText(spans),
            spans: spans,
            isLabel: false
        ))
    }

    for entry in entries {
        if !lines.isEmpty {
            append(role: .system, text: "", isLabel: false)
        }

        switch entry.style {
        case .message:
            append(role: entry.role, text: entry.role.rawValue, isLabel: true)
            for renderedLine in agentTUIMarkdownStyledLines(entry.text, width: bodyWidth) {
                append(role: entry.role, spans: [AgentTUIStyledTextSpan("  ")] + renderedLine)
            }
        case .userQuote:
            for renderedLine in agentTUIQuoteStyledLines(entry.text, width: bodyWidth) {
                append(role: entry.role, spans: renderedLine)
            }
        case let .toolCall(status):
            append(role: entry.role, spans: agentTUIToolCallStyledLine(entry.text, status: status))
        case .toolOutput:
            for renderedLine in agentTUIToolOutputStyledLines(entry.text, width: bodyWidth) {
                append(role: entry.role, spans: renderedLine)
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

private func tuiTokenUsage(from payload: [String: JSONValue]) -> TUITokenUsage? {
    var contextWindow = jsonInt(payload["model_context_window"])
        ?? jsonInt(payload["context_window"])
        ?? jsonInt(payload["context_window_tokens"])
        ?? jsonInt(payload["context_limit"])
    var usage = payload["usage"]?.objectValue

    if let info = payload["info"]?.objectValue {
        contextWindow = contextWindow
            ?? jsonInt(info["model_context_window"])
            ?? jsonInt(info["context_window"])
            ?? jsonInt(info["context_window_tokens"])
            ?? jsonInt(info["context_limit"])
        usage = usage ?? info["last_token_usage"]?.objectValue
    }

    usage = usage ?? payload["last_token_usage"]?.objectValue

    guard let usage else {
        if let contextWindow {
            return TUITokenUsage(
                inputTokens: 0,
                outputTokens: 0,
                reasoningTokens: 0,
                contextWindowTokens: contextWindow
            )
        }
        return nil
    }

    let input = jsonInt(usage["input_tokens"])
        ?? jsonInt(usage["prompt_tokens"])
        ?? 0
    let output = jsonInt(usage["output_tokens"])
        ?? jsonInt(usage["completion_tokens"])
        ?? 0
    var reasoning = jsonInt(usage["reasoning_output_tokens"])
        ?? jsonInt(usage["reasoning_tokens"])
        ?? 0

    if let outputDetails = usage["output_tokens_details"]?.objectValue {
        reasoning = jsonInt(outputDetails["reasoning_tokens"]) ?? reasoning
    }

    contextWindow = contextWindow
        ?? jsonInt(usage["model_context_window"])
        ?? jsonInt(usage["context_window"])
        ?? jsonInt(usage["context_window_tokens"])
        ?? jsonInt(usage["context_limit"])

    guard input > 0 || output > 0 || reasoning > 0 else {
        return nil
    }

    return TUITokenUsage(
        inputTokens: input,
        outputTokens: output,
        reasoningTokens: reasoning,
        contextWindowTokens: contextWindow
    )
}

private func jsonInt(_ value: JSONValue?) -> Int64? {
    switch value {
    case let .int(value):
        return value
    case let .double(value):
        return Int64(value)
    case let .string(value):
        return Int64(value)
    default:
        return nil
    }
}

private func formatTokenCount(_ value: Int64) -> String {
    let sign = value < 0 ? "-" : ""
    let absolute = abs(value)
    guard absolute >= 1_000 else {
        return "\(value)"
    }

    let scaled = Double(absolute) / 1_000
    if absolute % 1_000 == 0 {
        return "\(sign)\(Int(scaled.rounded()))k"
    }
    return "\(sign)\(String(format: "%.1f", scaled))k"
}

private func formatPercent(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func defaultContextWindowTokens(modelDisplayName: String) -> Int64 {
    if modelDisplayName.localizedCaseInsensitiveContains("gpt-5") {
        return 128_000
    }
    return 128_000
}

private func abbreviatedHomePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
        return "~"
    }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

private func truncateMiddle(_ value: String, maxWidth: Int) -> String {
    guard maxWidth > 0 else {
        return ""
    }
    guard value.count > maxWidth else {
        return value
    }
    guard maxWidth > 3 else {
        return String(value.prefix(maxWidth))
    }

    let marker = "..."
    let remaining = maxWidth - marker.count
    let prefixCount = max(1, remaining / 2)
    let suffixCount = max(1, remaining - prefixCount)
    return String(value.prefix(prefixCount)) + marker + String(value.suffix(suffixCount))
}

func agentTUIHorizontalDivider(label: String?, width: Int) -> String {
    let width = max(0, width)
    guard width > 0 else {
        return ""
    }
    guard let label, !label.isEmpty else {
        return String(repeating: "─", count: width)
    }

    let title = " \(label) "
    guard title.count < width else {
        return String(title.prefix(width))
    }

    let prefixWidth = min(2, max(0, width - title.count))
    let suffixWidth = max(0, width - prefixWidth - title.count)
    return String(repeating: "─", count: prefixWidth) + title + String(repeating: "─", count: suffixWidth)
}

func agentTUIStatusLine(repoBranchText: String, badges: [String], tokenStatus: String, width: Int) -> String {
    var leftParts = [repoBranchText]
    leftParts.append(contentsOf: badges)

    let availableWidth = max(0, width)
    guard availableWidth > 0 else {
        return ""
    }
    guard tokenStatus.count < availableWidth else {
        return String(tokenStatus.suffix(availableWidth))
    }

    let rightStart = availableWidth - tokenStatus.count
    let maxLeftWidth = max(0, rightStart - 1)
    let left = truncateMiddle(leftParts.joined(separator: " "), maxWidth: maxLeftWidth)
    let spaces = max(1, rightStart - left.count)
    return left + String(repeating: " ", count: spaces) + tokenStatus
}

private func resolvedCodexModelMetadata() -> CodexModelMetadata {
    let environment = ProcessInfo.processInfo.environment
    let defaults = codexConfigDefaults()
    let model = nonEmpty(environment["CODEX_MODEL"])
        ?? nonEmpty(defaults["model"])
        ?? "codex"
    let effort = nonEmpty(environment["CODEX_MODEL_REASONING_EFFORT"])
        ?? nonEmpty(defaults["model_reasoning_effort"])

    let displayName: String
    if let effort {
        displayName = "\(model) (\(effort))"
    } else {
        displayName = model
    }

    return CodexModelMetadata(
        displayName: displayName,
        contextWindowTokens: codexCatalogContextWindow(modelSlug: model)
    )
}

private func codexCatalogContextWindow(modelSlug: String) -> Int64? {
    guard
        let catalog = codexBundledModelCatalog(),
        let models = catalog["models"] as? [[String: Any]],
        let model = models.first(where: { catalogModelMatches($0, slug: modelSlug) })
    else {
        return nil
    }

    let contextWindow = intFromAny(model["context_window"])
        ?? intFromAny(model["max_context_window"])
    guard let contextWindow else {
        return nil
    }

    guard let effectivePercent = doubleFromAny(model["effective_context_window_percent"]) else {
        return contextWindow
    }

    return Int64((Double(contextWindow) * effectivePercent / 100).rounded())
}

private func codexBundledModelCatalog() -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["codex", "debug", "models", "--bundled"]
    process.standardError = FileHandle.nullDevice

    let output = Pipe()
    process.standardOutput = output

    do {
        try process.run()
    } catch {
        return nil
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func catalogModelMatches(_ model: [String: Any], slug: String) -> Bool {
    if (model["slug"] as? String) == slug {
        return true
    }
    if (model["display_name"] as? String)?.localizedCaseInsensitiveCompare(slug) == .orderedSame {
        return true
    }
    return false
}

private func intFromAny(_ value: Any?) -> Int64? {
    switch value {
    case let value as Int:
        return Int64(value)
    case let value as Int64:
        return value
    case let value as Double:
        return Int64(value)
    case let value as String:
        return Int64(value)
    default:
        return nil
    }
}

private func doubleFromAny(_ value: Any?) -> Double? {
    switch value {
    case let value as Int:
        return Double(value)
    case let value as Int64:
        return Double(value)
    case let value as Double:
        return value
    case let value as String:
        return Double(value)
    default:
        return nil
    }
}

private func codexConfigDefaults() -> [String: String] {
    let environment = ProcessInfo.processInfo.environment
    let codexHome = nonEmpty(environment["CODEX_HOME"])
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    let configURL = URL(fileURLWithPath: codexHome).appendingPathComponent("config.toml")

    guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
        return [:]
    }

    var values: [String: String] = [:]
    var inTopLevel = true

    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        if line.hasPrefix("[") {
            inTopLevel = false
            continue
        }
        guard inTopLevel, let separator = line.firstIndex(of: "=") else {
            continue
        }

        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        values[key] = tomlScalarString(value)
    }

    return values
}

private func tomlScalarString(_ rawValue: String) -> String {
    var value = rawValue
    if let comment = value.firstIndex(of: "#") {
        value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
    }
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value.removeFirst()
        value.removeLast()
        return value
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
    return value
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return value
}

private func terminalSize() -> TerminalSize {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
        return TerminalSize(rows: 24, columns: 80)
    }
    return TerminalSize(rows: Int(size.ws_row), columns: Int(size.ws_col))
}
