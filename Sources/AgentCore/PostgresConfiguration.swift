import Foundation
import PostgresNIO

public enum PostgresConfigurationError: Error, CustomStringConvertible, Sendable {
    case invalidDatabaseURL(String)
    case missingDatabaseURL

    public var description: String {
        switch self {
        case let .invalidDatabaseURL(value):
            return "invalid PostgreSQL database URL: \(value)"
        case .missingDatabaseURL:
            return "missing database URL; pass --database-url or set AGENTCTL_DATABASE_URL"
        }
    }
}

public struct AgentPostgresConfiguration: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var database: String
    public var tlsDisabled: Bool

    public init(
        host: String,
        port: Int = 5432,
        username: String,
        password: String? = nil,
        database: String,
        tlsDisabled: Bool = true
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tlsDisabled = tlsDisabled
    }

    public init(databaseURL: String) throws {
        guard
            let components = URLComponents(string: databaseURL),
            components.scheme == "postgres" || components.scheme == "postgresql",
            let host = components.host
        else {
            throw PostgresConfigurationError.invalidDatabaseURL(databaseURL)
        }

        let database = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !database.isEmpty else {
            throw PostgresConfigurationError.invalidDatabaseURL(databaseURL)
        }

        let sslMode = components.queryItems?.first(where: { $0.name == "sslmode" })?.value

        self.host = host
        self.port = components.port ?? 5432
        self.username = components.user ?? ProcessInfo.processInfo.environment["USER"] ?? "postgres"
        self.password = components.password
        self.database = database
        self.tlsDisabled = sslMode == nil || sslMode == "disable"
    }

    public var postgresClientConfiguration: PostgresClient.Configuration {
        PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
    }
}
