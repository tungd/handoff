import AgentCore
import Darwin
import Foundation

enum TerminalCapability {
    static var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }
}

final class SendableFlag: @unchecked Sendable {
    var value: Bool

    init(_ value: Bool = false) {
        self.value = value
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
        print(dim("/help /info /tasks /new [title] /resume <task> [--checkpoint <id|latest>] [--force] /checkpoint [--push] /checkpoints /artifacts /continue [path] /release /export [path] /events /raw /exit"))
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
        if let claim = activeTaskClaim(summary.currentClaim) {
            print("\(label("claim"))  \(claim.ownerName) until \(ISO8601DateFormatter().string(from: claim.expiresAt))")
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
                    block(label: "assistant", text: text, colorCode: "32")
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
