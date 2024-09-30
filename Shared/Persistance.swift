//
//  Persistance.swift
//  VPN
//
//  Created by Alexei Jovmir on 3/5/24.
//

import Foundation
import RealmSwift

let proxyServerPort: Int = 8888;
let proxyServerAddress = "127.0.0.1";

let fileURL = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.J3JX9R3MM2.snifferiOS.VPN")!
    .appendingPathComponent("default.realm")
let config = Realm.Configuration(fileURL: fileURL)
let realm = try! Realm(configuration: config)

final class Packet: Object {
    @Persisted var name: String
}



