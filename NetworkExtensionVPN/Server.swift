
import Foundation
import NIOHTTP1
import NIO
import NIOTransportServices
import NIOSSL

final class Server {
    // MARK: - Private properties
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private var host: String
    private var port: Int
    
    // MARK: - Initializers
    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
    
    // MARK: - Public functions
    func start() {
        
        defer {
            try! group.syncShutdownGracefully()
        }
        
        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            
            let bootstrap = ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    
                    channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))).flatMap {
                        
                        return channel.pipeline.addHandler(HTTPResponseEncoder()).flatMap {
                            channel.pipeline.addHandler(HttpHttpsConnectHandler())
                        }
                    }
                }
            
            let channel = try! bootstrap.bind(host: host, port: port).wait()
            
            try! channel.closeFuture.wait() // wait forever as we never close the Channel
            
        } catch {
            print("An error happed \(error.localizedDescription)")
            exit(0)
        }
    }
    
    func stop() {
        do {
            try group.syncShutdownGracefully()
        } catch {
            print("An error happed \(error.localizedDescription)")
            exit(0)
        }
    }
}
