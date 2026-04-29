import Foundation

public enum SchemaLoaderError: Error, CustomStringConvertible, Sendable {
    case missingMigration(String)

    public var description: String {
        switch self {
        case let .missingMigration(name):
            return "missing bundled migration: \(name)"
        }
    }
}

public enum SchemaLoader {
    public static func initialMigration() throws -> String {
        let url = Bundle.module.url(
            forResource: "001_initial",
            withExtension: "sql",
            subdirectory: "migrations"
        ) ?? Bundle.module.url(
            forResource: "001_initial",
            withExtension: "sql"
        )

        guard let url else {
            throw SchemaLoaderError.missingMigration("001_initial.sql")
        }

        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func allMigrations() throws -> [(name: String, sql: String)] {
        var migrations: [(name: String, sql: String)] = []

        // Add initial migration
        migrations.append((name: "001_initial", sql: try initialMigration()))

        // Add skills migration
        if let url = Bundle.module.url(
            forResource: "002_skills",
            withExtension: "sql",
            subdirectory: "migrations"
        ) ?? Bundle.module.url(
            forResource: "002_skills",
            withExtension: "sql"
        ) {
            migrations.append((name: "002_skills", sql: try String(contentsOf: url, encoding: .utf8)))
        }

        return migrations
    }

    public static func allMigrationStatements() throws -> [String] {
        let migrations = try allMigrations()
        var statements: [String] = []

        for (_, sql) in migrations {
            let parsed = sql
                .split(separator: ";", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            statements.append(contentsOf: parsed)
        }

        return statements
    }
}
