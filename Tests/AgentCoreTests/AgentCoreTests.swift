import Foundation
import Testing
@testable import AgentCore

@Test
func jsonValueRoundTripsNestedObjects() throws {
    let value: JSONValue = .object([
        "text": .string("hello"),
        "count": .int(2),
        "nested": .array([.bool(true), .null])
    ])

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    #expect(decoded == value)
}

@Test
func slugGenerationIsStable() {
    #expect(Slug.make("Fix Auth Retry!") == "fix-auth-retry")
    #expect(Slug.make("   ") == "task")
}

@Test
func schemaLoaderFindsInitialMigration() throws {
    let schema = try SchemaLoader.initialMigration()

    #expect(schema.contains("CREATE TABLE IF NOT EXISTS tasks"))
    #expect(schema.contains("CREATE TABLE IF NOT EXISTS memory_items"))
}
