import Foundation

public enum BackendCapability: String, Codable, CaseIterable, Sendable {
    case structuredInput = "structured_input"
    case structuredOutput = "structured_output"
    case appServer = "app_server"
    case execJSON = "exec_json"
    case resumeNativeSession = "resume_native_session"
    case cancel
}

public struct BackendDescriptor: Codable, Equatable, Sendable {
    public var backend: AgentBackend
    public var displayName: String
    public var capabilities: [BackendCapability]
    public var notes: String

    public init(
        backend: AgentBackend,
        displayName: String,
        capabilities: [BackendCapability],
        notes: String
    ) {
        self.backend = backend
        self.displayName = displayName
        self.capabilities = capabilities
        self.notes = notes
    }
}

public protocol AgentBackendAdapter: Sendable {
    var descriptor: BackendDescriptor { get }
}

public struct CodexBackendAdapter: AgentBackendAdapter {
    public let descriptor = BackendDescriptor(
        backend: .codex,
        displayName: "Codex",
        capabilities: [.execJSON, .appServer, .structuredOutput, .resumeNativeSession, .cancel],
        notes: "Primary backend. v1 uses codex exec --json/resume; app-server is the next backend target."
    )

    public init() {}

    public var appServerCommand: [String] {
        ["codex", "app-server", "--listen", "stdio://"]
    }

    public var execServerCommand: [String] {
        ["codex", "exec-server"]
    }
}

public struct ClaudeBackendAdapter: AgentBackendAdapter {
    public let descriptor = BackendDescriptor(
        backend: .claude,
        displayName: "Claude Code",
        capabilities: [.structuredInput, .structuredOutput, .cancel],
        notes: "Deferred backend. Target stream-json input/output after Codex MVP."
    )

    public init() {}

    public var streamJSONCommand: [String] {
        ["claude", "--output-format", "stream-json", "--input-format", "stream-json"]
    }
}
