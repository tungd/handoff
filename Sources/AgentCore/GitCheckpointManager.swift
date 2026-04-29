import Foundation

public enum GitCheckpointError: Error, CustomStringConvertible, Sendable {
    case notGitRepository
    case dirtyWorktree(status: String)
    case checkpointUnavailable(branch: String, remote: String?, stderr: String)
    case divergentCheckpointBranch(branch: String, remote: String, stderr: String)
    case checkpointCommitMismatch(expected: String, actual: String)
    case gitFailed(arguments: [String], stderr: String)

    public var description: String {
        switch self {
        case .notGitRepository:
            return "checkpoint requires a git repository"
        case let .dirtyWorktree(status):
            return "restore requires a clean worktree; commit, stash, or checkpoint these changes first:\n\(status.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .checkpointUnavailable(branch, remote, stderr):
            let location = remote.map { "\($0)/\(branch)" } ?? branch
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "checkpoint branch \(location) is not available" : "checkpoint branch \(location) is not available: \(detail)"
        case let .divergentCheckpointBranch(branch, remote, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "checkpoint branch \(branch) diverged from \(remote)/\(branch); resolve it manually before resume"
                : "checkpoint branch \(branch) diverged from \(remote)/\(branch): \(detail)"
        case let .checkpointCommitMismatch(expected, actual):
            return "checkpoint restore ended at \(actual), expected \(expected)"
        case let .gitFailed(arguments, stderr):
            let command = (["git"] + arguments).joined(separator: " ")
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(command) failed" : "\(command) failed: \(detail)"
        }
    }
}

public struct HandoffCommandOutput: Codable, Sendable, Equatable {
    public var command: String
    public var exitCode: Int32
    public var output: String

    public init(command: String, exitCode: Int32, output: String) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
    }
}

public struct HandoffTestResult: Codable, Sendable, Equatable {
    public var command: String
    public var status: String
    public var output: String?

    public init(command: String, status: String, output: String? = nil) {
        self.command = command
        self.status = status
        self.output = output
    }
}

public struct HandoffManifest: Codable, Sendable, Equatable {
    public var changedFiles: [String]
    public var generatedFiles: [String]
    public var commandOutputs: [HandoffCommandOutput]
    public var testResults: [HandoffTestResult]
    public var inspectNext: [String]

    public init(
        changedFiles: [String] = [],
        generatedFiles: [String] = [],
        commandOutputs: [HandoffCommandOutput] = [],
        testResults: [HandoffTestResult] = [],
        inspectNext: [String] = []
    ) {
        self.changedFiles = changedFiles
        self.generatedFiles = generatedFiles
        self.commandOutputs = commandOutputs
        self.testResults = testResults
        self.inspectNext = inspectNext
    }

