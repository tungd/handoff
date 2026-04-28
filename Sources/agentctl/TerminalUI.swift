import AgentCore
import Darwin
import Foundation

enum TerminalCapability {
    static var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }
}

struct TerminalRenderer {
    let styled: Bool

    init(styled: Bool = isatty(STDOUT_FILENO) == 1) {
        self.styled = styled
    }

    func header(task: TaskRecord, storeOptions: StoreOptions, repoURL: URL, snapshot: RepositorySnapshot) {
        let store = storeDescription(options: storeOptions, repoURL: repoURL, snapshot: snapshot)
        print("")
        print(line(" agentctl | task \(task.slug) | \(task.backendPreference.rawValue) | \(shortStore(store)) ", fill: "="))
        print(line("", fill: "-"))
        help()
    }

    func help() {
        print(dim("/help /info /tasks /new [title] /resume <task> /events /raw /exit"))
    }

    func prompt(task: TaskRecord) {
        flushStdout()
        writeStdout("\n\(accent(task.slug))> ")
    }

    func status(_ text: String) {
        print(dim(text))
    }

    func error(_ text: String) {
        print(color("error", code: "31") + " \(text)")
    }

    func info(task: TaskRecord, summary: TaskRunSummary, storeOptions: StoreOptions, repoURL: URL, snapshot: RepositorySnapshot) {
        print(line(" info ", fill: "-"))
        print("\(label("id"))  \(task.id.uuidString)")
        print("\(label("title"))  \(task.title)")
        print("\(label("state"))  \(task.state.rawValue)")
        print("\(label("backend"))  \(task.backendPreference.rawValue)")
        print("\(label("store"))  \(storeDescription(options: storeOptions, repoURL: repoURL, snapshot: snapshot))")
        print("\(label("repo"))  \(snapshot.rootPath ?? repoURL.path)")
        print("\(label("branch"))  \(snapshot.currentBranch ?? "-")")
        if let session = summary.sessions.first {
            print("\(label("thread"))  \(session.backendSessionID ?? "-")")
            print("\(label("cwd"))  \(session.cwd)")
        }
    }

    func tasks(_ tasks: [TaskRecord]) {
        print(line(" tasks ", fill: "-"))
        if tasks.isEmpty {
            print(dim("No tasks found."))
            return
        }

        for task in tasks {
            print("\(accent(task.slug))  \(task.title)  \(dim(task.state.rawValue))")
        }
    }

    func events(_ events: [AgentEvent]) {
        print(line(" events ", fill: "-"))
        if events.isEmpty {
            print(dim("No events found."))
            return
        }

        for event in events {
            let sequence = event.sequence.map(String.init) ?? "-"
            print("\(dim(sequence)) \(event.kind.rawValue) \(shortPayload(event.payload))")
        }
    }

    @discardableResult
    func render(update: AgentSessionUpdate, showRawEvents: Bool) -> Bool {
        switch update {
        case let .event(event):
            switch event.kind {
            case .assistantDone:
                if let text = event.payload["text"]?.stringValue {
                    block(label: "codex", text: text, colorCode: "32")
                    return true
                }
            case .toolStarted:
                print("\(color("tool", code: "33"))  start  \(shortPayload(event.payload))")
            case .toolFinished:
                print("\(color("tool", code: "33"))  done   \(shortPayload(event.payload))")
            case .backendSessionUpdated:
                if showRawEvents {
                    print(dim("\(event.kind.rawValue) \(shortPayload(event.payload))"))
                }
            case .backendEvent:
                if showRawEvents {
                    print(dim("\(event.kind.rawValue) \(shortPayload(event.payload))"))
                }
            default:
                if showRawEvents {
                    print(dim("\(event.kind.rawValue) \(shortPayload(event.payload))"))
                }
            }
        case let .session(session):
            if showRawEvents {
                print(dim("session \(session.state.rawValue) \(session.backendSessionID ?? "-")"))
            }
        }

        return false
    }

