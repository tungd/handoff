import Foundation

public struct RepositorySnapshot: Codable, Equatable, Sendable {
    public var isGitRepository: Bool
    public var rootPath: String?
    public var originURL: String?
    public var currentBranch: String?
    public var headSHA: String?
    public var isDirty: Bool
    public var porcelainStatus: String

    public init(
        isGitRepository: Bool,
        rootPath: String? = nil,
        originURL: String? = nil,
        currentBranch: String? = nil,
        headSHA: String? = nil,
        isDirty: Bool = false,
        porcelainStatus: String = ""
    ) {
        self.isGitRepository = isGitRepository
        self.rootPath = rootPath
        self.originURL = originURL
        self.currentBranch = currentBranch
        self.headSHA = headSHA
        self.isDirty = isDirty
        self.porcelainStatus = porcelainStatus
    }
}

public struct RepositoryInspector: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    public func inspect(path: URL) throws -> RepositorySnapshot {
        let root = try git.run(["rev-parse", "--show-toplevel"], workingDirectory: path)

        guard root.succeeded else {
            return RepositorySnapshot(isGitRepository: false)
        }

        let rootPath = root.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        let originURL = try optionalGitOutput(["remote", "get-url", "origin"], workingDirectory: rootURL)
        let branch = try optionalGitOutput(["branch", "--show-current"], workingDirectory: rootURL)
        let head = try optionalGitOutput(["rev-parse", "HEAD"], workingDirectory: rootURL)

        let status = try git.run(["status", "--porcelain=v1"], workingDirectory: rootURL)
        let statusText = status.succeeded ? status.stdout : ""

        return RepositorySnapshot(
            isGitRepository: true,
            rootPath: rootPath,
            originURL: originURL,
            currentBranch: branch?.isEmpty == false ? branch : nil,
            headSHA: head,
            isDirty: !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            porcelainStatus: statusText
        )
    }

    private func optionalGitOutput(_ arguments: [String], workingDirectory: URL) throws -> String? {
        let result = try git.run(arguments, workingDirectory: workingDirectory)
        guard result.succeeded else {
            return nil
        }

        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
