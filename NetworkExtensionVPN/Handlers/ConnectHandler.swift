
import NIOCore
import NIOPosix
import NIOHTTP1
import Foundation

final class HttpHttpsConnectHandler {
    private var upgradeState: State
    
    private var bufferedBody: ByteBuffer?
    private var bufferedEnd: HTTPHeaders?
    
    init() {
        self.upgradeState = .idle
    }
}

fileprivate extension HttpHttpsConnectHandler {
    enum State {
        case idle
        case beganConnecting
        case awaitingEnd(connectResult: Channel)
        case awaitingConnection(pendingBytes: [NIOAny])
        case upgradeComplete(pendingBytes: [NIOAny])
        case upgradeFailed
        case pendingConnection(head: HTTPRequestHead)
        case connected
    }
}

extension HttpHttpsConnectHandler: ChannelDuplexHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPClientRequestPart
    typealias OutboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPServerResponsePart
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        
        let dataNew = self.unwrapInboundIn(data)
        
        if case .head(let head) = dataNew {
            DispatchQueue.main.async {
                let taskObject = Packet()
                taskObject.name = "\(head.method) \(head.uri) \(head.version) \(Date().timeIntervalSince1970)"
                do {
                    try realm.write {
                        realm.add(taskObject)
                    }
                } catch let error {
                    print(error.localizedDescription)
                }
            }
        }
        
        switch self.upgradeState {
        case .idle, .pendingConnection(head: _), .connected:
            self.handleInitialMessage(context: context, data: self.unwrapInboundIn(data))
            
        case .beganConnecting:
            // We got .end, we're still waiting on the connection
            if case .end = self.unwrapInboundIn(data) {
                self.upgradeState = .awaitingConnection(pendingBytes: [])
                self.removeDecoder(context: context)
            }
            
        case .awaitingEnd(let peerChannel):
            if case .end = self.unwrapInboundIn(data) {
                // Upgrade has completed!
                self.upgradeState = .upgradeComplete(pendingBytes: [])
                self.removeDecoder(context: context)
                self.glue(peerChannel, context: context)
            }
            
        case .awaitingConnection(var pendingBytes):
            // We've seen end, this must not be HTTP anymore. Danger, Will Robinson! Do not unwrap.
            self.upgradeState = .awaitingConnection(pendingBytes: [])
            pendingBytes.append(data)
            self.upgradeState = .awaitingConnection(pendingBytes: pendingBytes)
            
        case .upgradeComplete(pendingBytes: var pendingBytes):
            // We're currently delivering data, keep doing so.
            self.upgradeState = .upgradeComplete(pendingBytes: [])
            pendingBytes.append(data)
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)
            
        case .upgradeFailed:
            break
        }
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.unwrapOutboundIn(data) {
        case .head(let head):
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        case .body(let body):
            context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        case .end(let trailers):
            context.write(self.wrapOutboundOut(.end(trailers)), promise: nil)
        }
    }
}


extension HttpHttpsConnectHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        var didRead = false
        
        // We are being removed, and need to deliver any pending bytes we may have if we're upgrading.
        while case .upgradeComplete(var pendingBytes) = self.upgradeState, !pendingBytes.isEmpty {
            // Avoid a CoW while we pull some data out.
            self.upgradeState = .upgradeComplete(pendingBytes: [])
            let nextRead = pendingBytes.removeFirst()
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)
            
            context.fireChannelRead(nextRead)
            didRead = true
        }
        
        if didRead {
            context.fireChannelReadComplete()
        }
        
        context.leavePipeline(removalToken: removalToken)
    }
}

extension HttpHttpsConnectHandler {
    private func handleInitialMessage(context: ChannelHandlerContext, data: InboundIn) {
        guard case .head(let head) = data else {
            switch data {
            case .body(let buffer):
                switch upgradeState {
                case .connected:
                    context.fireChannelRead(self.wrapInboundOut(.body(.byteBuffer(buffer))))
                case .pendingConnection:
                    self.bufferedBody = buffer
                default:
                    break
                }
            case .end(let headers):
                switch upgradeState {
                case .connected:
                    context.fireChannelRead(self.wrapInboundOut(.end(headers)))
                case .pendingConnection:
                    self.bufferedEnd = headers
                default:
                    break
                }
            case .head:
                assertionFailure("Not possible")
            }
            
            return
        }
        
        if let parsedUrl = URL(string: head.uri), parsedUrl.scheme == "http" {
            channelReadHttp(context: context, data: data)
            return
        }
        
        guard head.method == .CONNECT else {
            self.httpErrorAndClose(context: context)
            return
        }
        
        let components = head.uri.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = components.first ?? "" // There will always be a first.
        let port = components.last.flatMap { Int($0, radix: 10) } ?? 80  // Port 80 if not specified
        
        
        self.upgradeState = .beganConnecting
        self.connectTo(host: String(host), port: port, context: context)
    }
    
    private func connectTo(host: String, port: Int, context: ChannelHandlerContext) {
        
        let channelFuture = ClientBootstrap(group: context.eventLoop)
            .connect(host: String(host), port: port)
        
        channelFuture.whenSuccess { [weak self] channel in
            self?.connectSucceeded(channel: channel, context: context)
        }
        channelFuture.whenFailure { [weak self] error in
            self?.connectFailed(error: error, context: context)
        }
    }
    
