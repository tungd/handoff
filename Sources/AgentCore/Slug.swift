import Foundation

public enum Slug {
    public static func make(_ input: String, maxLength: Int = 64) -> String {
        let lowercased = input.lowercased()
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }

        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        if collapsed.isEmpty {
            return "task"
        }

        if collapsed.count <= maxLength {
            return collapsed
        }

        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
