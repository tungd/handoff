import Foundation

public enum AgentSessionControllerError: Error, CustomStringConvertible, Sendable {
    case unsupportedBackend(AgentBackend)
    case backendFailed(exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case let .unsupportedBackend(backend):
            return "backend is not wired yet: \(backend.rawValue)"
        case let .backendFailed(exitCode, stderr):
            return "backend exited with \(exitCode): \(stderr)"
        }
    }
}

public enum AgentSessionUpdate: Equatable, Sendable {
    case event(AgentEvent)
    case session(SessionRecord)
}

public struct AgentSessionController: Sendable {
    private let store: any AgentTaskStore
    private let codexBackend: CodexStreamingBackend
    private let codexInterruptBackend: CodexStreamingBackend
    private let piBackend: PiRPCBackend

    public init(
        store: any AgentTaskStore,
        codexBackend: CodexStreamingBackend = CodexStreamingBackend(),
        codexInterruptBackend: CodexStreamingBackend = CodexStreamingBackend(runner: SubprocessPTYStreamRunner()),
        piBackend: PiRPCBackend = PiRPCBackend()
    ) {
        self.store = store
        self.codexBackend = codexBackend
        self.codexInterruptBackend = codexInterruptBackend
        self.piBackend = piBackend
    }

    public func runAgentTurn(
        task: TaskRecord,
        prompt: String,
        repoURL: URL,
        snapshot: RepositorySnapshot,
        codexOptions: CodexExecOptions = CodexExecOptions(),
        piOptions: PiRPCOptions = PiRPCOptions(),
        images: [PiRPCImage] = [],
        interruptHandle: AgentInterruptHandle? = nil,
        onUpdate: @escaping @Sendable (AgentSessionUpdate) async throws -> Void = { _ in }
    ) async throws -> TaskRunSummary {
        switch task.backendPreference {
        case .codex:
            return try await runCodexTurn(
                task: task,
                prompt: prompt,
                repoURL: repoURL,
                snapshot: snapshot,
                options: codexOptions,
                images: images,
                interruptHandle: interruptHandle,
                onUpdate: onUpdate
            )
        case .pi:
            return try await runPiTurn(
                task: task,
                prompt: prompt,
                repoURL: repoURL,
                snapshot: snapshot,
                options: piOptions,
                images: images,
                interruptHandle: interruptHandle,
                onUpdate: onUpdate
            )
        case .claude:
            throw AgentSessionControllerError.unsupportedBackend(task.backendPreference)
        }
    }

