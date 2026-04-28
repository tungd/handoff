import Testing
import TUIkit
@testable import agentctl

@MainActor
@Suite("AgentTUI composer")
struct AgentTUIComposerTests {
    @Test
    func dividerPlacesModelAfterTwoRuleCharacters() {
        let line = agentTUIHorizontalDivider(label: "gpt-5.5 (xhigh)", width: 48)

        #expect(line == "── gpt-5.5 (xhigh) ─────────────────────────────")
        #expect(line.count == 48)
    }

    @Test
    func statusLineRightAlignsTokenStatus() {
        let line = agentTUIStatusLine(
            repoBranchText: "~/Projects/personal/agent (main)",
            badges: [],
            tokenStatus: "↑5.1k ↓579 R7.8k 4.2%/258.4k",
            width: 80
        )

        #expect(line == "~/Projects/personal/agent (main)                    ↑5.1k ↓579 R7.8k 4.2%/258.4k")
        #expect(line.count == 80)
        #expect(line.hasSuffix("↑5.1k ↓579 R7.8k 4.2%/258.4k"))
    }

    @Test
    func chromeSnapshotRendersExpectedRows() {
        let view = VStack(alignment: .leading, spacing: 0) {
            Text(agentTUIHorizontalDivider(label: "gpt-5.5 (xhigh)", width: 48))
            Text("█")
            Text(agentTUIHorizontalDivider(label: nil, width: 48))
            Text(agentTUIStatusLine(
                repoBranchText: "~/Projects/personal/agent (main)",
                badges: [],
                tokenStatus: "↑5.1k ↓579 2.0%/258.4k",
                width: 48
            ))
        }

        var environment = EnvironmentValues()
        environment.stateStorage = StateStorage()
        let context = RenderContext(
            availableWidth: 48,
            availableHeight: 8,
            environment: environment
        )
        let buffer = renderToBuffer(view, context: context)

        #expect(buffer.lines.map { $0.stripped } == [
            "── gpt-5.5 (xhigh) ─────────────────────────────",
            "█                                               ",
            "────────────────────────────────────────────────",
            "~/Projects/...gent (main) ↑5.1k ↓579 2.0%/258.4k"
        ])
    }
}
