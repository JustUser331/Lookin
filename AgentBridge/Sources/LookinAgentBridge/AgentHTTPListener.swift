import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

final class AgentHTTPListener: @unchecked Sendable {

    // MARK: - Properties

    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    let port: Int

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel) {
        self.group = group
        self.channel = channel
        port = channel.localAddress?.port ?? 47199
    }

    // MARK: - Public Methods

    static func start(port: Int, provider: AgentProviderBox) async throws -> AgentHTTPListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandlers([
                            IdleStateHandler(readTimeout: .seconds(45)),
                            AgentHTTPHandler(provider: provider)
                        ])
                    }
                }.bind(host: "127.0.0.1", port: port).get()
            return AgentHTTPListener(group: group, channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}

private final class AgentHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    // MARK: - Properties

    private let provider: AgentProviderBox
    private var head: HTTPRequestHead?
    private var body = Data()
    private var task: Task<Void, Never>?
    private var deadline: Scheduled<Void>?
    private var responded = false
    private var executing = false

    init(provider: AgentProviderBox) { self.provider = provider }

    // MARK: - Public Methods

    func channelActive(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(5)) { [weak self] in
            self?.send(context, status: 408, headers: [:], data: Data())
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard self.head == nil, !executing else {
                send(context, status: 400, headers: [:], data: Data()); return
            }
            guard head.uri == "/mcp" else {
                send(context, status: 404, headers: [:], data: Data()); return
            }
            let host = head.headers["host"].first?.lowercased() ?? ""
            let hostname = host.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard head.headers["host"].count == 1, ["127.0.0.1", "localhost"].contains(hostname),
                  head.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16_384 else {
                send(context, status: 403, headers: [:], data: Data()); return
            }
            let fields = Dictionary(head.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { $0 + "," + $1 })
            if head.headers["origin"].count > 1 {
                send(context, status: 403, headers: [:], data: Data()); return
            }
            let validation = HTTPValidationContext(httpMethod: head.method.rawValue)
            if let denied = OriginValidator.localhost().validate(.init(method: head.method.rawValue, headers: fields), context: validation) {
                send(context, status: denied.statusCode, headers: denied.headers, data: denied.bodyData ?? Data()); return
            }
            self.head = head
        case .body(var buffer):
            guard !executing, body.count + buffer.readableBytes <= 1_048_576 else {
                send(context, status: 413, headers: [:], data: Data()); return
            }
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            guard let head, !executing else { return }
            executing = true
            deadline?.cancel()
            deadline = context.eventLoop.scheduleTask(in: .seconds(40)) { [weak self] in
                self?.task?.cancel()
                self?.send(context, status: 504, headers: [:], data: Data())
            }
            let headers = Dictionary(head.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { $0 + "," + $1 })
            let request = MCP.HTTPRequest(method: head.method.rawValue, headers: headers, body: body)
            task = Task { [provider, weak self] in
                let response = await AgentProtocol.respond(to: request, provider: provider)
                context.eventLoop.execute {
                    self?.send(context, status: response.statusCode, headers: response.headers, data: response.bodyData ?? Data())
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        task?.cancel()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        task?.cancel()
        send(context, status: 400, headers: [:], data: Data())
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            task?.cancel()
            context.close(promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }

    // MARK: - Private Methods

    private func send(_ context: ChannelHandlerContext, status: Int, headers: [String: String], data: Data) {
        guard !responded else { return }
        responded = true
        deadline?.cancel()
        var fields = HTTPHeaders(headers.map { ($0.key, $0.value) })
        fields.replaceOrAdd(name: "Content-Length", value: String(data.count))
        fields.replaceOrAdd(name: "Connection", value: "close")
        fields.replaceOrAdd(name: "Cache-Control", value: "no-store")
        if status == 405 { fields.replaceOrAdd(name: "Allow", value: "POST") }
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .init(statusCode: status), headers: fields))), promise: nil)
        if !data.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}