    private func block(label: String, text: String, colorCode: String) {
        print("")
        print(color(label, code: colorCode))
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            print(String(line))
        }
    }

    private func label(_ text: String) -> String {
        color(text, code: "36")
    }

    private func accent(_ text: String) -> String {
        color(text, code: "36;1")
    }

    private func dim(_ text: String) -> String {
        color(text, code: "2")
    }

    private func color(_ text: String, code: String) -> String {
        guard styled else {
            return text
        }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func line(_ title: String, fill: Character) -> String {
        let width = max(40, terminalWidth())
        let raw = title.isEmpty ? String(fill) : title
        if raw.count >= width {
            return raw
        }
        return raw + String(repeating: String(fill), count: width - raw.count)
    }

    private func terminalWidth() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return 80
        }
        return Int(size.ws_col)
    }

    private func shortPayload(_ payload: [String: JSONValue]) -> String {
        if let command = payload["command"]?.stringValue {
            let exitCode: String
            if case let .int(value) = payload["exitCode"] {
                exitCode = " exit \(value)"
            } else {
                exitCode = ""
            }
            return "\(command)\(exitCode)"
        }
        if let type = payload["type"]?.stringValue {
            return type
        }
        if let text = payload["text"]?.stringValue {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        if let stderr = payload["stderr"]?.stringValue {
            return stderr.replacingOccurrences(of: "\n", with: " ")
        }
        return ""
    }

    private func shortStore(_ store: String) -> String {
        if store.hasPrefix("postgres://") {
            return "postgres"
        }
        if store.hasSuffix("/.agentctl") {
            return "local"
        }
        return store
    }
}

enum FullScreenEntryRole: String {
    case user
    case codex
    case tool
    case system
    case error
}

struct FullScreenEntry {
    var role: FullScreenEntryRole
    var text: String
}

struct FullScreenState {
    var task: TaskRecord
    var storeName: String
    var entries: [FullScreenEntry]
    var input: String = ""
    var status: String = "ready"
    var scrollOffset: Int = 0
    var showRawEvents: Bool = false

    mutating func append(_ role: FullScreenEntryRole, _ text: String) {
        entries.append(FullScreenEntry(role: role, text: text))
        scrollOffset = 0
    }
}

enum FullScreenInput {
    case submit(String)
    case quit
}

final class FullScreenTerminal {
    private var originalTermios = termios()
    private var rawModeEnabled = false
    private let styled: Bool

    init(styled: Bool = true) {
        self.styled = styled
    }

    func start() throws {
        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0 else {
            throw RuntimeError("failed to read terminal attributes")
        }

        originalTermios = current
        current.c_lflag &= ~UInt(ECHO | ICANON | IEXTEN | ISIG)
        current.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        current.c_oflag &= ~UInt(OPOST)
        current.c_cflag |= UInt(CS8)
        current.c_cc.16 = 1
        current.c_cc.17 = 0

        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &current) == 0 else {
            throw RuntimeError("failed to enter raw terminal mode")
        }

