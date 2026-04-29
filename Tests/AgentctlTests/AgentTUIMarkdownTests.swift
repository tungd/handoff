import AgentCore
import Testing
@testable import agentctl

@Suite("AgentTUI markdown rendering")
struct AgentTUIMarkdownTests {
    @Test
    func inlineMarkdownProducesStyledSpans() {
        let lines = agentTUIMarkdownStyledLines(
            "Hello **bold** *italic* <u>under</u> [OpenAI](https://openai.com)",
            width: 120
        )

        #expect(lines.map(agentTUIPlainText) == [
            "Hello bold italic under OpenAI (https://openai.com)"
        ])
        #expect(span(containing: "bold", in: lines[0])?.isBold == true)
        #expect(span(containing: "italic", in: lines[0])?.isItalic == true)
        #expect(span(containing: "under", in: lines[0])?.isUnderlined == true)

        let link = span(containing: "OpenAI", in: lines[0])
        #expect(link?.isUnderlined == true)
        #expect(link?.tone == .accent)

        let url = span(containing: "https://openai.com", in: lines[0])
        #expect(url?.tone == .secondary)
    }

    @Test
    func listsNormalizeMarkersAndKeepInlineStyles() {
        let lines = agentTUIMarkdownStyledLines(
            """
            - **Fix** render
            1. <u>Ship</u> it
            """,
            width: 80
        )

        #expect(lines.map(agentTUIPlainText) == [
            "• Fix render",
            "1. Ship it"
        ])
        #expect(span(containing: "Fix", in: lines[0])?.isBold == true)
        #expect(span(containing: "Ship", in: lines[1])?.isUnderlined == true)
    }

    @Test
    func tablesRenderAlignedRowsAsStablePrecomposedLines() {
        let lines = agentTUIMarkdownStyledLines(
            """
            | Name | Status |
            | ---- | ------ |
            | API | **done** |
            """,
            width: 80
        )

        #expect(lines.map(agentTUIPlainText) == [
            "┌──────┬────────┐",
            "│ Name │ Status │",
            "├──────┼────────┤",
            "│ API  │ done   │",
            "└──────┴────────┘"
        ])
        #expect(lines.allSatisfy { $0.count == 1 })
        #expect(lines.allSatisfy { $0.first?.preservesLayout == true })
        #expect(lines.allSatisfy { $0.first?.tone == .base })
    }

    @Test
    func wideTablesWrapCellContentWithoutBreakingSeparators() {
        let lines = agentTUIMarkdownStyledLines(
            """
            | Area | Status |
            | ---- | ------ |
            | Swift package/build/tests | Implemented, `swift test` passes 20 tests |
            """,
            width: 40
        )
        let plain = lines.map(agentTUIPlainText)

        #expect(plain == [
            "┌──────────────────┬───────────────────┐",
            "│ Area             │ Status            │",
            "├──────────────────┼───────────────────┤",
            "│ Swift            │ Implemented,      │",
            "│ package/build/te │ `swift test`      │",
            "│ sts              │ passes 20 tests   │",
            "└──────────────────┴───────────────────┘"
        ])
        #expect(plain.dropFirst(3).dropLast().allSatisfy { $0.contains("│") })
        #expect(lines.allSatisfy { $0.count == 1 })
        #expect(lines.allSatisfy { $0.first?.preservesLayout == true })
    }

    @Test
    func wrapsStyledTextWithoutKeepingMarkdownDelimiters() {
        let lines = agentTUIMarkdownStyledLines("A **bold value** wraps cleanly", width: 13)

        #expect(lines.map(agentTUIPlainText) == [
            "A bold value",
            "wraps cleanly"
        ])
        #expect(span(containing: "bold", in: lines[0])?.isBold == true)
        #expect(span(containing: "value", in: lines[0])?.isBold == true)
    }

    @Test
    func quoteLinesRenderWithQuoteBarAndItalicText() {
        let lines = agentTUIQuoteStyledLines("How **far** is it?", width: 80)

        #expect(lines.map(agentTUIPlainText) == [
            "┃ How far is it?"
        ])
        #expect(lines[0].count == 1)
        #expect(lines[0].first?.text == "┃ How far is it?")
        #expect(lines[0].first?.tone == .quote)
        #expect(lines[0].first?.isItalic == true)
        #expect(lines[0].first?.preservesLayout == true)
    }

    @Test
    func toolCallsRenderBriefStatusLines() {
        let payload: [String: JSONValue] = [
            "command": .string("/bin/zsh -lc 'pnpm -C cli test --run --no-color'")
        ]
        let line = agentTUIToolCallStyledLine(
            agentTUIToolCallText(from: payload),
            status: .succeeded
        )

        #expect(agentTUIPlainText(line) == "✓ Bash pnpm -C cli test --run --no-color")
        #expect(line.count == 1)
        #expect(line[0].tone == .success)
        #expect(line[0].isBold == true)
        #expect(line[0].preservesLayout == true)
    }

    @Test
    func transcriptIndentKeepsPreservedToolLinesSingleSpan() {
        let line = agentTUIIndentedTranscriptSpans([
            AgentTUIStyledTextSpan("✓ Bash swift test", isBold: true, tone: .success, preservesLayout: true)
        ])

        #expect(line.count == 1)
        #expect(agentTUIPlainText(line) == "  ✓ Bash swift test")
        #expect(line[0].tone == .success)
        #expect(line[0].isBold == true)
        #expect(line[0].preservesLayout == true)
    }

    @Test
    func toolOutputShowsShellCommandAndTruncatedTail() {
        let payload: [String: JSONValue] = [
            "command": .string("/bin/zsh -lc 'pnpm test'"),
            "output": .string((1...14).map { "line \($0)" }.joined(separator: "\n"))
        ]

        let text = agentTUIToolOutputText(from: payload, maxLines: 3)

        #expect(text == """
        $ pnpm test
        [... 11 lines truncated ...]
        line 12
        line 13
        line 14
        """)

        let rendered = agentTUIToolOutputStyledLines(text ?? "", width: 80)
        #expect(rendered.first?.count == 1)
        #expect(rendered.first.map(agentTUIPlainText) == "$ pnpm test")
    }

    @Test
    func hydratedTranscriptTextKeepsRecentTail() {
        let text = "abcdef"
        let truncated = agentTUIHydratedTranscriptText(text, limit: 3)

        #expect(truncated == "[... 3 chars truncated from earlier transcript ...]\ndef")
        #expect(agentTUIHydratedTranscriptText(text, limit: 10) == text)
    }
}

private func span(
    containing needle: String,
    in spans: [AgentTUIStyledTextSpan]
) -> AgentTUIStyledTextSpan? {
    spans.first { $0.text.contains(needle) }
}
