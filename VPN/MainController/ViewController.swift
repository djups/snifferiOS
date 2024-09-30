//
//  ViewController.swift
//  VPN
//
//  Created by Alexei Jovmir on 18/4/24.
//

import UIKit
import NetworkExtension
import RealmSwift

final class ViewController: UIViewController, ObservableObject {
    var tunnel: NETunnelProviderManager!
    var token: NotificationToken?
    private var packets = [Packet]()
    
    @IBOutlet weak var startTunel: UIButton!
    @IBOutlet weak var tableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            self.tunnel = managers?.first
            if self.tunnel == nil {
                self.startTunel.isEnabled = false
            }
        }
        setupObserver()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UINib(nibName: "PacketTableViewCell", bundle: nil), forCellReuseIdentifier: "PacketTableViewCell")
    }
    
    private func setupObserver() {
        DispatchQueue.main.async {
            do {
                let results = realm.objects(Packet.self)
                
                self.token = results.observe({ [weak self] changes in
                    self?.packets = results.map(Packet.init)
                    self?.tableView.reloadData()
                })
            } catch let error {
                print(error.localizedDescription)
            }
        }
    }
    
    @IBAction func makeTunel(_ sender: UIButton) {
        let tunnel = buildTunnelProviderManager()
        tunnel.saveToPreferences { error in
            if error == nil {
            }
            tunnel.loadFromPreferences { [weak self] error in
                self?.tunnel = tunnel
                self?.startTunel.isEnabled = true
            }
        }
    }
    
    @IBAction func deleteAll(_ sender: Any) {
        try! realm.write {
            realm.deleteAll()
        }
    }
    
    @IBAction func buttonStartTapped() {
        
        do {
            try tunnel.connection.startVPNTunnel(options: [
                NEVPNConnectionStartOptionUsername: "test"
            ] as [String : NSObject])
        } catch {
            print("error.localizedDescription \(error.localizedDescription)")
        }
    }
    
    private func buildTunnelProviderManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "Test VPN"
        
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "snifferiOS.VPN.NetworkExtensionVPN"
        proto.serverAddress = "\(proxyServerAddress):\(proxyServerPort)"
        proto.providerConfiguration = [:]
        proto.username = "test"
        manager.protocolConfiguration = proto
        
        manager.isEnabled = true
        
        return manager
    }
}

extension ViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return packets.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "PacketTableViewCell", for: indexPath) as! PacketTableViewCell
        cell.packetTitle?.text = packets[indexPath.row].name
        return cell
    }
}
