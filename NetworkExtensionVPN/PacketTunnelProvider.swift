//
//  PacketTunnelProvider.swift
//  NetworkExtensionVPN
//
//  Created by Alexei Jovmir on 18/4/24.
//

import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        
        startServer()
        
        let settings: NEPacketTunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: proxyServerAddress)
        let proxySettings: NEProxySettings = NEProxySettings()
        proxySettings.httpServer = NEProxyServer(
            address: proxyServerAddress,
            port: proxyServerPort
        )
        
        proxySettings.httpsServer = NEProxyServer(
            address: proxyServerAddress,
            port: proxyServerPort
        )
        
        proxySettings.autoProxyConfigurationEnabled = false
        proxySettings.httpEnabled = true
        proxySettings.httpsEnabled = true
        proxySettings.excludeSimpleHostnames = true
        proxySettings.exceptionList = [
            "192.168.0.0/16",
            "10.0.0.0/8",
            "172.16.0.0/12"
        ]
        
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        settings.proxySettings = proxySettings
        
        let ipv4Settings: NEIPv4Settings = NEIPv4Settings(
            addresses: [settings.tunnelRemoteAddress],
            subnetMasks: ["255.255.255.255"]
        )
        
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0")
        ]
        settings.ipv4Settings = ipv4Settings
        
        settings.mtu = 1500
        setTunnelNetworkSettings(settings) { error in
            if let e = error {
                NSLog("Settings error %@", e.localizedDescription)
                completionHandler(e)
            } else {
                NSLog("Settings set without error")
                completionHandler(nil)
            }
        }
        
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let handler = completionHandler {
            handler(messageData)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    private func startServer() {
        Task.detached {
            let webServer = Server(host: proxyServerAddress, port: proxyServerPort)
            webServer.start()
        }
    }
    
}
