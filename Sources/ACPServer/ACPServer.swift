import Foundation
import AgentCore
import ACP
import ACPModel

public actor ACPServer {
    private let transport: StdinTransport
    private let agent: Agent
    private let sessionManager: ACPSessionManager
    private let sessionController: AgentSessionController
    private let store: any AgentTaskStore
    private let delegate: ACPAgentDelegate

    public init(store: any AgentTaskStore) async {
        self.transport = StdinTransport()
        self.agent = Agent(transport: transport)
        self.sessionManager = ACPSessionManager(store: store)
        self.sessionController = AgentSessionController(store: store)
        self.store = store
        self.delegate = ACPAgentDelegate(
            sessionManager: sessionManager,
            sessionController: sessionController,
            store: store,
            agent: agent
        )
    }

    public func start() async {
        await agent.setDelegate(delegate)
        await transport.start()
        await agent.start()
    }

    public func stop() async {
        await agent.close()
    }
}