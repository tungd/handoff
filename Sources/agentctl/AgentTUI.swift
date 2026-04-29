import AgentCore
import Darwin
import Foundation
import TUIkit

// MARK: - File Drop Support

/// Represents a file dropped onto the terminal (iTerm2/Ghostty OSC 1337 protocol).
private struct AgentTUIDroppedFile: Sendable, Equatable {
    var name: String
    var mimeType: String
    var base64Data: String
    var size: Int

    /// Detects if paste content is actually a dropped file from OSC 1337.
    static func parse(fromPaste text: String) -> AgentTUIDroppedFile? {
        // OSC 1337 File format embedded in paste:
        // ESC ] 1337 ; File=name=<base64>;size=<bytes>:[<base64content>] BEL
        // We encode this as a JSON object for detection: {"_osc1337": {...}}
        guard text.hasPrefix("{_osc1337:"), text.hasSuffix("}") else {
            return nil
        }
        let inner = text.dropFirst(10).dropLast(1)
        guard let data = String(inner).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let name = json["name"] as? String,
              let base64Data = json["data"] as? String else {
            return nil
        }
        let mimeType = json["mimeType"] as? String ?? mimeTypeForFilename(name)
        let size = json["size"] as? Int ?? 0
        return AgentTUIDroppedFile(name: name, mimeType: mimeType, base64Data: base64Data, size: size)
    }

    static func mimeTypeForFilename(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain"
        case "json": return "application/json"
        case "swift": return "text/x-swift"
        case "py": return "text/x-python"
        case "js", "ts": return "text/javascript"
        default: return "application/octet-stream"
        }
    }
}

/// Wrapper for KeyEvent that can include file drop information.
private struct AgentTUIInputEvent: Sendable, Equatable {
    var keyEvent: KeyEvent
    var droppedFile: AgentTUIDroppedFile?

    init(keyEvent: KeyEvent, droppedFile: AgentTUIDroppedFile? = nil) {
        self.keyEvent = keyEvent
        self.droppedFile = droppedFile
    }

    /// Check if this is a dropped file event.
    var isFileDrop: Bool {
        droppedFile != nil
    }

    /// Parse from KeyEvent, detecting if paste contains OSC 1337 file data.
    static func from(keyEvent: KeyEvent) -> AgentTUIInputEvent {
        if case .paste(let text) = keyEvent.key {
            if let file = AgentTUIDroppedFile.parse(fromPaste: text) {
                return AgentTUIInputEvent(keyEvent: keyEvent, droppedFile: file)
            }
        }
        return AgentTUIInputEvent(keyEvent: keyEvent)
    }
}

private let agentTUITranscriptEventLimit = 80
private let agentTUIHydratedUserTextLimit = 2_000
private let agentTUIHydratedAssistantTextLimit = 8_000
private let agentTUITranscriptEventKinds: [EventKind] = [
    .userMessage,
    .assistantDone,
    .toolStarted,
    .toolFinished
]

private struct AgentTUIRuntime: @unchecked Sendable {
    var task: TaskRecord
    var storeOptions: StoreOptions
    var repoURL: URL
    var snapshot: RepositorySnapshot
    var store: any AgentTaskStore
    var model: AgentTUIModel
    var modelDisplayName: String
    var modelContextWindowTokens: Int64?
    var defaultBackend: AgentBackend
    var fullAuto: Bool
    var sandbox: String?
    var backendRunOptions: BackendRunOptions
}

private enum AgentTUIRuntimeBox {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: AgentTUIRuntime?

    static var current: AgentTUIRuntime? {
        get {
            lock.withLock { storage }
        }
        set {
            lock.withLock { storage = newValue }
        }
    }
}

private func updateAgentTUIRuntimeSnapshot(_ snapshot: RepositorySnapshot) {
    guard var runtime = AgentTUIRuntimeBox.current else {
        return
    }
    runtime.snapshot = snapshot
    AgentTUIRuntimeBox.current = runtime
}

private func updateAgentTUIRuntimeTask(_ task: TaskRecord) {
    guard var runtime = AgentTUIRuntimeBox.current else {
        return
    }
    let metadata = resolvedAgentModelMetadata(backend: task.backendPreference, options: runtime.backendRunOptions)
    runtime.task = task
    runtime.modelDisplayName = metadata.displayName
    runtime.modelContextWindowTokens = metadata.contextWindowTokens
    AgentTUIRuntimeBox.current = runtime
}

func runTUIkitInteractiveLoop(
    task: TaskRecord,
    taskPersisted: Bool,
    storeOptions: StoreOptions,
    repoURL: URL,
    snapshot: RepositorySnapshot,
    store: any AgentTaskStore,
    defaultBackend: AgentBackend,
    fullAuto: Bool,
    sandbox: String?,
    backendRunOptions: BackendRunOptions
) async throws {
    let initialEntries = taskPersisted ? try await tuiEntries(for: task.id, store: store) : []
    let modelMetadata = resolvedAgentModelMetadata(backend: task.backendPreference, options: backendRunOptions)
    let model = AgentTUIModel(task: task, isTaskPersisted: taskPersisted, entries: initialEntries.isEmpty ? [
        TUITranscriptEntry(role: .system, text: "Ready.")
    ] : initialEntries)
    let runtime = AgentTUIRuntime(
        task: task,
        storeOptions: storeOptions,
        repoURL: repoURL,
        snapshot: snapshot,
        store: store,
        model: model,
        modelDisplayName: modelMetadata.displayName,
        modelContextWindowTokens: modelMetadata.contextWindowTokens,
        defaultBackend: defaultBackend,
        fullAuto: fullAuto,
        sandbox: sandbox,
        backendRunOptions: backendRunOptions
    )

    let loop = AgentTUINativeLoop(model: model)
    model.setUpdateHandler {
        loop.requestRender()
    }
    AgentTUIRuntimeBox.current = runtime
    defer {
        model.setUpdateHandler(nil)
        AgentTUIRuntimeBox.current = nil
    }
    try await loop.run()
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
    let success = Color.rgb(134, 198, 134)  // Green for task success (✓)
    let warning = Color.rgb(201, 157, 74)
    let error = Color.rgb(219, 88, 88)       // Red for task failure (×)
    let info = Color.rgb(149, 168, 174)

    let border = Color.rgb(183, 170, 143)
    let focusBackground = Color.rgb(28, 27, 24)
    let cursorColor = Color.default
}

private enum TUITranscriptRole: String, Sendable {
    case user
    case assistant
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
    var isTaskPersisted: Bool
    var revision: Int
}

private struct TUITokenUsage: Sendable, Equatable {
    var inputTokens: Int64
    var outputTokens: Int64
    var reasoningTokens: Int64
    var contextWindowTokens: Int64?
}

struct AgentTUIInputLine: Equatable, Sendable {
    var start: Int
    var end: Int
    var text: String
}

struct AgentTUIComposerRow: Identifiable, Equatable, Sendable {
    var id: Int
    var before: String
    var cursorText: String?
    var after: String
    var hasCursor: Bool
}

private struct CodexModelMetadata: Sendable, Equatable {
    var displayName: String
    var contextWindowTokens: Int64?
}

private struct AgentTUIRunningOperation: Sendable {
    var task: _Concurrency.Task<Void, Never>
    var interruptHandle: AgentInterruptHandle?
    var cancelTaskOnInterrupt: Bool
}

