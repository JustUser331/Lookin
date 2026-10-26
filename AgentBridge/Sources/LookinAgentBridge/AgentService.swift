import Foundation
import MCP

@MainActor
@objc(LKAgentDataProvider)
public protocol AgentDataProvider: AnyObject {
    func toolsJSON() -> Data
    func performTool(_ name: String, arguments: Data, requestID: String, completion: @escaping (Data) -> Void)
    func cancelRequest(_ requestID: String)
}

@MainActor
final class AgentProviderBox {
    let value: any AgentDataProvider
    init(_ value: any AgentDataProvider) { self.value = value }
    func toolsJSON() -> Data { value.toolsJSON() }
    func performTool(_ name: String, arguments: Data, requestID: String, completion: @escaping (Data) -> Void) {
        value.performTool(name, arguments: arguments, requestID: requestID, completion: completion)
    }
    func cancelRequest(_ identifier: String) { value.cancelRequest(identifier) }
}

@MainActor
@objc(LKAgentService)
public final class AgentService: NSObject {

    // MARK: - Properties

    @objc public static let shared = AgentService()
    @objc public private(set) var status = "Stopped"
    @objc public private(set) var endpoint = "http://127.0.0.1:47199/mcp"
    private var listener: AgentHTTPListener?
    private var provider: (any AgentDataProvider)?

    // MARK: - Public Methods

    @objc(startWithProvider:)
    public func start(provider: any AgentDataProvider) {
        guard listener == nil else { return }
        self.provider = provider
        status = "Starting"
        Task {
            do {
                let listener = try await AgentHTTPListener.start(port: 47199, provider: AgentProviderBox(provider))
                self.listener = listener
                self.status = "Listening at \(endpoint)"
            } catch {
                status = "Unable to start MCP: \(error.localizedDescription). Close other Lookin instances using port 47199."
            }
        }
    }

    @objc public func stop() {
        let active = listener
        listener = nil
        status = "Stopped"
        Task { await active?.stop() }
    }
}

enum AgentProtocol {

    // MARK: - Public Methods

    static func respond(to request: HTTPRequest, provider: AgentProviderBox) async -> HTTPResponse {
        // Отдельный обработчик на HTTP-запрос исключает коллизии id разных клиентов.
        let transport = StatelessHTTPServerTransport()
        let scope = await AgentRequestScope(provider: provider)
        let server = Server(name: "lookin-agent", version: "1.0.0", instructions:
            "Inspect running iOS apps. Start with list_apps, connect_app, then get_snapshot. " +
            "Use snapshot-bound node refs for get_node/get_image. Refresh invalidates refs. " +
            "Tree, attributes and images may be captured at different times; inspect readiness fields.",
            capabilities: .init(tools: .init(listChanged: false)))
        do {
            let tools = try await JSONDecoder().decode([Tool].self, from: provider.toolsJSON())
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
            await server.withMethodHandler(CallTool.self) { parameters in
                guard tools.contains(where: { $0.name == parameters.name }) else {
                    throw MCPError.invalidParams("Unknown Lookin tool: \(parameters.name)")
                }
                let identifier = UUID().uuidString
                let arguments = try JSONEncoder().encode(parameters.arguments ?? [:])
                let call = await scope.makeCall(identifier: identifier)
                let result = await withTaskCancellationHandler {
                    await call.run(name: parameters.name, arguments: arguments)
                } onCancel: {
                    Task { @MainActor in call.cancel() }
                }
                do { return try JSONDecoder().decode(CallTool.Result.self, from: result) }
                catch { throw MCPError.internalError("Invalid tool result: \(String(reflecting: error))") }
            }
            try await server.start(transport: transport)
            let response = await withTaskCancellationHandler {
                await transport.handleRequest(request)
            } onCancel: {
                Task { await scope.cancel(); await server.stop() }
            }
            await scope.cancel()
            await server.stop()
            return response
        } catch {
            await scope.cancel()
            await server.stop()
            return .error(statusCode: 500, .internalError(error.localizedDescription))
        }
    }
}

@MainActor
private final class AgentRequestScope {
    private let provider: AgentProviderBox
    private var call: AgentCall?
    private var cancelled = false
    init(provider: AgentProviderBox) { self.provider = provider }
    func makeCall(identifier: String) -> AgentCall {
        let call = AgentCall(provider: provider, identifier: identifier)
        self.call = call
        if cancelled { call.cancel() }
        return call
    }
    func cancel() { cancelled = true; call?.cancel() }
}

@MainActor
private final class AgentCall {

    // MARK: - Properties

    private let provider: AgentProviderBox
    private let identifier: String
    private var continuation: CheckedContinuation<Data, Never>?
    private var cancelled = false
    private var finished = false
    private let cancellationResult = Data("{\"content\":[{\"type\":\"text\",\"text\":\"Request cancelled\"}],\"isError\":true}".utf8)

    init(provider: AgentProviderBox, identifier: String) {
        self.provider = provider
        self.identifier = identifier
    }

    // MARK: - Public Methods

    func run(name: String, arguments: Data) async -> Data {
        if cancelled { return cancellationResult }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            provider.performTool(name, arguments: arguments, requestID: identifier) { [self] result in finish(result) }
        }
    }

    func cancel() {
        guard !finished else { return }
        cancelled = true
        provider.cancelRequest(identifier)
        finish(cancellationResult)
    }

    // MARK: - Private Methods

    private func finish(_ result: Data) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: result)
        continuation = nil
    }
}