    private func connectSucceeded(channel: Channel, context: ChannelHandlerContext) {
        
        switch self.upgradeState {
        case .beganConnecting:
            self.upgradeState = .awaitingEnd(connectResult: channel)
            
        case .awaitingConnection(pendingBytes: let pendingBytes):
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)
            self.glue(channel, context: context)
            
        case .awaitingEnd(let peerChannel):
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)
            
        case .idle, .upgradeFailed, .upgradeComplete:
            context.close(promise: nil)
        default:
            break
        }
    }
    
    private func connectFailed(error: Error, context: ChannelHandlerContext) {
        
        switch self.upgradeState {
        case .beganConnecting, .awaitingConnection:
            self.httpErrorAndClose(context: context)
            
        case .awaitingEnd(let peerChannel):
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)
            
        case .idle, .upgradeFailed, .upgradeComplete:
            context.close(promise: nil)
        default:
            break
        }
        
        context.fireErrorCaught(error)
    }
    
    private func glue(_ peerChannel: Channel, context: ChannelHandlerContext, throttle: Bool = false) {
        
        let headers = HTTPHeaders([("Content-Length", "0")])
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        
        self.removeEncoder(context: context)
        
        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        context.channel.pipeline.addHandler(localGlue).and(peerChannel.pipeline.addHandler(peerGlue)).whenComplete { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                context.pipeline.removeHandler(self, promise: nil)
            case .failure:
                // Close connected peer channel before closing our channel.
                peerChannel.close(mode: .all, promise: nil)
                context.close(promise: nil)
            }
        }
    }
    
    private func httpErrorAndClose(context: ChannelHandlerContext) {
        self.upgradeState = .upgradeFailed
        
        let headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .badRequest, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
    }
    
    private func removeDecoder(context: ChannelHandlerContext) {
        context.pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self).whenSuccess {
            context.pipeline.removeHandler(context: $0, promise: nil)
        }
    }
    
    private func removeEncoder(context: ChannelHandlerContext) {
        context.pipeline.context(handlerType: HTTPResponseEncoder.self).whenSuccess {
            context.pipeline.removeHandler(context: $0, promise: nil)
        }
    }
}

// MARK: - HTTPConnectHandler
extension HttpHttpsConnectHandler {
    func sendDataTo(context: ChannelHandlerContext) {
        if case let .pendingConnection(head) = self.upgradeState {
            self.upgradeState = .connected
            
            context.fireChannelRead(self.wrapInboundOut(.head(head)))
            
            if let bufferedBody = self.bufferedBody {
                context.fireChannelRead(self.wrapInboundOut(.body(.byteBuffer(bufferedBody))))
                self.bufferedBody = nil
            }
            
            if let bufferedEnd = self.bufferedEnd {
                context.fireChannelRead(self.wrapInboundOut(.end(bufferedEnd)))
                self.bufferedEnd = nil
            }
            
            context.fireChannelReadComplete()
        }
    }
    
    enum ConnectError: Error {
        case invalidURL
        case wrongScheme
        case wrongHost
    }
    
    func channelReadHttp(context: ChannelHandlerContext, data: InboundIn) {
        guard case .head(var head) = data else {
            return
        }
        
        
        guard let parsedUrl = URL(string: head.uri) else {
            context.fireErrorCaught(ConnectError.invalidURL)
            return
        }
        
        
        guard let host = head.headers.first(where: { $0.name == "Host" })?.value, let parsedHost = parsedUrl.host, host == parsedHost else {
            context.fireErrorCaught(ConnectError.wrongHost)
            return
        }
        
        var targetUrl = parsedUrl.path
        
        if let query = parsedUrl.query {
            targetUrl += "?\(query)"
        }
        
        head.uri = targetUrl
        
        switch upgradeState {
        case .idle:
            upgradeState = .pendingConnection(head: head)
            connectToHTTP(host: host, port: 80, context: context)
        case .pendingConnection:
            break
        case .connected:
            context.fireChannelRead(self.wrapInboundOut(.head(head)))
        default:
            break
        }
    }
    
    private func connectToHTTP(host: String, port: Int, context: ChannelHandlerContext) {
        
        let channelFuture = ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(HTTPRequestEncoder()).flatMap {
                    channel.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)))
                }
            }
            .connect(host: host, port: port)
        
        
        channelFuture.whenSuccess { channel in
            self.connectSucceededHTTP(channel: channel, context: context)
        }
        channelFuture.whenFailure { error in
            self.connectFailedHttp(error: error, context: context)
        }
    }
    
    private func connectSucceededHTTP(channel: Channel, context: ChannelHandlerContext) {
        self.glueHTTP(channel, context: context)
    }
    
    private func connectFailedHttp(error: Error, context: ChannelHandlerContext) {
        context.fireErrorCaught(error)
    }
    
    private func glueHTTP(_ peerChannel: Channel, context: ChannelHandlerContext) {
        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        context.channel.pipeline.addHandler(localGlue).and(peerChannel.pipeline.addHandler(peerGlue)).whenComplete { result in
            switch result {
            case .success:
                self.sendDataTo(context: context)
            case .failure:
                // Close connected peer channel before closing our channel.
                peerChannel.close(mode: .all, promise: nil)
                context.close(promise: nil)
            }
        }
    }
}