private final class AgentTUIModel: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AgentTUISnapshot
    private var cacheClearedRevision = 0
    private var runningOperation: AgentTUIRunningOperation?
    private var updateHandler: (@Sendable () -> Void)?

    init(task: TaskRecord, isTaskPersisted: Bool = true, entries: [TUITranscriptEntry]) {
        state = AgentTUISnapshot(
            task: task,
            entries: entries,
            status: "ready",
            tokenUsage: nil,
            scrollOffset: 0,
            showRawEvents: false,
            isRunning: false,
            isTaskPersisted: isTaskPersisted,
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

    func setUpdateHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock {
            updateHandler = handler
        }
    }

    func append(_ role: TUITranscriptRole, _ text: String) {
        update { state in
            append(role, text, to: &state)
        }
    }

    func startTurn(prompt: String) -> (task: TaskRecord, isTaskPersisted: Bool)? {
        var turn: (task: TaskRecord, isTaskPersisted: Bool)?
        update { state in
            guard !state.isRunning else {
                return
            }
            append(.user, prompt, to: &state)
            state.isRunning = true
            state.status = "running \(state.task.backendPreference.rawValue) turn..."
            turn = (state.task, state.isTaskPersisted)
        }
        return turn
    }

    func finishTurn() {
        update { state in
            state.status = "ready"
            state.isRunning = false
        }
    }

    func startCommand(status: String) -> Bool {
        var started = false
        update { state in
            guard !state.isRunning else {
                return
            }
            state.isRunning = true
            state.status = status
            started = true
        }
        return started
    }

    func finishCommand(status: String = "ready") {
        update { state in
            state.status = status
            state.isRunning = false
        }
    }

    func failTurn(_ error: Error) {
        update { state in
            state.status = "turn failed"
            state.isRunning = false
            append(.error, agentctlErrorMessage(error), to: &state)
        }
    }

    func interruptOperation() {
        update { state in
            state.status = "interrupted"
            state.isRunning = false
            append(.system, "Interrupted.", to: &state)
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
            state.isRunning = false
            append(.error, agentctlErrorMessage(error), to: &state)
        }
    }

    func setRunningOperation(
        _ operation: _Concurrency.Task<Void, Never>,
        interruptHandle: AgentInterruptHandle? = nil,
        cancelTaskOnInterrupt: Bool = true
    ) {
        lock.withLock {
            if state.isRunning {
                runningOperation = AgentTUIRunningOperation(
                    task: operation,
                    interruptHandle: interruptHandle,
                    cancelTaskOnInterrupt: cancelTaskOnInterrupt
                )
            }
        }
    }

    func clearRunningOperation() {
        let interruptHandle = lock.withLock { () -> AgentInterruptHandle? in
            let interruptHandle = runningOperation?.interruptHandle
            runningOperation = nil
            return interruptHandle
        }
        interruptHandle?.clearAction()
    }

    func interruptRunningOperation() -> Bool {
        guard let operation = lock.withLock({ state.isRunning ? runningOperation : nil }) else {
            return false
        }

        let accepted: Bool
        if let interruptHandle = operation.interruptHandle {
            accepted = interruptHandle.requestInterrupt()
        } else if operation.cancelTaskOnInterrupt {
            operation.task.cancel()
            accepted = true
        } else {
            accepted = false
        }

        update { state in
            if accepted, state.status != "interrupting..." {
                state.status = "interrupting..."
                append(.system, "Interrupt requested.", to: &state)
            } else if !accepted {
                append(.error, "Current operation does not expose an interrupt channel.", to: &state)
            }
        }
        return true
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

    func markTaskPersisted(_ task: TaskRecord) {
        update { state in
            state.task = task
            state.isTaskPersisted = true
        }
    }

    func setTask(_ task: TaskRecord, isTaskPersisted: Bool = true, entries: [TUITranscriptEntry], message: String) {
        update { state in
            state.task = task
            state.isTaskPersisted = isTaskPersisted
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
                        append(.assistant, text, to: &state)
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
        var handler: (@Sendable () -> Void)?
        lock.withLock {
            body(&state)
            state.revision += 1
            handler = updateHandler
        }
        if let handler {
            handler()
        } else {
            AppState.shared.setNeedsRender()
            // TUIkit's runner owns a private AppState; SIGWINCH is its process-wide render wake-up.
            Darwin.raise(SIGWINCH)
        }
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

private enum AgentTUIQueuedInput: Sendable {
    case prompt(String)
    case command(String)
}

private final class AgentTUINativeLoop: @unchecked Sendable {
    private let model: AgentTUIModel
    private let renderSignal = AgentTUIRenderSignal()
    private let terminal = AgentTUINativeTerminal()
    private let queueLock = NSLock()
    private var input = ""
    private var inputCursor = 0
    private var promptHistory: [String] = []
    private var promptHistoryIndex: Int?
    private var promptHistoryDraft = ""
    private var queuedInputs: [AgentTUIQueuedInput] = []
    private var printedEntryKeys = Set<String>()
    private var hasPrintedTranscript = false
    private var composerLineCount = 0
    private let exitLock = NSLock()
    private var shouldExitStorage = false
    private var pendingImages: [AgentTUIDroppedFile] = []  // Images waiting to be sent with prompt

    private var shouldExit: Bool {
        get {
            exitLock.withLock { shouldExitStorage }
        }
        set {
            exitLock.withLock { shouldExitStorage = newValue }
        }
    }

    init(model: AgentTUIModel) {
        self.model = model
    }

    func requestRender() {
        renderSignal.mark()
    }

    func run() async throws {
        try terminal.enableRawMode()
        terminal.hideCursor()
        defer {
            clearComposer()
            terminal.disableRawMode()
            terminal.showCursor()
        }

        renderHeader()
        renderTranscriptAndComposer(forceTranscript: true)

        // Vsync-style rendering: 60fps frame timing (16ms), minimum 8ms between renders
        let minRenderInterval = 1.0 / 120.0  // Minimum time between actual renders (throttle)
        let spinnerInterval = 1.0 / 15.0  // Spinner animation at 15fps
        var lastRenderTime = Date()
        var nextSpinnerRender = Date.distantPast

        while !shouldExit {
            // Process all pending input events (up to 128 per frame)
            var eventsProcessed = 0
            while eventsProcessed < 128, let event = terminal.readKeyEvent() {
                _ = handleKey(event)
                eventsProcessed += 1
            }

            drainQueuedInputIfIdle()

            let now = Date()
            let timeSinceLastRender = now.timeIntervalSince(lastRenderTime)

            // Only render if enough time has passed (throttling to prevent flicker)
            if timeSinceLastRender >= minRenderInterval {
                if renderSignal.consume() {
                    renderTranscriptAndComposer()
                    lastRenderTime = now
                    nextSpinnerRender = now.addingTimeInterval(spinnerInterval)
                } else if shouldSpinActivity(model.snapshot()), now >= nextSpinnerRender {
                    renderComposerOnly()
                    lastRenderTime = now
                    nextSpinnerRender = now.addingTimeInterval(spinnerInterval)
                }
            }

            // Sleep for frame interval (60fps = ~16ms)
            usleep(16_000)
        }
    }

    private func renderHeader() {
        guard let runtime = AgentTUIRuntimeBox.current else {
            return
        }
        let snapshot = model.snapshot()
        let width = terminalSize().columns
        let left = agentTUIANSIStyled("agentctl", color: .palette.accent, isBold: false, isItalic: false, isUnderlined: false, palette: AgentTUIPalette())
        let slug = agentTUIANSIStyled(" \(snapshot.task.slug)", color: .palette.foregroundTertiary, isBold: false, isItalic: false, isUnderlined: false, palette: AgentTUIPalette())
        let store = shortStoreName(storeDescription(options: runtime.storeOptions, repoURL: runtime.repoURL, snapshot: runtime.snapshot))
        let plainLeft = "agentctl \(snapshot.task.slug)"
        let spaces = max(1, width - plainLeft.count - store.count)
        let right = agentTUIANSIStyled(store, color: .palette.foregroundTertiary, isBold: false, isItalic: false, isUnderlined: false, palette: AgentTUIPalette())
        terminal.write(left + slug + String(repeating: " ", count: spaces) + right + "\r\n")
        terminal.write(agentTUIANSIStyled(
            String(repeating: "─", count: max(1, width)),
            color: .palette.foregroundTertiary,
            isBold: false,
            isItalic: false,
            isUnderlined: false,
            palette: AgentTUIPalette()
        ) + "\r\n")
    }

    private func renderTranscriptAndComposer(forceTranscript: Bool = false) {
        let snapshot = model.snapshot()
        let width = max(40, terminalSize().columns)
        clearComposer()

        for entry in snapshot.entries {
            let key = transcriptRenderKey(entry)
            guard forceTranscript || !printedEntryKeys.contains(key) else {
                continue
            }
            printedEntryKeys.insert(key)

            if hasPrintedTranscript {
                terminal.write("\r\n")
            }
            hasPrintedTranscript = true

            for line in transcriptLines([entry], width: max(20, width - 4)) {
                terminal.write(agentTUIRenderedTranscriptRow(line, width: width, palette: AgentTUIPalette()) + "\r\n")
            }
        }

        drawComposer(snapshot: snapshot)
    }

    private func renderComposerOnly() {
        // Move cursor to composer start and redraw (overwrites old content)
        moveCursorToComposerStart()
        drawComposer(snapshot: model.snapshot())
    }

    private func moveCursorToComposerStart() {
        guard composerLineCount > 0 else {
            return
        }
        if composerLineCount > 1 {
            terminal.write("\u{1B}[\(composerLineCount - 1)F")
        } else {
            terminal.write("\r")
        }
    }

    private func clearComposer() {
        guard composerLineCount > 0 else {
            return
        }
        moveCursorToComposerStart()
        // Clear from cursor to end of screen
        terminal.write("\u{1B}[J")
        composerLineCount = 0
    }

    private func drawComposer(snapshot: AgentTUISnapshot) {
        let width = max(20, terminalSize().columns)
        let maxInputRows = max(1, min(8, terminalSize().rows / 3))
        let rows = agentTUIComposerRows(input: input, cursor: inputCursor, width: width, maxRows: maxInputRows)
        let palette = AgentTUIPalette()
        let lines = nativeComposerLines(snapshot: snapshot, rows: rows, width: width, palette: palette)

        for (index, line) in lines.enumerated() {
            terminal.write(paddedANSI(line, width: width))
            if index < lines.count - 1 {
                terminal.write("\r\n")
            }
        }
        composerLineCount = lines.count
    }

    private func nativeComposerLines(
        snapshot: AgentTUISnapshot,
        rows: [AgentTUIComposerRow],
        width: Int,
        palette: any Palette
    ) -> [String] {
        var lines: [String] = []
        lines.append("")
        lines.append(activityLine(snapshot, width: width, palette: palette))
        lines.append("")
        lines.append(agentTUIANSIStyled(
            agentTUIHorizontalDivider(label: modelDisplayName, width: width),
            color: .palette.foregroundTertiary,
            isBold: false,
            isItalic: false,
            isUnderlined: false,
            palette: palette
        ))
        // Show pending images indicator
        if !pendingImages.isEmpty {
            let imageNames = pendingImages.map { $0.name }.joined(separator: ", ")
            let countText = pendingImages.count == 1 ? "1 image" : "\(pendingImages.count) images"
            lines.append(agentTUIANSIStyled(
                "  🎎 \(countText) attached: \(imageNames)  [Esc to clear]",
                color: .palette.accent,
                isBold: false,
                isItalic: false,
                isUnderlined: false,
                palette: palette
            ))
        }
        for row in rows {
            lines.append(inputRow(row, palette: palette))
        }
        lines.append(agentTUIANSIStyled(
            agentTUIHorizontalDivider(label: nil, width: width),
            color: .palette.foregroundTertiary,
            isBold: false,
            isItalic: false,
            isUnderlined: false,
            palette: palette
        ))
        lines.append(agentTUIANSIStyled(
            statusLine(snapshot, width: width),
            color: .palette.foregroundTertiary,
            isBold: false,
            isItalic: false,
            isUnderlined: false,
            palette: palette
        ))
        return lines
    }

    private func activityLine(_ snapshot: AgentTUISnapshot, width: Int, palette: any Palette) -> String {
        guard shouldShowActivity(snapshot) else {
            return ""
        }

        let text = shouldSpinActivity(snapshot)
            ? "\(spinnerFrame()) \(activityText(snapshot))"
            : activityText(snapshot)
        let color = activityColor(snapshot)
        return " " + agentTUIANSIStyled(
            text,
            color: color,
            isBold: false,
            isItalic: false,
            isUnderlined: false,
            palette: palette
        )
    }

    private func spinnerFrame() -> String {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let tick = Int(Date().timeIntervalSinceReferenceDate * 12)
        return frames[((tick % frames.count) + frames.count) % frames.count]
    }

    private func inputRow(_ row: AgentTUIComposerRow, palette: any Palette) -> String {
        var line = ""
        if !row.before.isEmpty {
            line += agentTUIANSIStyled(
                row.before,
                color: .palette.foreground,
                isBold: false,
                isItalic: false,
                isUnderlined: false,
                palette: palette
            )
        }
        if row.hasCursor {
            line += agentTUIANSIStyled(
                row.cursorText ?? " ",
                color: .palette.foreground,
                isBold: false,
                isItalic: false,
                isUnderlined: false,
                isReversed: true,
                palette: palette
            )
        }
        if !row.after.isEmpty {
            line += agentTUIANSIStyled(
                row.after,
                color: .palette.foreground,
                isBold: false,
                isItalic: false,
                isUnderlined: false,
                palette: palette
            )
        }
        return line
    }

    private func paddedANSI(_ line: String, width: Int) -> String {
        let padding = max(0, width - line.strippedLength)
        return line + String(repeating: " ", count: padding)
    }

    private func transcriptRenderKey(_ entry: TUITranscriptEntry) -> String {
        "\(entry.id.uuidString)|\(entry.style)|\(entry.text)"
    }

    private func submitInput() {
        let text = input.trimmingCharacters(in: .newlines)
        let images = pendingImages
        input = ""
        inputCursor = 0
        promptHistoryIndex = nil
        promptHistoryDraft = ""
        pendingImages = []
        requestRender()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
            return
        }

        switch agentTUISubmission(for: text, backend: model.snapshot().task.backendPreference) {
        case let .agentctlCommand(command):
            guard !model.snapshot().isRunning else {
                enqueue(.command(text))
                return
            }
            handle(command)
        case let .backendPrompt(prompt):
            guard !model.snapshot().isRunning else {
                enqueue(.prompt(prompt))
                return
            }
            startPromptTurn(prompt, images: images)
        }
    }

    private func startPromptTurn(_ text: String, images: [AgentTUIDroppedFile] = []) {
        guard let turn = model.startTurn(prompt: text) else {
            enqueue(.prompt(text), atFront: true, announce: false)
            return
        }
        appendPromptHistory(text)

        guard let runtime = AgentTUIRuntimeBox.current else {
            model.failTurn(RuntimeError("TUI runtime is not available."))
            return
        }

        let model = model
        let interruptHandle = AgentInterruptHandle()
        // Convert dropped files to PiRPCImage format
        let rpcImages = images.map { PiRPCImage(data: $0.base64Data, mimeType: $0.mimeType) }
        let operation = _Concurrency.Task.detached {
            defer {
                model.clearRunningOperation()
            }
            do {
                let currentTask = turn.task
                try _Concurrency.Task.checkCancellation()
                if !turn.isTaskPersisted {
                    try await persistInteractiveTask(currentTask, store: runtime.store)
                    model.markTaskPersisted(currentTask)
                }
                _ = try await refreshResumeClaimIfActive(task: currentTask, store: runtime.store)
                _ = try await runAgentTurn(
                    task: currentTask,
                    prompt: text,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    store: runtime.store,
                    fullAuto: runtime.fullAuto,
                    sandbox: runtime.sandbox,
                    backendRunOptions: runtime.backendRunOptions,
                    images: rpcImages,
                    showStatus: false,
                    interruptHandle: interruptHandle
                ) { update in
                    model.render(update)
                }
                try _Concurrency.Task.checkCancellation()
                _ = try await refreshResumeClaimIfActive(task: currentTask, store: runtime.store)
                try _Concurrency.Task.checkCancellation()
                model.finishTurn()
            } catch is CancellationError {
                model.interruptOperation()
            } catch {
                if _Concurrency.Task.isCancelled {
                    model.interruptOperation()
                } else {
                    model.failTurn(error)
                }
            }
        }
        model.setRunningOperation(operation, interruptHandle: interruptHandle, cancelTaskOnInterrupt: false)
    }

    private func enqueue(
        _ queuedInput: AgentTUIQueuedInput,
        atFront: Bool = false,
        announce: Bool = true
    ) {
        let pending = queueLock.withLock { () -> Int in
            if atFront {
                queuedInputs.insert(queuedInput, at: 0)
            } else {
                queuedInputs.append(queuedInput)
            }
            return queuedInputs.count
        }

        guard announce else {
            return
        }

        switch queuedInput {
        case .prompt:
            model.append(.system, "Queued prompt (\(pending) pending).")
        case let .command(text):
            model.append(.system, "Queued \(queuedCommandLabel(text)) (\(pending) pending).")
        }
    }

    private func drainQueuedInputIfIdle() {
        guard !shouldExit, !model.snapshot().isRunning else {
            return
        }
        guard let queuedInput = queueLock.withLock({ queuedInputs.isEmpty ? nil : queuedInputs.removeFirst() }) else {
            return
        }

        switch queuedInput {
        case let .prompt(text):
            startPromptTurn(text)
        case let .command(text):
            switch agentTUISubmission(for: text, backend: model.snapshot().task.backendPreference) {
            case let .agentctlCommand(command):
                handle(command)
            case let .backendPrompt(prompt):
                startPromptTurn(prompt)
            }
        }
    }

    private func queuedCommandLabel(_ text: String) -> String {
        guard let command = SlashCommand(text) else {
            return "command"
        }
        return "/\(command.name)"
    }

    private func handle(_ command: SlashCommand) {
        guard let runtime = AgentTUIRuntimeBox.current else {
            model.append(.error, "TUI runtime is not available.")
            return
        }
        let model = self.model

        switch command.name {
        case "exit", "quit":
            releaseClaimThenExit()
        case "help":
            model.append(.system, "/help /info /tasks /new [title] /resume <task> [--checkpoint <id|latest>] [--force] /checkpoint [--push] /checkpoints /artifacts /continue [path] /release /export [path] /events /raw /exit\nUnknown /... commands are sent to Codex for Codex-backed tasks. Use //... to send /... to the backend.")
        case "raw":
            _ = model.toggleRawEvents()
        case "info", "task", "repo":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
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
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "loading events...") {
                let events = try await runtime.store.events(for: task.id)
                model.append(.system, tuiEvents(events))
                model.setStatus("ready")
            }
        case "checkpoints":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "loading checkpoints...") {
                let checkpoints = try await runtime.store.listCheckpoints(taskID: task.id)
                model.append(.system, tuiCheckpoints(checkpoints))
                model.setStatus("ready")
            }
        case "artifacts":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "loading artifacts...") {
                let artifacts = try await runtime.store.listArtifacts(taskID: task.id)
                model.append(.system, tuiArtifacts(artifacts))
                model.setStatus("ready")
            }
        case "continue":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "writing continuation bundle...") {
                let result = try await exportContinuationMarkdown(
                    task: task,
                    store: runtime.store,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    destination: command.argument
                )
                model.append(.system, "Continuation bundle written to \(result.url.path).")
                model.setStatus("ready")
            }
        case "release":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "releasing claim...") {
                let result = try await releaseResumeClaim(task: task, store: runtime.store)
                model.append(.system, result.released ? "Claim released." : "No active claim for this machine.")
                model.setStatus("ready")
            }
        case "export":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "exporting transcript...") {
                let result = try await exportTranscriptMarkdown(
                    task: task,
                    store: runtime.store,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    destination: command.argument
                )
                model.append(.system, "Exported \(result.eventCount) events to \(result.url.path).")
                model.setStatus("ready")
            }
        case "checkpoint":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "creating checkpoint...") {
                let options = try checkpointSlashOptions(command.argument)
                let result = try await createAndPersistCheckpoint(
                    task: task,
                    store: runtime.store,
                    snapshot: runtime.snapshot,
                    repoURL: runtime.repoURL,
                    options: options,
                    onStatus: { status in model.setStatus(status) }
                )
                let updatedSnapshot = try RepositoryInspector().inspect(path: runtime.repoURL)
                updateAgentTUIRuntimeSnapshot(updatedSnapshot)
                model.append(.system, checkpointCreatedStatus(result))
                model.setStatus("ready")
            }
        case "new":
            runCommand(status: "creating task...") {
                let newTask = try await resolveInteractiveTask(
                    identifier: nil,
                    title: command.argument?.isEmpty == false ? command.argument : nil,
                    backend: runtime.defaultBackend,
                    snapshot: runtime.snapshot,
                    repoURL: runtime.repoURL,
                    store: runtime.store
                )
                updateAgentTUIRuntimeTask(newTask)
                model.setTask(newTask, entries: [], message: "Created task \(newTask.slug).")
            }
        case "resume":
            let resume: ResumeSlashOptions
            do {
                resume = try resumeSlashOptions(command.argument)
            } catch {
                model.append(.error, String(describing: error))
                return
            }
            guard !resume.taskIdentifier.isEmpty else {
                model.append(.error, "usage: /resume <task> [--checkpoint <id|latest>] [--force]")
                return
            }
            runCommand(status: "resuming task...") {
                let resumedTask = try await runtime.store.findTask(resume.taskIdentifier)
                let handoff = try await prepareResumeHandoff(
                    task: resumedTask,
                    store: runtime.store,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    checkpointSelector: resume.checkpointSelector,
                    forceClaim: resume.forceClaim,
                    onStatus: { status in model.setStatus(status) }
                )
                if handoff.restore != nil {
                    model.setStatus("inspecting restored repo...")
                    let updatedSnapshot = try RepositoryInspector().inspect(path: runtime.repoURL)
                    updateAgentTUIRuntimeSnapshot(updatedSnapshot)
                }
                model.setStatus("loading recent transcript...")
                let loadedEntries = try await tuiEntries(for: resumedTask.id, store: runtime.store)
                updateAgentTUIRuntimeTask(resumedTask)
                var message = "Resumed task \(resumedTask.slug)."
                if let restore = handoff.restore {
                    message += "\n\(tuiCheckpointRestoreDetails(restore, claim: handoff.claim))"
                } else {
                    message += "\n\(taskClaimStatus(handoff.claim))"
                }
                model.setTask(resumedTask, entries: loadedEntries, message: message)
                model.setStatus(handoff.restore.map(checkpointRestoreStatus) ?? taskClaimStatus(handoff.claim))
            }
        default:
            model.append(.error, "unknown command: /\(command.name)")
        }
    }

    private func releaseClaimThenExit() {
        guard let runtime = AgentTUIRuntimeBox.current else {
            shouldExit = true
            return
        }
        let snapshot = model.snapshot()
        guard snapshot.isTaskPersisted else {
            shouldExit = true
            return
        }

        let task = snapshot.task
        let ownerName = currentClaimOwnerName()
        model.setStatus("releasing claim...")
        _Concurrency.Task.detached {
            _ = try? await runtime.store.releaseTaskClaim(taskID: task.id, ownerName: ownerName)
        }
        shouldExit = true
    }

    private func runCommand(status newStatus: String, operation: @escaping @Sendable () async throws -> Void) {
        guard model.startCommand(status: newStatus) else {
            return
        }
        let model = model
        let runningOperation = _Concurrency.Task.detached {
            defer {
                model.clearRunningOperation()
            }
            do {
                try _Concurrency.Task.checkCancellation()
                try await operation()
                try _Concurrency.Task.checkCancellation()
                model.finishCommand()
            } catch is CancellationError {
                model.interruptOperation()
            } catch {
                if _Concurrency.Task.isCancelled {
                    model.interruptOperation()
                } else {
                    model.commandFailed(error)
                }
            }
        }
        model.setRunningOperation(runningOperation)
    }

    private func handleKey(_ event: KeyEvent) -> Bool {
        // Check for file drop (OSC 1337)
        let inputEvent = AgentTUIInputEvent.from(keyEvent: event)
        if let file = inputEvent.droppedFile {
            // Add to pending images
            pendingImages.append(file)
            requestRender()
            return true
        }

        switch event.key {
        case .enter where event.shift || event.alt:
            insertInput("\n")
            return true
        case .enter:
            submitInput()
            return true
        case .escape:
            // Clear pending images on escape
            if !pendingImages.isEmpty {
                pendingImages = []
                requestRender()
                return true
            }
            if model.interruptRunningOperation() {
                return true
            }
            releaseClaimThenExit()
            return true
        case .character("c") where event.ctrl:
            if model.interruptRunningOperation() {
                return true
            }
            releaseClaimThenExit()
            return true
        case .character("a") where event.ctrl:
            moveToBeginningOfInputLine()
            return true
        case .character("e") where event.ctrl:
            moveToEndOfInputLine()
            return true
        case .character("b") where event.ctrl:
            moveInputCursorBackward()
            return true
        case .character("f") where event.ctrl:
            moveInputCursorForward()
            return true
        case .character("w") where event.ctrl:
            killInputWordBackward()
            return true
        case .character("k") where event.ctrl:
            killInputLineForward()
            return true
        case .character("p") where event.ctrl:
            moveInputLineOrHistory(delta: -1)
            return true
        case .character("n") where event.ctrl:
            moveInputLineOrHistory(delta: 1)
            return true
        case .backspace where event.alt:
            killInputWordBackward()
            return true
        case .backspace:
            deleteInputBackward()
            return true
        case .delete:
            deleteInputForward()
            return true
        case .left:
            inputCursor = max(0, inputCursor - 1)
            requestRender()
            return true
        case .right:
            inputCursor = min(input.count, inputCursor + 1)
            requestRender()
            return true
        case .up:
            inputCursor = agentTUIMoveCursorUp(lines: agentTUIInputLines(input), cursor: inputCursor)
            requestRender()
            return true
        case .down:
            inputCursor = agentTUIMoveCursorDown(lines: agentTUIInputLines(input), cursor: inputCursor)
            requestRender()
            return true
        case .home:
            inputCursor = 0
            requestRender()
            return true
        case .end:
            inputCursor = input.count
            requestRender()
            return true
        case .space where !event.ctrl && !event.alt:
            insertInput(" ")
            return true
        case .paste(let text):
            insertInput(text)
            return true
        case .character(let character) where !event.ctrl && !event.alt:
            insertInput(String(character))
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
        resetPromptHistorySelectionForEdit()
        requestRender()
    }

    private func deleteInputBackward() {
        guard inputCursor > 0 else {
            return
        }
        let cursor = min(inputCursor, input.count)
        let index = input.index(input.startIndex, offsetBy: cursor - 1)
        input.remove(at: index)
        inputCursor = cursor - 1
        resetPromptHistorySelectionForEdit()
        requestRender()
    }

    private func deleteInputForward() {
        guard inputCursor < input.count else {
            return
        }
        let cursor = min(inputCursor, input.count)
        let index = input.index(input.startIndex, offsetBy: cursor)
        input.remove(at: index)
        inputCursor = cursor
        resetPromptHistorySelectionForEdit()
        requestRender()
    }

    private func moveInputCursorBackward() {
        inputCursor = max(0, inputCursor - 1)
        requestRender()
    }

    private func moveInputCursorForward() {
        inputCursor = min(input.count, inputCursor + 1)
        requestRender()
    }

    private func moveToBeginningOfInputLine() {
        let lines = agentTUIInputLines(input)
        let index = agentTUIInputLineIndex(lines: lines, cursor: inputCursor)
        inputCursor = lines[index].start
        requestRender()
    }

    private func moveToEndOfInputLine() {
        let lines = agentTUIInputLines(input)
        let index = agentTUIInputLineIndex(lines: lines, cursor: inputCursor)
        inputCursor = lines[index].end
        requestRender()
    }

    private func moveInputLineOrHistory(delta: Int) {
        let lines = agentTUIInputLines(input)
        let lineIndex = agentTUIInputLineIndex(lines: lines, cursor: inputCursor)
        if delta < 0, lineIndex == 0 {
            recallPreviousPrompt()
            return
        }
        if delta > 0, lineIndex == lines.count - 1 {
            recallNextPrompt()
            return
        }

        let targetIndex = min(max(0, lineIndex + delta), lines.count - 1)
        let column = max(0, inputCursor - lines[lineIndex].start)
        let target = lines[targetIndex]
        inputCursor = target.start + min(column, target.end - target.start)
        requestRender()
    }

    private func killInputWordBackward() {
        guard inputCursor > 0 else {
            return
        }
        let characters = Array(input)
        let cursor = min(inputCursor, characters.count)
        var start = cursor

        while start > 0, characters[start - 1].isWhitespace {
            start -= 1
        }
        while start > 0, !characters[start - 1].isWhitespace {
            start -= 1
        }

        guard start < cursor else {
            return
        }
        var edited = characters
        edited.removeSubrange(start..<cursor)
        input = String(edited)
        inputCursor = start
        resetPromptHistorySelectionForEdit()
        requestRender()
    }

    private func killInputLineForward() {
        let result = agentTUIKillToEndOfLine(input: input, cursor: inputCursor)
        guard result.input != input else {
            return
        }
        input = result.input
        inputCursor = result.cursor
        resetPromptHistorySelectionForEdit()
        requestRender()
    }

    private func appendPromptHistory(_ prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if promptHistory.last != prompt {
            promptHistory.append(prompt)
        }
    }

    private func recallPreviousPrompt() {
        guard !promptHistory.isEmpty else {
            return
        }
        if promptHistoryIndex == nil {
            promptHistoryDraft = input
            promptHistoryIndex = promptHistory.count - 1
        } else if let index = promptHistoryIndex, index > 0 {
            promptHistoryIndex = index - 1
        }
        loadPromptHistorySelection()
    }

    private func recallNextPrompt() {
        guard let index = promptHistoryIndex else {
            return
        }
        if index < promptHistory.count - 1 {
            promptHistoryIndex = index + 1
            loadPromptHistorySelection()
        } else {
            promptHistoryIndex = nil
            input = promptHistoryDraft
            inputCursor = input.count
            promptHistoryDraft = ""
            requestRender()
        }
    }

    private func loadPromptHistorySelection() {
        guard let index = promptHistoryIndex, promptHistory.indices.contains(index) else {
            return
        }
        input = promptHistory[index]
        inputCursor = input.count
        requestRender()
    }

    private func resetPromptHistorySelectionForEdit() {
        promptHistoryIndex = nil
        promptHistoryDraft = ""
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
            return snapshot.status == "ready" ? "Working..." : snapshot.status
        }
        return snapshot.status
    }

    private func activityColor(_ snapshot: AgentTUISnapshot) -> Color {
        if snapshot.status.hasPrefix("turn failed") || snapshot.status.hasPrefix("command failed") {
            return .palette.error
        }
        return .palette.foregroundTertiary
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
}