    public var jsonValue: JSONValue {
        .object([
            "changedFiles": .array(changedFiles.map { .string($0) }),
            "generatedFiles": .array(generatedFiles.map { .string($0) }),
            "commandOutputs": .array(commandOutputs.map {
                .object([
                    "command": .string($0.command),
                    "exitCode": .int(Int64($0.exitCode)),
                    "output": .string($0.output)
                ])
            }),
            "testResults": .array(testResults.map {
                var object: [String: JSONValue] = [
                    "command": .string($0.command),
                    "status": .string($0.status)
                ]
                if let output = $0.output {
                    object["output"] = .string(output)
                }
                return .object(object)
            }),
            "inspectNext": .array(inspectNext.map { .string($0) })
        ])
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
    public var manifest: HandoffManifest

    public init(
        checkpoint: CheckpointRecord,
        dirtyStatus: String,
        committed: Bool,
        pushed: Bool,
        manifest: HandoffManifest
    ) {
        self.checkpoint = checkpoint
        self.dirtyStatus = dirtyStatus
        self.committed = committed
        self.pushed = pushed
        self.manifest = manifest
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
        options: GitCheckpointOptions = GitCheckpointOptions(),
        manifestContext: HandoffManifest = HandoffManifest()
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
        let dirtyStatus = try workingTreeStatus(workingDirectory: rootURL)
        let hasChanges = !dirtyStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let changedFiles = Self.unique(manifestContext.changedFiles + Self.changedFiles(from: dirtyStatus))
        let generatedFiles = Self.unique(manifestContext.generatedFiles + Self.generatedFiles(from: dirtyStatus))
        var commandOutputs: [HandoffCommandOutput] = manifestContext.commandOutputs

        if hasChanges {
            try runRequired(["add", "-A", "--", ".", ":!.agentctl"], workingDirectory: rootURL)
            let output = try runRequiredCapture(
                ["commit", "-m", options.message ?? Self.defaultMessage(for: task)],
                workingDirectory: rootURL
            )
            commandOutputs.append(HandoffCommandOutput(
                command: "git commit",
                exitCode: 0,
                output: Self.truncated(output)
            ))
        }

        let head = try requiredOutput(["rev-parse", "HEAD"], workingDirectory: rootURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pushedAt: Date?
        if options.push {
            let output = try runRequiredCapture(["push", "-u", options.remoteName, branch], workingDirectory: rootURL)
            commandOutputs.append(HandoffCommandOutput(
                command: "git push -u \(options.remoteName) \(branch)",
                exitCode: 0,
                output: Self.truncated(output)
            ))
            pushedAt = Date()
        } else {
            pushedAt = nil
        }

        let manifest = HandoffManifest(
            changedFiles: changedFiles,
            generatedFiles: generatedFiles,
            commandOutputs: commandOutputs,
            testResults: manifestContext.testResults,
            inspectNext: Self.unique(manifestContext.inspectNext + changedFiles.prefix(12).map { "Review \($0)" })
        )
        let checkpoint = CheckpointRecord(
            taskID: task.id,
            branch: branch,
            commitSHA: head.isEmpty ? nil : head,
            remoteName: options.remoteName,
            pushedAt: pushedAt,
            metadata: [
                "handoffManifest": manifest.jsonValue,
                "changedFiles": .array(changedFiles.map { .string($0) }),
                "generatedFiles": .array(generatedFiles.map { .string($0) }),
                "pushed": .bool(options.push),
                "dirtyStatus": .string(dirtyStatus)
            ]
        )

        return GitCheckpointResult(
            checkpoint: checkpoint,
            dirtyStatus: dirtyStatus,
            committed: hasChanges,
            pushed: options.push,
            manifest: manifest
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
        let dirtyStatus = try workingTreeStatus(workingDirectory: rootURL)
        if !dirtyStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GitCheckpointError.dirtyWorktree(status: dirtyStatus)
        }

        if shouldFetch {
            let fetch = try git.run(
                ["fetch", checkpoint.remoteName, "\(checkpoint.branch):refs/remotes/\(checkpoint.remoteName)/\(checkpoint.branch)"],
                workingDirectory: rootURL
            )
            guard fetch.succeeded else {
                throw GitCheckpointError.checkpointUnavailable(
                    branch: checkpoint.branch,
                    remote: checkpoint.remoteName,
                    stderr: fetch.stderr
                )
            }
        }

        try switchToRestoredBranch(
            checkpoint.branch,
            remoteBranch: shouldFetch ? remoteBranch : nil,
            workingDirectory: rootURL
        )

        if shouldFetch {
            let merge = try git.run(["merge", "--ff-only", remoteBranch], workingDirectory: rootURL)
            guard merge.succeeded else {
                throw GitCheckpointError.divergentCheckpointBranch(
                    branch: checkpoint.branch,
                    remote: checkpoint.remoteName,
                    stderr: merge.stderr
                )
            }
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

    public static func changedFiles(from porcelainStatus: String) -> [String] {
        Array(Set(porcelainStatus.split(separator: "\n").compactMap { porcelainPath(String($0)) })).sorted()
    }

    public static func generatedFiles(from porcelainStatus: String) -> [String] {
        Array(Set(porcelainStatus.split(separator: "\n").compactMap { line -> String? in
            line.hasPrefix("??") ? porcelainPath(String(line)) : nil
        })).sorted()
    }

    private static func porcelainPath(_ line: String) -> String? {
        guard line.count >= 4 else {
            return nil
        }
        let rawPath = String(line.dropFirst(3))
        if let range = rawPath.range(of: " -> ") {
            return String(rawPath[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return rawPath.trimmingCharacters(in: .whitespaces)
    }

    private static func truncated(_ output: String, limit: Int = 4_000) -> String {
        guard output.count > limit else {
            return output
        }
        return String(output.suffix(limit))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            seen.insert(value).inserted
        }
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
            let tracked = try git.run(["switch", "--track", "-c", branch, remoteBranch], workingDirectory: workingDirectory)
            guard tracked.succeeded else {
                let remoteName = remoteBranch.split(separator: "/").first.map(String.init)
                throw GitCheckpointError.checkpointUnavailable(branch: branch, remote: remoteName, stderr: tracked.stderr)
            }
            return
        }

        throw GitCheckpointError.checkpointUnavailable(branch: branch, remote: nil, stderr: switched.stderr)
    }

    private func requiredOutput(_ arguments: [String], workingDirectory: URL) throws -> String {
        let result = try git.run(arguments, workingDirectory: workingDirectory)
        guard result.succeeded else {
            throw GitCheckpointError.gitFailed(arguments: arguments, stderr: result.stderr)
        }
        return result.stdout
    }

    private func workingTreeStatus(workingDirectory: URL) throws -> String {
        try requiredOutput(["status", "--porcelain=v1", "--", ".", ":!.agentctl"], workingDirectory: workingDirectory)
    }

    private func runRequired(_ arguments: [String], workingDirectory: URL) throws {
        let result = try git.run(arguments, workingDirectory: workingDirectory)
        guard result.succeeded else {
            throw GitCheckpointError.gitFailed(arguments: arguments, stderr: result.stderr)
        }
    }

    private func runRequiredCapture(_ arguments: [String], workingDirectory: URL) throws -> String {
        let result = try git.run(arguments, workingDirectory: workingDirectory)
        guard result.succeeded else {
            throw GitCheckpointError.gitFailed(arguments: arguments, stderr: result.stderr)
        }
        return [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