        rawModeEnabled = true
        write("\u{001B}[?1049h\u{001B}[?25l")
    }

    func stop() {
        write("\u{001B}[?25h\u{001B}[?1049l")
        if rawModeEnabled {
            var original = originalTermios
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            rawModeEnabled = false
        }
    }

    func readInput(state: inout FullScreenState) -> FullScreenInput {
        while true {
            render(state)
            guard let byte = readByte() else {
                return .quit
            }

            switch byte {
            case 3, 4, 17:
                return .quit
            case 10, 13:
                let input = state.input.trimmingCharacters(in: .whitespacesAndNewlines)
                state.input = ""
                if !input.isEmpty {
                    return .submit(input)
                }
            case 27:
                handleEscape(state: &state)
            case 127, 8:
                if !state.input.isEmpty {
                    state.input.removeLast()
                }
            default:
                if byte >= 32 {
                    state.input.append(Character(UnicodeScalar(Int(byte)) ?? " "))
                }
            }
        }
    }

    func render(_ state: FullScreenState) {
        let size = terminalSize()
        let width = max(40, size.columns)
        let height = max(12, size.rows)
        let transcriptHeight = max(3, height - 6)
        let lines = transcriptLines(state.entries, width: width)
        let visibleStart = max(0, lines.count - transcriptHeight - state.scrollOffset)
        let visible = Array(lines.dropFirst(visibleStart).prefix(transcriptHeight))

        var output = "\u{001B}[H\u{001B}[2J"
        output += bar(" agentctl | \(state.task.slug) | \(state.task.backendPreference.rawValue) | \(state.storeName) ", width: width, fill: "=")
        output += "\n"

        for line in visible {
            output += fit(line, width: width) + "\n"
        }

        if visible.count < transcriptHeight {
            output += String(repeating: "\n", count: transcriptHeight - visible.count)
        }

        output += bar(" \(state.status) ", width: width, fill: "-")
        output += "\n"
        output += fit("> \(state.input)", width: width)
        output += "\n"
        output += fit(dim("/help /info /tasks /new /resume /events /raw /exit | PgUp/PgDn"), width: width)
        write(output)
    }

    func append(update: AgentSessionUpdate, state: inout FullScreenState) {
        switch update {
        case let .event(event):
            switch event.kind {
            case .assistantDone:
                if let text = event.payload["text"]?.stringValue {
                    state.append(.codex, text)
                }
            case .toolStarted:
                state.append(.tool, "start  \(shortPayload(event.payload))")
            case .toolFinished:
                state.append(.tool, "done   \(shortPayload(event.payload))")
            case .backendSessionUpdated:
                if state.showRawEvents {
                    state.append(.system, "\(event.kind.rawValue) \(shortPayload(event.payload))")
                }
            case .backendEvent:
                if state.showRawEvents {
                    state.append(.system, "\(event.kind.rawValue) \(shortPayload(event.payload))")
                }
            default:
                if state.showRawEvents {
                    state.append(.system, "\(event.kind.rawValue) \(shortPayload(event.payload))")
                }
            }
        case let .session(session):
            state.status = "session \(session.state.rawValue)"
        }
    }

    private func handleEscape(state: inout FullScreenState) {
        guard let first = readByte() else {
            return
        }

        if first == 91, let second = readByte() {
            switch second {
            case 65:
                state.scrollOffset += 1
            case 66:
                state.scrollOffset = max(0, state.scrollOffset - 1)
            case 53:
                _ = readByte()
                state.scrollOffset += 10
            case 54:
                _ = readByte()
                state.scrollOffset = max(0, state.scrollOffset - 10)
            default:
                return
            }
        }
    }

    private func transcriptLines(_ entries: [FullScreenEntry], width: Int) -> [String] {
        var lines: [String] = []
        for entry in entries {
            if !lines.isEmpty {
                lines.append("")
            }

            lines.append(style(entry.role.rawValue, role: entry.role))
            let bodyWidth = max(20, width - 2)
            for rawLine in entry.text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(contentsOf: wrap(String(rawLine), width: bodyWidth).map { "  \($0)" })
            }
        }
        return lines
    }

    private func wrap(_ text: String, width: Int) -> [String] {
        if text.isEmpty {
            return [""]
        }

        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let piece = String(word)
            if current.count + piece.count + 1 > width, !current.isEmpty {
                lines.append(current)
                current = piece
            } else {
                current += current.isEmpty ? piece : " \(piece)"
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private func style(_ text: String, role: FullScreenEntryRole) -> String {
        switch role {
        case .user:
            return color(text, code: "36;1")
        case .codex:
            return color(text, code: "32;1")
        case .tool:
            return color(text, code: "33")
        case .error:
            return color(text, code: "31;1")
        case .system:
            return dim(text)
        }
    }

    private func bar(_ title: String, width: Int, fill: Character) -> String {
        if title.count >= width {
            return String(title.prefix(width))
        }
        return title + String(repeating: String(fill), count: width - title.count)
    }

    private func fit(_ text: String, width: Int) -> String {
        let plain = visibleCount(text)
        if plain >= width {
            return String(text.prefix(width))
        }
        return text + String(repeating: " ", count: width - plain)
    }

    private func visibleCount(_ text: String) -> Int {
        var count = 0
        var inEscape = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x1B {
                inEscape = true
            } else if inEscape, scalar == "m" {
                inEscape = false
            } else if !inEscape {
                count += 1
            }
        }
        return count
    }

    private func terminalSize() -> (rows: Int, columns: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
            return (24, 80)
        }
        return (Int(size.ws_row), Int(size.ws_col))
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        return count == 1 ? byte : nil
    }

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func dim(_ text: String) -> String {
        color(text, code: "2")
    }

    private func color(_ text: String, code: String) -> String {
        guard styled else {
            return text
        }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func shortPayload(_ payload: [String: JSONValue]) -> String {
        if let command = payload["command"]?.stringValue {
            let exitCode: String
            if case let .int(value) = payload["exitCode"] {
                exitCode = " exit \(value)"
            } else {
                exitCode = ""
            }
            return "\(command)\(exitCode)"
        }
        if let text = payload["text"]?.stringValue {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        if let stderr = payload["stderr"]?.stringValue {
            return stderr.replacingOccurrences(of: "\n", with: " ")
        }
        if let type = payload["type"]?.stringValue {
            return type
        }
        return ""
    }
}

struct SlashCommand {
    var name: String
    var argument: String?

    init?(_ input: String) {
        guard input.hasPrefix("/") else {
            return nil
        }

        let trimmed = input.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        name = String(parts[0])
        argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}