private final class AgentTUIRenderSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var needsRender = false

    func mark() {
        lock.withLock {
            needsRender = true
        }
    }

    func consume() -> Bool {
        lock.withLock {
            let value = needsRender
            needsRender = false
            return value
        }
    }
}

#if os(Linux)
private typealias AgentTUITermFlag = UInt32
#else
private typealias AgentTUITermFlag = UInt
#endif

private final class AgentTUINativeTerminal: @unchecked Sendable {
    private var originalTermios: termios?
    private var isRawMode = false

    func enableRawMode() throws {
        guard !isRawMode else {
            return
        }

        var raw = termios()
        guard tcgetattr(STDIN_FILENO, &raw) == 0 else {
            throw RuntimeError("failed to read terminal settings")
        }
        originalTermios = raw

        raw.c_lflag &= ~AgentTUITermFlag(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~AgentTUITermFlag(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~AgentTUITermFlag(OPOST)
        raw.c_cflag |= AgentTUITermFlag(CS8)

        withUnsafeMutablePointer(to: &raw.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { buffer in
                buffer[Int(VMIN)] = 0
                buffer[Int(VTIME)] = 0
            }
        }

        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            throw RuntimeError("failed to enable terminal raw mode")
        }
        isRawMode = true
        write("\u{1B}[?2004h")
    }

    func disableRawMode() {
        guard isRawMode, var originalTermios else {
            return
        }
        write("\u{1B}[?2004l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        isRawMode = false
    }

    func hideCursor() {
        write("\u{1B}[?25l")
    }

    func showCursor() {
        write("\u{1B}[?25h")
    }

    func write(_ string: String) {
        string.utf8CString.withUnsafeBufferPointer { buffer in
            let count = buffer.count - 1
            guard count > 0, let baseAddress = buffer.baseAddress else {
                return
            }
            baseAddress.withMemoryRebound(to: UInt8.self, capacity: count) { pointer in
                var written = 0
                while written < count {
                    let result = Foundation.write(STDOUT_FILENO, pointer + written, count - written)
                    if result <= 0 {
                        break
                    }
                    written += result
                }
            }
        }
    }

    func readKeyEvent() -> KeyEvent? {
        let bytes = readBytes()
        guard !bytes.isEmpty else {
            return nil
        }

        // Bracketed paste start: ESC [ 200 ~
        if bytes == [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] {
            return KeyEvent(key: .paste(readBracketedPasteContent()))
        }

        // OSC sequence (ESC ]): Check for iTerm2/Ghostty file drop
        // Format: ESC ] 1337 ; File=name=<base64>;size=<bytes>:[<base64content>] BEL
        if bytes.count >= 2 && bytes[0] == 0x1B && bytes[1] == 0x5D {
            return parseOSCSequence(bytes)
        }

        return KeyEvent.parse(bytes)
    }

    /// Parse OSC sequence for iTerm2/Ghostty file drop support.
    private func parseOSCSequence(_ initialBytes: [UInt8]) -> KeyEvent? {
        // OSC format: ESC ] <command> ; <params> BEL (or ESC \ for ST terminator)
        // We've already read ESC ], now read until BEL (0x07) or ST (ESC \)
        var content: [UInt8] = []
        var prevByte: UInt8 = 0
        let maxOSCBytes = 1024 * 1024  // 1MB max for file drops

        while content.count < maxOSCBytes {
            var byte = [UInt8](repeating: 0, count: 1)
            let bytesRead = read(STDIN_FILENO, &byte, 1)
            guard bytesRead > 0 else {
                usleep(1_000)
                continue
            }

            // BEL (0x07) terminates OSC
            if byte[0] == 0x07 {
                break
            }

            // ST (ESC \) terminates OSC
            if prevByte == 0x1B && byte[0] == 0x5C {
                content.removeLast()  // Remove the ESC
                break
            }

            content.append(byte[0])
            prevByte = byte[0]
        }

        // Parse OSC content
        let oscString = String(bytes: content, encoding: .utf8) ?? ""

        // Check for iTerm2 file drop: "1337;File=..."
        if oscString.hasPrefix("1337;File=") {
            return parseOSC1337File(oscString)
        }

        // Unknown OSC - return as paste with raw content
        return KeyEvent(key: .paste(oscString))
    }

    /// Parse iTerm2 OSC 1337 File sequence.
    /// Format: 1337;File=name=<base64name>;size=<bytes>:[<base64content>]
    private func parseOSC1337File(_ oscContent: String) -> KeyEvent? {
        // Remove "1337;File=" prefix
        let params = oscContent.dropFirst(10)

        // Parse parameters: name=...;size=...:content
        var name: String?
        var size: Int?
        var base64Content: String?

        // Split by ':' to separate params from content
        let colonIndex = params.firstIndex(of: ":") ?? params.endIndex
        let paramPart = params[..<colonIndex]
        let contentPart = colonIndex < params.endIndex ? params[params.index(after: colonIndex)...] : ""

        // Parse semicolon-separated parameters
        for param in paramPart.split(separator: ";") {
            let keyValue = param.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 {
                let key = String(keyValue[0])
                let value = String(keyValue[1])
                switch key {
                case "name":
                    // name is base64-encoded
                    if let decodedData = Data(base64Encoded: value),
                       let decodedName = String(data: decodedData, encoding: .utf8) {
                        name = decodedName
                    } else {
                        name = value  // Fall back to raw value
                    }
                case "size":
                    size = Int(value)
                case "type":
                    // MIME type provided directly
                    // We'll use filename inference instead for simplicity
                    break
                default:
                    break
                }
            }
        }

        // Content is after the colon
        base64Content = String(contentPart)

        guard let finalName = name, let finalData = base64Content, !finalData.isEmpty else {
            return nil
        }

        // Encode as JSON for AgentTUIDroppedFile to parse
        let mimeType = AgentTUIDroppedFile.mimeTypeForFilename(finalName)
        let jsonPayload: [String: Any] = [
            "name": finalName,
            "mimeType": mimeType,
            "data": finalData,
            "size": size ?? 0
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonPayload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        // Wrap in special marker for detection
        return KeyEvent(key: .paste("{_osc1337:" + jsonString + "}"))
    }

    private func readBytes(maxBytes: Int = 8) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 1)
        let bytesRead = read(STDIN_FILENO, &buffer, 1)
        guard bytesRead > 0 else {
            return []
        }

        guard buffer[0] == 0x1B else {
            return [buffer[0]]
        }

        var result: [UInt8] = [0x1B]
        var nextByte = [UInt8](repeating: 0, count: 1)
        let nextRead = read(STDIN_FILENO, &nextByte, 1)
        guard nextRead > 0 else {
            return result
        }
        result.append(nextByte[0])

        if nextByte[0] == 0x5B {
            for _ in 0..<(maxBytes - 2) {
                let paramRead = read(STDIN_FILENO, &nextByte, 1)
                guard paramRead > 0 else {
                    break
                }
                result.append(nextByte[0])
                if nextByte[0] >= 0x40 && nextByte[0] <= 0x7E {
                    break
                }
            }
        } else if nextByte[0] == 0x4F {
            let funcRead = read(STDIN_FILENO, &nextByte, 1)
            if funcRead > 0 {
                result.append(nextByte[0])
            }
        }
        // Note: OSC (ESC ]) is handled separately in readKeyEvent()

        return result
    }

    private func readBracketedPasteContent() -> String {
        var content: [UInt8] = []
        let endMarker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        let maxPasteBytes = 65_536

        while content.count < maxPasteBytes {
            var byte = [UInt8](repeating: 0, count: 1)
            let bytesRead = read(STDIN_FILENO, &byte, 1)
            guard bytesRead > 0 else {
                usleep(1_000)
                continue
            }

            content.append(byte[0])
            if content.count >= endMarker.count, Array(content.suffix(endMarker.count)) == endMarker {
                content.removeLast(endMarker.count)
                break
            }
        }

        return String(bytes: content, encoding: .utf8) ?? String(content.map { Character(UnicodeScalar($0)) })
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
    @State private var promptHistory: [String] = []
    @State private var promptHistoryIndex: Int?
    @State private var promptHistoryDraft = ""

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
        let maxInputRows = max(1, min(8, size.rows / 3))
        let inputRows = agentTUIComposerRows(
            input: input,
            cursor: inputCursor,
            width: max(20, size.columns),
            maxRows: maxInputRows
        ).count
        let composerHeight = 6 + inputRows
        let transcriptHeight = max(3, size.rows - 2 - composerHeight)
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
            composer(
                snapshot,
                terminalWidth: size.columns,
                maxInputRows: maxInputRows
            )
            .frame(height: composerHeight, alignment: .bottomLeading)
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
        terminalWidth: Int,
        maxInputRows: Int
    ) -> some View {
        let width = max(20, terminalWidth)

        return VStack(alignment: .leading, spacing: 0) {
            Text("").frame(width: width)
            activityLine(snapshot, width: width)
            Text("").frame(width: width)
            dividerLine(label: modelDisplayName, width: width)
            inputBlock(width: width, maxRows: maxInputRows)
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

    private func inputBlock(width: Int, maxRows: Int) -> some View {
        let rows = agentTUIComposerRows(
            input: input,
            cursor: inputCursor,
            width: width,
            maxRows: maxRows
        )

        return VStack(alignment: .leading, spacing: 0) {
            ViewArray(rows.map { inputRow($0, width: width) })
        }
        .frame(width: width, height: rows.count, alignment: .topLeading)
    }

    private func inputRow(_ row: AgentTUIComposerRow, width: Int) -> AnyView {
        AnyView(
            HStack(spacing: 0) {
                if !row.before.isEmpty {
                    Text(row.before).foregroundStyle(.palette.foreground)
                }
                if row.hasCursor {
                    Text(row.cursorText ?? " ")
                        .foregroundStyle(.palette.background)
                        .background(.palette.foreground)
                }
                if !row.after.isEmpty {
                    Text(row.after).foregroundStyle(.palette.foreground)
                }
                Spacer(minLength: 0)
            }
            .frame(width: width)
        )
    }

    private func composerStatus(
        _ snapshot: AgentTUISnapshot,
        width: Int
    ) -> some View {
        Text(statusLine(snapshot, width: width))
            .foregroundStyle(.palette.foregroundTertiary)
    }

    private func transcriptLine(_ line: TUITranscriptLine) -> AnyView {
        AnyView(AgentTUITranscriptRow(line: line))
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
            return snapshot.status == "ready" ? "Working..." : snapshot.status
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
        let text = input.trimmingCharacters(in: .newlines)
        input = ""
        inputCursor = 0
        promptHistoryIndex = nil
        promptHistoryDraft = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        switch agentTUISubmission(for: text, backend: model.snapshot().task.backendPreference) {
        case let .agentctlCommand(command):
            handle(command)
            return
        case let .backendPrompt(prompt):
            startPromptTurn(prompt)
        }
    }

    private func startPromptTurn(_ prompt: String) {
        guard let turn = model.startTurn(prompt: prompt) else {
            return
        }
        appendPromptHistory(prompt)

        guard let runtime = AgentTUIRuntimeBox.current else {
            model.failTurn(RuntimeError("TUI runtime is not available."))
            return
        }

        let model = model
        let interruptHandle = AgentInterruptHandle()
        let operation = _Concurrency.Task.detached {
            defer {
                model.clearRunningOperation()
            }
            do {
                let currentTask = turn.task
                try _Concurrency.Task.checkCancellation()
                if !turn.isTaskPersisted {
                    try await persistInteractiveTask(currentTask, store: runtime.store)
                    model.markTaskPersisted(currentTask)
                }
                _ = try await refreshResumeClaimIfActive(task: currentTask, store: runtime.store)
                _ = try await runAgentTurn(
                    task: currentTask,
                    prompt: prompt,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    store: runtime.store,
                    fullAuto: runtime.fullAuto,
                    sandbox: runtime.sandbox,
                    backendRunOptions: runtime.backendRunOptions,
                    showStatus: false,
                    interruptHandle: interruptHandle
                ) { update in
                    model.render(update)
                }
                try _Concurrency.Task.checkCancellation()
                _ = try await refreshResumeClaimIfActive(task: currentTask, store: runtime.store)
                try _Concurrency.Task.checkCancellation()
                model.finishTurn()
            } catch is CancellationError {
                model.interruptOperation()
            } catch {
                if _Concurrency.Task.isCancelled {
                    model.interruptOperation()
                } else {
                    model.failTurn(error)
                }
            }
        }
        model.setRunningOperation(operation, interruptHandle: interruptHandle, cancelTaskOnInterrupt: false)
    }

    private func handle(_ command: SlashCommand) {
        guard let runtime = AgentTUIRuntimeBox.current else {
            model.append(.error, "TUI runtime is not available.")
            return
        }

        switch command.name {
        case "exit", "quit":
            releaseClaimThenExit()
        case "help":
            model.append(.system, "/help /info /tasks /new [title] /resume <task> [--checkpoint <id|latest>] [--force] /checkpoint [--push] /checkpoints /artifacts /continue [path] /release /export [path] /events /raw /exit\nUnknown /... commands are sent to Codex for Codex-backed tasks. Use //... to send /... to the backend.")
        case "raw":
            _ = model.toggleRawEvents()
        case "info", "task", "repo":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
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
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "loading events...") {
                let events = try await runtime.store.events(for: task.id)
                model.append(.system, tuiEvents(events))
                model.setStatus("ready")
            }
        case "checkpoints":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "loading checkpoints...") {
                let checkpoints = try await runtime.store.listCheckpoints(taskID: task.id)
                model.append(.system, tuiCheckpoints(checkpoints))
                model.setStatus("ready")
            }
        case "artifacts":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "loading artifacts...") {
                let artifacts = try await runtime.store.listArtifacts(taskID: task.id)
                model.append(.system, tuiArtifacts(artifacts))
                model.setStatus("ready")
            }
        case "continue":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "writing continuation bundle...") {
                let result = try await exportContinuationMarkdown(
                    task: task,
                    store: runtime.store,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    destination: command.argument
                )
                model.append(.system, "Continuation bundle written to \(result.url.path).")
                model.setStatus("ready")
            }
        case "release":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "releasing claim...") {
                let result = try await releaseResumeClaim(task: task, store: runtime.store)
                model.append(.system, result.released ? "Claim released." : "No active claim for this machine.")
                model.setStatus("ready")
            }
        case "export":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "exporting transcript...") {
                let result = try await exportTranscriptMarkdown(
                    task: task,
                    store: runtime.store,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    destination: command.argument
                )
                model.append(.system, "Exported \(result.eventCount) events to \(result.url.path).")
                model.setStatus("ready")
            }
        case "checkpoint":
            let snapshot = model.snapshot()
            guard snapshot.isTaskPersisted else {
                model.append(.system, "No persisted task yet. Send a prompt, /new [title], or /resume <task>.")
                return
            }
            let task = snapshot.task
            runCommand(status: "creating checkpoint...") {
                let options = try checkpointSlashOptions(command.argument)
                let result = try await createAndPersistCheckpoint(
                    task: task,
                    store: runtime.store,
                    snapshot: runtime.snapshot,
                    repoURL: runtime.repoURL,
                    options: options,
                    onStatus: { status in model.setStatus(status) }
                )
                let updatedSnapshot = try RepositoryInspector().inspect(path: runtime.repoURL)
                updateAgentTUIRuntimeSnapshot(updatedSnapshot)
                model.append(.system, checkpointCreatedStatus(result))
                model.setStatus("ready")
            }
        case "new":
            runCommand(status: "creating task...") {
                let newTask = try await resolveInteractiveTask(
                    identifier: nil,
                    title: command.argument?.isEmpty == false ? command.argument : nil,
                    backend: runtime.defaultBackend,
                    snapshot: runtime.snapshot,
                    repoURL: runtime.repoURL,
                    store: runtime.store
                )
                updateAgentTUIRuntimeTask(newTask)
                model.setTask(newTask, entries: [], message: "Created task \(newTask.slug).")
            }
        case "resume":
            let resume: ResumeSlashOptions
            do {
                resume = try resumeSlashOptions(command.argument)
            } catch {
                model.append(.error, String(describing: error))
                return
            }
            guard !resume.taskIdentifier.isEmpty else {
                model.append(.error, "usage: /resume <task> [--checkpoint <id|latest>] [--force]")
                return
            }
            runCommand(status: "resuming task...") {
                let resumedTask = try await runtime.store.findTask(resume.taskIdentifier)
                let handoff = try await prepareResumeHandoff(
                    task: resumedTask,
                    store: runtime.store,
                    repoURL: runtime.repoURL,
                    snapshot: runtime.snapshot,
                    checkpointSelector: resume.checkpointSelector,
                    forceClaim: resume.forceClaim,
                    onStatus: { status in model.setStatus(status) }
                )
                if handoff.restore != nil {
                    model.setStatus("inspecting restored repo...")
                    let updatedSnapshot = try RepositoryInspector().inspect(path: runtime.repoURL)
                    updateAgentTUIRuntimeSnapshot(updatedSnapshot)
                }
                model.setStatus("loading recent transcript...")
                let loadedEntries = try await tuiEntries(for: resumedTask.id, store: runtime.store)
                updateAgentTUIRuntimeTask(resumedTask)
                var message = "Resumed task \(resumedTask.slug)."
                if let restore = handoff.restore {
                    message += "\n\(tuiCheckpointRestoreDetails(restore, claim: handoff.claim))"
                } else {
                    message += "\n\(taskClaimStatus(handoff.claim))"
                }
                model.setTask(resumedTask, entries: loadedEntries, message: message)
                model.setStatus(handoff.restore.map(checkpointRestoreStatus) ?? taskClaimStatus(handoff.claim))
            }
        default:
            model.append(.error, "unknown command: /\(command.name)")
        }
    }

    private func releaseClaimThenExit() {
        guard let runtime = AgentTUIRuntimeBox.current else {
            Darwin.raise(SIGINT)
            return
        }
        let snapshot = model.snapshot()
        guard snapshot.isTaskPersisted else {
            Darwin.raise(SIGINT)
            return
        }

        let task = snapshot.task
        model.setStatus("releasing claim...")
        _Concurrency.Task.detached {
            _ = try? await releaseResumeClaim(task: task, store: runtime.store)
            Darwin.raise(SIGINT)
        }
    }

    private func runCommand(status newStatus: String, operation: @escaping @Sendable () async throws -> Void) {
        guard model.startCommand(status: newStatus) else {
            return
        }
        let model = model
        let runningOperation = _Concurrency.Task.detached {
            defer {
                model.clearRunningOperation()
            }
            do {
                try _Concurrency.Task.checkCancellation()
                try await operation()
                try _Concurrency.Task.checkCancellation()
                model.finishCommand()
            } catch is CancellationError {
                model.interruptOperation()
            } catch {
                if _Concurrency.Task.isCancelled {
                    model.interruptOperation()
                } else {
                    model.commandFailed(error)
                }
            }
        }
        model.setRunningOperation(runningOperation)
    }

    private func handleKey(_ event: KeyEvent, pageSize: Int, maxScrollOffset: Int) -> Bool {
        switch event.key {
        case .enter where event.shift || event.alt:
            insertInput("\n")
            return true
        case .enter:
            submitInput()
            return true
        case .escape:
            if model.interruptRunningOperation() {
                return true
            }
            releaseClaimThenExit()
            return true
        case .character("c") where event.ctrl:
            releaseClaimThenExit()
            return true
        case .character("a") where event.ctrl:
            moveToBeginningOfInputLine()
            return true
        case .character("e") where event.ctrl:
            moveToEndOfInputLine()
            return true
        case .character("b") where event.ctrl:
            moveInputCursorBackward()
            return true
        case .character("f") where event.ctrl:
            moveInputCursorForward()
            return true
        case .character("w") where event.ctrl:
            killInputWordBackward()
            return true
        case .character("k") where event.ctrl:
            killInputLineForward()
            return true
        case .character("p") where event.ctrl:
            moveInputLineOrHistory(delta: -1)
            return true
        case .character("n") where event.ctrl:
            moveInputLineOrHistory(delta: 1)
            return true
        case .character("u") where event.ctrl:
            model.adjustScroll(-pageSize, maxOffset: maxScrollOffset)
            return true
        case .character("d") where event.ctrl:
            model.adjustScroll(pageSize, maxOffset: maxScrollOffset)
            return true
        case .backspace where event.alt:
            killInputWordBackward()
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
        case .up where event.ctrl:
            model.adjustScroll(1, maxOffset: maxScrollOffset)
            return true
        case .down where event.ctrl:
            model.adjustScroll(-1, maxOffset: maxScrollOffset)
            return true
        case .up:
            inputCursor = agentTUIMoveCursorUp(lines: agentTUIInputLines(input), cursor: inputCursor)
            return true
        case .down:
            inputCursor = agentTUIMoveCursorDown(lines: agentTUIInputLines(input), cursor: inputCursor)
            return true
        case .pageUp:
            model.adjustScroll(-pageSize, maxOffset: maxScrollOffset)
            return true
        case .pageDown:
            model.adjustScroll(pageSize, maxOffset: maxScrollOffset)
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
            insertInput(text)
            return true
        case .character(let character) where !event.ctrl && !event.alt:
            insertInput(String(character))
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
        resetPromptHistorySelectionForEdit()
    }

    private func deleteInputBackward() {
        guard inputCursor > 0 else {
            return
        }
        let cursor = min(inputCursor, input.count)
        let index = input.index(input.startIndex, offsetBy: cursor - 1)
        input.remove(at: index)
        inputCursor = cursor - 1
        resetPromptHistorySelectionForEdit()
    }

    private func deleteInputForward() {
        guard inputCursor < input.count else {
            return
        }
        let cursor = min(inputCursor, input.count)
        let index = input.index(input.startIndex, offsetBy: cursor)
        input.remove(at: index)
        inputCursor = cursor
        resetPromptHistorySelectionForEdit()
    }

    private func moveInputCursorBackward() {
        inputCursor = max(0, inputCursor - 1)
    }

    private func moveInputCursorForward() {
        inputCursor = min(input.count, inputCursor + 1)
    }

    private func moveToBeginningOfInputLine() {
        let lines = agentTUIInputLines(input)
        let index = agentTUIInputLineIndex(lines: lines, cursor: inputCursor)
        inputCursor = lines[index].start
    }

    private func moveToEndOfInputLine() {
        let lines = agentTUIInputLines(input)
        let index = agentTUIInputLineIndex(lines: lines, cursor: inputCursor)
        inputCursor = lines[index].end
    }

    private func moveInputLineOrHistory(delta: Int) {
        let lines = agentTUIInputLines(input)
        let lineIndex = agentTUIInputLineIndex(lines: lines, cursor: inputCursor)
        if delta < 0, lineIndex == 0 {
            recallPreviousPrompt()
            return
        }
        if delta > 0, lineIndex == lines.count - 1 {
            recallNextPrompt()
            return
        }

        let targetIndex = min(max(0, lineIndex + delta), lines.count - 1)
        let column = max(0, inputCursor - lines[lineIndex].start)
        let target = lines[targetIndex]
        inputCursor = target.start + min(column, target.end - target.start)
    }

    private func killInputWordBackward() {
        guard inputCursor > 0 else {
            return
        }
        let characters = Array(input)
        let cursor = min(inputCursor, characters.count)
        var start = cursor

        while start > 0, characters[start - 1].isWhitespace {
            start -= 1
        }
        while start > 0, !characters[start - 1].isWhitespace {
            start -= 1
        }

        guard start < cursor else {
            return
        }
        var edited = characters
        edited.removeSubrange(start..<cursor)
        input = String(edited)
        inputCursor = start
        resetPromptHistorySelectionForEdit()
    }

    private func killInputLineForward() {
        let result = agentTUIKillToEndOfLine(input: input, cursor: inputCursor)
        guard result.input != input else {
            return
        }
        input = result.input
        inputCursor = result.cursor
        resetPromptHistorySelectionForEdit()
    }

    private func appendPromptHistory(_ prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if promptHistory.last != prompt {
            promptHistory.append(prompt)
        }
    }

    private func recallPreviousPrompt() {
        guard !promptHistory.isEmpty else {
            return
        }
        if promptHistoryIndex == nil {
            promptHistoryDraft = input
            promptHistoryIndex = promptHistory.count - 1
        } else if let index = promptHistoryIndex, index > 0 {
            promptHistoryIndex = index - 1
        }
        loadPromptHistorySelection()
    }

    private func recallNextPrompt() {
        guard let index = promptHistoryIndex else {
            return
        }
        if index < promptHistory.count - 1 {
            promptHistoryIndex = index + 1
            loadPromptHistorySelection()
        } else {
            promptHistoryIndex = nil
            input = promptHistoryDraft
            inputCursor = input.count
            promptHistoryDraft = ""
        }
    }

    private func loadPromptHistorySelection() {
        guard let index = promptHistoryIndex, promptHistory.indices.contains(index) else {
            return
        }
        input = promptHistory[index]
        inputCursor = input.count
    }

    private func resetPromptHistorySelectionForEdit() {
        promptHistoryIndex = nil
        promptHistoryDraft = ""
    }
}

