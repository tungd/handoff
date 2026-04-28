import Foundation

public enum GitCheckpointError: Error, CustomStringConvertible, Sendable {
    case notGitRepository
    case checkpointCommitMismatch(expected: String, actual: String)
    case gitFailed(arguments: [String], stderr: String)

    public var description: String {
        switch self {
        case .notGitRepository:
            return "checkpoint requires a git repository"
        case let .checkpointCommitMismatch(expected, actual):
            return "checkpoint restore ended at \(actual), expected \(expected)"
        case let .gitFailed(arguments, stderr):
            let command = (["git"] + arguments).joined(separator: " ")
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(command) failed" : "\(command) failed: \(detail)"
        }
    }
}

public struct GitCheckpointOptions: Sendable, Equatable {
    public var branch: String?
    public var remoteName: String
    public var message: String?
    public var push: Bool

    public init(
        branch: String? = nil,
        remoteName: String = "origin",
        message: String? = nil,
        push: Bool = false
    ) {
        self.branch = branch
        self.remoteName = remoteName
        self.message = message
        self.push = push
    }
}

public struct GitCheckpointResult: Codable, Sendable, Equatable {
    public var checkpoint: CheckpointRecord
    public var dirtyStatus: String
    public var committed: Bool
    public var pushed: Bool

    public init(
        checkpoint: CheckpointRecord,
        dirtyStatus: String,
        committed: Bool,
        pushed: Bool
    ) {
        self.checkpoint = checkpoint
        self.dirtyStatus = dirtyStatus
        self.committed = committed
        self.pushed = pushed
    }
}

public struct GitCheckpointRestoreResult: Codable, Sendable, Equatable {
    public var checkpoint: CheckpointRecord
    public var fetched: Bool
    public var switched: Bool
    public var fastForwarded: Bool
    public var headSHA: String?

    public init(
        checkpoint: CheckpointRecord,
        fetched: Bool,
        switched: Bool,
        fastForwarded: Bool,
        headSHA: String?
    ) {
        self.checkpoint = checkpoint
        self.fetched = fetched
        self.switched = switched
        self.fastForwarded = fastForwarded
        self.headSHA = headSHA
    }
}

public struct GitCheckpointManager: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    public func createCheckpoint(
        task: TaskRecord,
        snapshot: RepositorySnapshot,
        repoURL: URL,
        options: GitCheckpointOptions = GitCheckpointOptions()
    ) throws -> GitCheckpointResult {
        guard snapshot.isGitRepository else {
            throw GitCheckpointError.notGitRepository
        }

        let rootURL = URL(
            fileURLWithPath: snapshot.rootPath ?? repoURL.path,
            isDirectory: true
        )
        let branch = options.branch?.isEmpty == false ? options.branch! : Self.defaultBranch(for: task)

        try switchToBranch(branch, workingDirectory: rootURL)
        let dirtyStatus = try requiredOutput(["status", "--porcelain=v1"], workingDirectory: rootURL)
        let hasChanges = !dirtyStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasChanges {
            try runRequired(["add", "-A", "--", ".", ":!.agentctl"], workingDirectory: rootURL)
            try runRequired(
                ["commit", "-m", options.message ?? Self.defaultMessage(for: task)],
                workingDirectory: rootURL
            )
        }

        let head = try requiredOutput(["rev-parse", "HEAD"], workingDirectory: rootURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pushedAt: Date?
        if options.push {
            try runRequired(["push", "-u", options.remoteName, branch], workingDirectory: rootURL)
            pushedAt = Date()
        } else {
            pushedAt = nil
        }

        let checkpoint = CheckpointRecord(
            taskID: task.id,
            branch: branch,
            commitSHA: head.isEmpty ? nil : head,
            remoteName: options.remoteName,
            pushedAt: pushedAt
        )

        return GitCheckpointResult(
            checkpoint: checkpoint,
            dirtyStatus: dirtyStatus,
            committed: hasChanges,
            pushed: options.push
        )
    }

    public func restoreCheckpoint(
        _ checkpoint: CheckpointRecord,
        snapshot: RepositorySnapshot,
        repoURL: URL
    ) throws -> GitCheckpointRestoreResult {
        guard snapshot.isGitRepository else {
            throw GitCheckpointError.notGitRepository
        }

        let rootURL = URL(
            fileURLWithPath: snapshot.rootPath ?? repoURL.path,
            isDirectory: true
        )
        let shouldFetch = checkpoint.pushedAt != nil
        let remoteBranch = "\(checkpoint.remoteName)/\(checkpoint.branch)"

        if shouldFetch {
            try runRequired(
                ["fetch", checkpoint.remoteName, "\(checkpoint.branch):refs/remotes/\(checkpoint.remoteName)/\(checkpoint.branch)"],
                workingDirectory: rootURL
            )
        }

        try switchToRestoredBranch(
            checkpoint.branch,
            remoteBranch: shouldFetch ? remoteBranch : nil,
            workingDirectory: rootURL
        )

        if shouldFetch {
            try runRequired(["merge", "--ff-only", remoteBranch], workingDirectory: rootURL)
        }

        let head = try requiredOutput(["rev-parse", "HEAD"], workingDirectory: rootURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let expected = checkpoint.commitSHA, !expected.isEmpty, head != expected {
            throw GitCheckpointError.checkpointCommitMismatch(expected: expected, actual: head)
        }

        return GitCheckpointRestoreResult(
            checkpoint: checkpoint,
            fetched: shouldFetch,
            switched: true,
            fastForwarded: shouldFetch,
            headSHA: head.isEmpty ? nil : head
        )
    }

    public static func defaultBranch(for task: TaskRecord) -> String {
        "agent/\(task.slug)"
    }

    public static func defaultMessage(for task: TaskRecord) -> String {
        "agentctl checkpoint: \(task.slug)"
    }

    private func switchToBranch(_ branch: String, workingDirectory: URL) throws {
        let switched = try git.run(["switch", branch], workingDirectory: workingDirectory)
        if switched.succeeded {
            return
        }

        try runRequired(["switch", "-c", branch], workingDirectory: workingDirectory)
    }

    private func switchToRestoredBranch(
        _ branch: String,
        remoteBranch: String?,
        workingDirectory: URL
    ) throws {
        let switched = try git.run(["switch", branch], workingDirectory: workingDirectory)
        if switched.succeeded {
            return
        }

        if let remoteBranch {
            try runRequired(["switch", "--track", "-c", branch, remoteBranch], workingDirectory: workingDirectory)
            return
        }

        throw GitCheckpointError.gitFailed(arguments: ["switch", branch], stderr: switched.stderr)
    }

    private func requiredOutput(_ arguments: [String], workingDirectory: URL) throws -> String {
        let result = try git.run(arguments, workingDirectory: workingDirectory)
        guard result.succeeded else {
            throw GitCheckpointError.gitFailed(arguments: arguments, stderr: result.stderr)
        }
        return result.stdout
    }

    private func runRequired(_ arguments: [String], workingDirectory: URL) throws {
        let result = try git.run(arguments, workingDirectory: workingDirectory)
        guard result.succeeded else {
            throw GitCheckpointError.gitFailed(arguments: arguments, stderr: result.stderr)
        }
    }
}