    public func runCodexTurn(
        task: TaskRecord,
        prompt: String,
        repoURL: URL,
        snapshot: RepositorySnapshot,
        options: CodexExecOptions = CodexExecOptions(),
        images: [PiRPCImage] = [],
        interruptHandle: AgentInterruptHandle? = nil,
        onUpdate: @escaping @Sendable (AgentSessionUpdate) async throws -> Void = { _ in }
    ) async throws -> TaskRunSummary {
        guard task.backendPreference == .codex else {
            throw AgentSessionControllerError.unsupportedBackend(task.backendPreference)
        }

        // Save images to temp files for Codex CLI (-i option requires file paths)
        var imageTempFiles: [URL] = []
        var codexOptions = options
        if !images.isEmpty {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentctl-images")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            for image in images {
                // Decode base64 and write to temp file
                guard let imageData = Data(base64Encoded: image.data) else {
                    continue
                }
                let ext = mimeTypeExtension(image.mimeType)
                let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ext)
                try imageData.write(to: tempFile)
                imageTempFiles.append(tempFile)
            }
            codexOptions.imagePaths = imageTempFiles.map { $0.path }
        }

        let cwd = snapshot.rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? repoURL
        let previousSession = try await store.latestSession(for: task.id)
        var session = SessionRecord(
            taskID: task.id,
            backend: .codex,
            backendSessionID: previousSession?.backendSessionID,
            cwd: cwd.path,
            state: .running
        )

        try await store.saveSession(session)
        try await onUpdate(.session(session))

        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .sessionStarted, payload: [
            "backend": .string(session.backend.rawValue),
            "cwd": .string(session.cwd),
            "resumeThreadID": session.backendSessionID.map { .string($0) } ?? .null,
            "imageCount": .int(Int64(images.count))
        ]), onUpdate: onUpdate)

        // Include images in userMessage payload if present
        var userMessagePayload: [String: JSONValue] = ["text": .string(prompt)]
        if !images.isEmpty {
            userMessagePayload["images"] = .array(images.map { img in
                .object(["type": .string("image"), "data": .string(img.data), "mimeType": .string(img.mimeType)])
            })
        }
        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .userMessage, payload: userMessagePayload), onUpdate: onUpdate)

        let activeCodexBackend = interruptHandle == nil ? codexBackend : codexInterruptBackend
        let result = try await activeCodexBackend.run(
            prompt: prompt,
            cwd: cwd,
            resumeThreadID: session.backendSessionID,
            options: codexOptions,
            interruptHandle: interruptHandle
        ) { update in
            switch update {
            case let .mappedLine(mapped):
                if let threadID = mapped.threadID {
                    session.backendSessionID = threadID
                    try await store.saveSession(session)
                    try await onUpdate(.session(session))
                }

                var event = mapped.event
                event.taskID = task.id
                event.sessionID = session.id
                try await appendAndEmit(event, onUpdate: onUpdate)
            case let .stderrLine(line):
                try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .backendEvent, payload: [
                    "stderr": .string(line)
                ]), onUpdate: onUpdate)
            }
        }

        if let threadID = result.threadID {
            session.backendSessionID = threadID
        }

        session.state = result.exitCode == 0 ? .ended : .failed
        session.endedAt = Date()

        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .sessionEnded, payload: [
            "exitCode": .int(Int64(result.exitCode)),
            "threadID": session.backendSessionID.map { .string($0) } ?? .null
        ]), onUpdate: onUpdate)

        try await store.saveSession(session)
        try await onUpdate(.session(session))

        // Clean up temp image files
        for tempFile in imageTempFiles {
            try? FileManager.default.removeItem(at: tempFile)
        }

        if result.exitCode != 0 {
            throw AgentSessionControllerError.backendFailed(exitCode: result.exitCode, stderr: result.stderr)
        }

        return try await store.summary(for: task)
    }

    public func runPiTurn(
        task: TaskRecord,
        prompt: String,
        repoURL: URL,
        snapshot: RepositorySnapshot,
        options: PiRPCOptions = PiRPCOptions(),
        images: [PiRPCImage] = [],
        interruptHandle: AgentInterruptHandle? = nil,
        onUpdate: @escaping @Sendable (AgentSessionUpdate) async throws -> Void = { _ in }
    ) async throws -> TaskRunSummary {
        guard task.backendPreference == .pi else {
            throw AgentSessionControllerError.unsupportedBackend(task.backendPreference)
        }

        let cwd = snapshot.rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? repoURL
        let previousSession = try await store.latestSession(for: task.id)
        let sessionPath = previousSession?.backendSessionID.map { URL(fileURLWithPath: $0) }
            ?? Self.piSessionPath(taskID: task.id, cwd: cwd)
        var session = SessionRecord(
            taskID: task.id,
            backend: .pi,
            backendSessionID: sessionPath.path,
            cwd: cwd.path,
            state: .running
        )

        try await store.saveSession(session)
        try await onUpdate(.session(session))

        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .sessionStarted, payload: [
            "backend": .string(session.backend.rawValue),
            "cwd": .string(session.cwd),
            "sessionPath": .string(sessionPath.path)
        ]), onUpdate: onUpdate)

        // Include images in userMessage payload if present
        var userMessagePayload: [String: JSONValue] = ["text": .string(prompt)]
        if !images.isEmpty {
            userMessagePayload["images"] = .array(images.map { img in
                .object(["type": .string("image"), "data": .string(img.data), "mimeType": .string(img.mimeType)])
            })
        }
        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .userMessage, payload: userMessagePayload), onUpdate: onUpdate)

        let result = try await piBackend.run(
            prompt: prompt,
            cwd: cwd,
            sessionPath: sessionPath,
            options: options,
            images: images,
            interruptHandle: interruptHandle
        ) { update in
            switch update {
            case let .mappedLine(mapped):
                if let newSessionPath = mapped.sessionPath {
                    session.backendSessionID = newSessionPath
                    try await store.saveSession(session)
                    try await onUpdate(.session(session))
                }

                var event = mapped.event
                event.taskID = task.id
                event.sessionID = session.id
                try await appendAndEmit(event, onUpdate: onUpdate)
            case let .stderrLine(line):
                try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .backendEvent, payload: [
                    "stderr": .string(line),
                    "backend": .string("pi")
                ]), onUpdate: onUpdate)
            }
        }

        session.backendSessionID = result.sessionPath
        session.state = result.exitCode == 0 ? .ended : .failed
        session.endedAt = Date()

        try await appendAndEmit(AgentEvent(taskID: task.id, sessionID: session.id, kind: .sessionEnded, payload: [
            "exitCode": .int(Int64(result.exitCode)),
            "sessionPath": .string(result.sessionPath)
        ]), onUpdate: onUpdate)

        try await store.saveSession(session)
        try await onUpdate(.session(session))

        if result.exitCode != 0 {
            throw AgentSessionControllerError.backendFailed(exitCode: result.exitCode, stderr: result.stderr)
        }

        return try await store.summary(for: task)
    }

    public static func piSessionPath(taskID: UUID, cwd: URL) -> URL {
        cwd.appendingPathComponent(".agentctl", isDirectory: true)
            .appendingPathComponent("pi-sessions", isDirectory: true)
            .appendingPathComponent("\(taskID.uuidString).jsonl")
    }

    @discardableResult
    private func appendAndEmit(
        _ event: AgentEvent,
        onUpdate: @escaping @Sendable (AgentSessionUpdate) async throws -> Void
    ) async throws -> AgentEvent {
        let stored = try await store.appendEvent(event)
        try await onUpdate(.event(stored))
        return stored
    }
}

/// Get file extension from MIME type for temp file creation.
private func mimeTypeExtension(_ mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/png": return ".png"
    case "image/jpeg", "image/jpg": return ".jpg"
    case "image/gif": return ".gif"
    case "image/webp": return ".webp"
    case "image/svg+xml": return ".svg"
    case "application/pdf": return ".pdf"
    case "text/plain": return ".txt"
    default: return ".bin"
    }
}
