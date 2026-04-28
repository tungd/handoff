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
    func tablesRenderAlignedRowsAndStyledCells() {
        let lines = agentTUIMarkdownStyledLines(
            """
            | Name | Status |
            | ---- | ------ |
            | API | **done** |
            """,
            width: 80
        )

        #expect(lines.map(agentTUIPlainText) == [
            "Name │ Status",
            "─────┼───────",
            "API  │ done"
        ])
        #expect(span(containing: "Name", in: lines[0])?.isBold == true)
        #expect(span(containing: "Status", in: lines[0])?.isBold == true)
        #expect(span(containing: "done", in: lines[2])?.isBold == true)
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
}

private func span(
    containing needle: String,
    in spans: [AgentTUIStyledTextSpan]
) -> AgentTUIStyledTextSpan? {
    spans.first { $0.text.contains(needle) }
}