private struct AgentTUITranscriptRow: View, Renderable {
    let line: TUITranscriptLine

    var body: Never {
        fatalError("AgentTUITranscriptRow renders via Renderable")
    }

    func renderToBuffer(context: RenderContext) -> FrameBuffer {
        let rendered = agentTUIRenderedTranscriptRow(
            line,
            width: max(1, context.availableWidth),
            palette: context.environment.palette
        )
        return FrameBuffer(lines: [rendered.isEmpty ? " " : rendered])
    }
}

private func agentTUIRenderedTranscriptRow(
    _ line: TUITranscriptLine,
    width: Int,
    palette: any Palette
) -> String {
    var output = ""
    var usedWidth = 0

    func append(
        _ text: String,
        color: Color,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false
    ) {
        guard usedWidth < width else {
            return
        }
        let remaining = width - usedWidth
        let clipped = String(text.prefix(remaining))
        guard !clipped.isEmpty else {
            return
        }
        output += agentTUIANSIStyled(
            clipped,
            color: color,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            palette: palette
        )
        usedWidth += clipped.count
    }

    if line.isLabel {
        append(line.text, color: agentTUILabelColor(line.role))
    } else if !line.spans.isEmpty {
        for span in line.spans {
            append(
                span.text,
                color: agentTUISpanColor(span.tone, role: line.role),
                isBold: span.isBold,
                isItalic: span.isItalic,
                isUnderlined: span.isUnderlined
            )
        }
    } else {
        append(
            line.text,
            color: agentTUIFallbackColor(line.role),
            isBold: line.role == .error
        )
    }

    return output.isEmpty ? " " : output
}

