import Foundation
import MCP
import Testing
@testable import LookinAgentBridge

@MainActor
private final class FixtureProvider: NSObject, AgentDataProvider {
    var pending: ((Data) -> Void)?
    var holdsCalls = false
    var wasCancelled = false
    func toolsJSON() -> Data {
        Data("""
        [{"name":"echo","description":"Fixture","inputSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}]
        """.utf8)
    }

    func performTool(_ name: String, arguments: Data, requestID: String, completion: @escaping (Data) -> Void) {
        if holdsCalls { pending = completion; return }
        let args = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let value = args["value"] as? String ?? ""
        completion(try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": value]],
                                                               "structuredContent": ["value": value], "isError": false]))
    }

    func cancelRequest(_ requestID: String) {
        wasCancelled = true
        pending?(Data("{\"content\":[],\"isError\":true}".utf8))
        pending = nil
    }
}

@Test @MainActor func cancellationReleasesPendingProviderCall() async throws {
    let fixture = FixtureProvider()
    fixture.holdsCalls = true
    let provider = AgentProviderBox(fixture)
    let post = try request("tools/call", params: ["name": "echo", "arguments": ["value": "wait"]])
    let task = Task { await AgentProtocol.respond(to: post, provider: provider) }
    for _ in 0..<100 {
        if fixture.pending != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(fixture.pending != nil)
    task.cancel()
    _ = await task.value
    for _ in 0..<100 {
        if fixture.wasCancelled { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(fixture.wasCancelled)
    #expect(fixture.pending == nil)
}

private func request(_ method: String, params: [String: Any] = [:]) throws -> MCP.HTTPRequest {
    .init(method: "POST", headers: ["Accept": "application/json, text/event-stream", "Content-Type": "application/json"],
          body: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]))
}

@Test @MainActor func officialClientCanUseHTTP() async throws {
    let listener = try await AgentHTTPListener.start(port: 0, provider: AgentProviderBox(FixtureProvider()))
    do {
        let client = Client(name: "Lookin test", version: "1")
        let transport = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(listener.port)/mcp")!)
        _ = try await client.connect(transport: transport)
        let tools = try await client.listTools()
        #expect(tools.tools.map(\.name) == ["echo"])
        let result = try await client.callTool(name: "echo", arguments: ["value": .string("hello")])
        #expect(result.isError != true)
        #expect(result.content == [.text("hello")])
        for method in ["POST", "GET"] {
            var attack = URLRequest(url: URL(string: "http://127.0.0.1:\(listener.port)/mcp")!)
            attack.httpMethod = method
            attack.setValue("https://attacker.example", forHTTPHeaderField: "Origin")
            if method == "POST" { attack.httpBody = Data("{}".utf8) }
            let (_, response) = try await URLSession.shared.data(for: attack)
            #expect((response as? HTTPURLResponse)?.statusCode == 403)
        }
        await client.disconnect()
        await listener.stop()
    } catch {
        await listener.stop()
        throw error
    }
}

@Test @MainActor func equalIDsFromDifferentClientsStaySeparate() async throws {
    let provider = AgentProviderBox(FixtureProvider())
    let a = try request("tools/call", params: ["name": "echo", "arguments": ["value": "first"]])
    let b = try request("tools/call", params: ["name": "echo", "arguments": ["value": "second"]])
    async let first = AgentProtocol.respond(to: a, provider: provider)
    async let second = AgentProtocol.respond(to: b, provider: provider)
    let results = await [first, second]
    #expect(results[0].bodyData.flatMap { String(data: $0, encoding: .utf8) }?.contains("first") == true)
    #expect(results[1].bodyData.flatMap { String(data: $0, encoding: .utf8) }?.contains("second") == true)
}

@Test @MainActor func rejectsWebOriginsAndUnsupportedMethods() async throws {
    let provider = AgentProviderBox(FixtureProvider())
    let post = try request("tools/list")
    let attack = MCP.HTTPRequest(method: "POST", headers: post.headers.merging(["Origin": "https://attacker.example"]) { _, new in new }, body: post.body)
    #expect(await AgentProtocol.respond(to: attack, provider: provider).statusCode == 403)
    #expect(await AgentProtocol.respond(to: .init(method: "GET"), provider: provider).statusCode == 405)
    let invalid = MCP.HTTPRequest(method: "POST", headers: post.headers, body: Data("[]".utf8))
    #expect(await AgentProtocol.respond(to: invalid, provider: provider).statusCode == 400)
}
