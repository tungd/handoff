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
}