private func agentTUIANSIStyled(
    _ text: String,
    color: Color,
    isBold: Bool,
    isItalic: Bool,
    isUnderlined: Bool,
    isReversed: Bool = false,
    palette: any Palette
) -> String {
    var codes: [String] = []
    if isBold {
        codes.append("1")
    }
    if isItalic {
        codes.append("3")
    }
    if isUnderlined {
        codes.append("4")
    }
    if isReversed {
        codes.append("7")
    }
    codes.append(contentsOf: agentTUIForegroundCodes(for: color.resolve(with: palette)))

    guard !codes.isEmpty else {
        return text
    }
    return "\u{1B}[\(codes.joined(separator: ";"))m\(text)\u{1B}[0m"
}

private func agentTUIForegroundCodes(for color: Color) -> [String] {
    switch color.value {
    case let .standard(ansi):
        return [String(ansi.foregroundCode)]
    case let .bright(ansi):
        return [String(ansi.brightForegroundCode)]
    case let .palette256(index):
        return ["38", "5", String(index)]
    case let .rgb(red, green, blue):
        return ["38", "2", String(red), String(green), String(blue)]
    case .semantic:
        return []
    }
}

private func agentTUISpanColor(_ tone: AgentTUIStyledTextTone, role: TUITranscriptRole) -> Color {
    switch tone {
    case .base:
        return agentTUIFallbackColor(role)
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

private func agentTUIFallbackColor(_ role: TUITranscriptRole) -> Color {
    switch role {
    case .user, .assistant:
        return .palette.foreground
    case .tool, .system:
        return .palette.foregroundSecondary
    case .error:
        return .palette.error
    }
}

private func agentTUILabelColor(_ role: TUITranscriptRole) -> Color {
    switch role {
    case .user:
        return .palette.accent
    case .assistant, .system, .tool:
        return .palette.foregroundTertiary
    case .error:
        return .palette.error
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

private func tuiEntries(
    for taskID: UUID,
    store: any AgentTaskStore,
    eventLimit: Int = agentTUITranscriptEventLimit
) async throws -> [TUITranscriptEntry] {
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

    for event in try await store.recentEvents(for: taskID, limit: eventLimit, kinds: agentTUITranscriptEventKinds) {
        switch event.kind {
        case .userMessage:
            if let text = event.payload["text"]?.stringValue {
                append(.user, agentTUIHydratedTranscriptText(text, limit: agentTUIHydratedUserTextLimit))
            }
        case .assistantDone:
            if let text = event.payload["text"]?.stringValue {
                append(.assistant, agentTUIHydratedTranscriptText(text, limit: agentTUIHydratedAssistantTextLimit))
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

func agentTUIHydratedTranscriptText(_ text: String, limit: Int) -> String {
    guard text.count > limit else {
        return text
    }

    return "[... \(text.count - limit) chars truncated from earlier transcript ...]\n\(text.suffix(limit))"
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
    if let claim = activeTaskClaim(summary.currentClaim) {
        lines.append("claim: \(claim.ownerName) until \(ISO8601DateFormatter().string(from: claim.expiresAt))")
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

private func tuiCheckpoints(_ checkpoints: [CheckpointRecord]) -> String {
    if checkpoints.isEmpty {
        return "No checkpoints found."
    }

    return checkpoints.map { checkpoint in
        let pushed = checkpoint.pushedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
        return [
            "\(checkpoint.id.uuidString.prefix(8))  \(checkpoint.branch)",
            "commit: \(checkpoint.commitSHA ?? "-")",
            "remote: \(checkpoint.remoteName)",
            "pushed: \(pushed)",
            "files: \(checkpointChangedFileCount(checkpoint))"
        ].joined(separator: "\n")
    }.joined(separator: "\n\n")
}

private func tuiArtifacts(_ artifacts: [ArtifactRecord]) -> String {
    if artifacts.isEmpty {
        return "No artifacts found."
    }

    return artifacts.map { artifact in
        var lines = [
            "\(artifact.id.uuidString.prefix(8))  \(artifact.kind.rawValue)  \(artifact.title)",
            "ref: \(artifact.contentRef)",
            "type: \(artifact.contentType ?? "-")"
        ]
        if let checkpointID = artifact.metadata["checkpointID"]?.stringValue {
            lines.append("checkpoint: \(String(checkpointID.prefix(8)))")
        }
        return lines.joined(separator: "\n")
    }.joined(separator: "\n\n")
}

private func tuiCheckpointRestoreDetails(
    _ restore: GitCheckpointRestoreResult,
    claim: TaskClaimRecord
) -> String {
    var lines = [
        checkpointRestoreStatus(restore),
        "checkpoint: \(restore.checkpoint.id.uuidString)",
        "branch: \(restore.checkpoint.branch)",
        "commit: \(restore.headSHA ?? restore.checkpoint.commitSHA ?? "-")",
        "claim: \(claim.ownerName) until \(ISO8601DateFormatter().string(from: claim.expiresAt))"
    ]
    if restore.advancedBeyondCheckpoint, let checkpointCommit = restore.checkpoint.commitSHA {
        lines.insert("checkpoint commit: \(checkpointCommit)", at: 4)
    }
    return lines.joined(separator: "\n")
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
                append(role: entry.role, spans: agentTUIIndentedTranscriptSpans(renderedLine))
            }
        case .userQuote:
            for renderedLine in agentTUIQuoteStyledLines(entry.text, width: bodyWidth) {
                append(role: entry.role, spans: renderedLine)
            }
        case let .toolCall(status):
            append(
                role: entry.role,
                spans: agentTUIIndentedTranscriptSpans(agentTUIToolCallStyledLine(entry.text, status: status))
            )
        case .toolOutput:
            for renderedLine in agentTUIToolOutputStyledLines(entry.text, width: bodyWidth) {
                append(role: entry.role, spans: agentTUIIndentedTranscriptSpans(renderedLine))
            }
        }
    }

    return lines
}

func agentTUIIndentedTranscriptSpans(_ spans: [AgentTUIStyledTextSpan]) -> [AgentTUIStyledTextSpan] {
    guard spans.count == 1, var span = spans.first, span.preservesLayout else {
        return [AgentTUIStyledTextSpan("  ")] + spans
    }

    span.text = "  " + span.text
    return [span]
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

func agentTUIInputLines(_ input: String) -> [AgentTUIInputLine] {
    let characters = Array(input)
    guard !characters.isEmpty else {
        return [AgentTUIInputLine(start: 0, end: 0, text: "")]
    }

    var lines: [AgentTUIInputLine] = []
    var start = 0
    for (index, character) in characters.enumerated() where character == "\n" {
        lines.append(AgentTUIInputLine(
            start: start,
            end: index,
            text: start < index ? String(characters[start..<index]) : ""
        ))
        start = index + 1
    }

    lines.append(AgentTUIInputLine(
        start: start,
        end: characters.count,
        text: start < characters.count ? String(characters[start..<characters.count]) : ""
    ))
    return lines
}

func agentTUIInputLineIndex(lines: [AgentTUIInputLine], cursor: Int) -> Int {
    guard !lines.isEmpty else {
        return 0
    }

    let clampedCursor = max(0, cursor)
    for (index, line) in lines.enumerated()
        where clampedCursor >= line.start && clampedCursor <= line.end {
        return index
    }
    return clampedCursor < lines[0].start ? 0 : lines.count - 1
}

func agentTUIMoveCursorUp(lines: [AgentTUIInputLine], cursor: Int) -> Int {
    guard !lines.isEmpty else {
        return 0
    }
    let currentLineIndex = agentTUIInputLineIndex(lines: lines, cursor: cursor)
    if currentLineIndex == 0 {
        return cursor
    }
    let currentLine = lines[currentLineIndex]
    let column = cursor - currentLine.start
    let targetLine = lines[currentLineIndex - 1]
    return targetLine.start + min(column, targetLine.end - targetLine.start)
}

func agentTUIMoveCursorDown(lines: [AgentTUIInputLine], cursor: Int) -> Int {
    guard !lines.isEmpty else {
        return 0
    }
    let currentLineIndex = agentTUIInputLineIndex(lines: lines, cursor: cursor)
    if currentLineIndex == lines.count - 1 {
        return cursor
    }
    let currentLine = lines[currentLineIndex]
    let column = cursor - currentLine.start
    let targetLine = lines[currentLineIndex + 1]
    return targetLine.start + min(column, targetLine.end - targetLine.start)
}

private func clampedScrollOffset(_ offset: Int, maxOffset: Int) -> Int {
    min(max(0, offset), maxOffset)
}

private func visibleLines(_ lines: [TUITranscriptLine], height: Int, scrollOffset: Int) -> [TUITranscriptLine] {
    guard lines.count > height else {
        return lines
    }
    // scrollOffset is from the bottom: 0 = show most recent content
    // When scrollOffset > 0, we're scrolling up into older content
    let start = max(0, lines.count - height - scrollOffset)
    return Array(lines[start..<start + height])
}

func agentTUIKillToEndOfLine(input: String, cursor: Int) -> (input: String, cursor: Int) {
    var characters = Array(input)
    guard !characters.isEmpty else {
        return (input, 0)
    }

    let clampedCursor = min(max(0, cursor), characters.count)
    let lines = agentTUIInputLines(input)
    let line = lines[agentTUIInputLineIndex(lines: lines, cursor: clampedCursor)]
    let end = clampedCursor < line.end
        ? line.end
        : min(characters.count, clampedCursor + 1)
    guard clampedCursor < end else {
        return (input, clampedCursor)
    }

    characters.removeSubrange(clampedCursor..<end)
    return (String(characters), clampedCursor)
}

func agentTUIComposerRows(
    input: String,
    cursor: Int,
    width: Int,
    maxRows: Int
) -> [AgentTUIComposerRow] {
    let lines = agentTUIInputLines(input)
    let inputCount = input.count
    let clampedCursor = min(max(0, cursor), inputCount)
    let cursorLineIndex = agentTUIInputLineIndex(lines: lines, cursor: clampedCursor)
    let wrapWidth = max(1, width - 1)
    var rows: [AgentTUIComposerRow] = []
    var cursorRowIndex = 0

    for (lineIndex, line) in lines.enumerated() {
        let characters = Array(line.text)
        let cursorColumn = clampedCursor - line.start

        if characters.isEmpty {
            let hasCursor = lineIndex == cursorLineIndex
            if hasCursor {
                cursorRowIndex = rows.count
            }
            rows.append(AgentTUIComposerRow(
                id: rows.count,
                before: "",
                cursorText: hasCursor ? " " : nil,
                after: "",
                hasCursor: hasCursor
            ))
            continue
        }

        var offset = 0
        while offset < characters.count {
            let chunkEnd = min(characters.count, offset + wrapWidth)
            let hasCursor = lineIndex == cursorLineIndex
                && cursorColumn >= offset
                && (cursorColumn < chunkEnd || (cursorColumn == chunkEnd && chunkEnd == characters.count))
            let split = hasCursor ? min(max(cursorColumn, offset), chunkEnd) : chunkEnd

            if hasCursor {
                cursorRowIndex = rows.count
            }

            let cursorText: String?
            let before: String
            let after: String
            if hasCursor {
                before = offset < split ? String(characters[offset..<split]) : ""
                if split < chunkEnd {
                    cursorText = String(characters[split])
                    let afterStart = split + 1
                    after = afterStart < chunkEnd ? String(characters[afterStart..<chunkEnd]) : ""
                } else {
                    cursorText = " "
                    after = ""
                }
            } else {
                before = String(characters[offset..<chunkEnd])
                cursorText = nil
                after = ""
            }

            rows.append(AgentTUIComposerRow(
                id: rows.count,
                before: before,
                cursorText: cursorText,
                after: after,
                hasCursor: hasCursor
            ))
            offset = chunkEnd
        }
    }

    guard rows.count > maxRows else {
        return rows
    }

    let visibleCount = max(1, maxRows)
    let maxStart = max(0, rows.count - visibleCount)
    let start = min(max(0, cursorRowIndex - visibleCount + 1), maxStart)
    return rows[start..<(start + visibleCount)].enumerated().map { index, row in
        AgentTUIComposerRow(
            id: index,
            before: row.before,
            cursorText: row.cursorText,
            after: row.after,
            hasCursor: row.hasCursor
        )
    }
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

private func resolvedAgentModelMetadata(backend: AgentBackend, options: BackendRunOptions) -> CodexModelMetadata {
    switch backend {
    case .codex:
        return resolvedCodexModelMetadata(modelOverride: options.model)
    case .pi:
        return resolvedPiModelMetadata(modelOverride: options.model, thinkingOverride: options.thinking)
    case .claude:
        return CodexModelMetadata(displayName: nonEmpty(options.model) ?? "claude", contextWindowTokens: nil)
    }
}

private func resolvedPiModelMetadata(modelOverride: String? = nil, thinkingOverride: String? = nil) -> CodexModelMetadata {
    let settings = piSettings()
    let model = nonEmpty(modelOverride)
        ?? nonEmpty(settings["defaultModel"])
        ?? "pi"
    let thinking = nonEmpty(thinkingOverride)
        ?? nonEmpty(settings["defaultThinkingLevel"])

    let displayName: String
    if let thinking, thinking != "off" {
        displayName = "\(model) (\(thinking))"
    } else {
        displayName = model
    }

    return CodexModelMetadata(displayName: displayName, contextWindowTokens: nil)
}

private func piSettings() -> [String: String] {
    let environment = ProcessInfo.processInfo.environment
    let piDir = nonEmpty(environment["PI_CODING_AGENT_DIR"])
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent").path
    let settingsURL = URL(fileURLWithPath: piDir).appendingPathComponent("settings.json")

    guard let data = try? Data(contentsOf: settingsURL) else {
        return [:]
    }

    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }

    var values: [String: String] = [:]
    for (key, value) in object {
        if let stringValue = value as? String {
            values[key] = stringValue
        }
    }
    return values
}

private func resolvedCodexModelMetadata(modelOverride: String? = nil) -> CodexModelMetadata {
    let environment = ProcessInfo.processInfo.environment
    let defaults = codexConfigDefaults()
    let model = nonEmpty(modelOverride)
        ?? nonEmpty(environment["CODEX_MODEL"])
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
