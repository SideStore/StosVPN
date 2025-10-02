//
//  PacketTunnelProvider.swift
//  TunnelProv
//
//  Created by Stossy11 on 28/03/2025.
//

import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    var tunnelDeviceIp: String = "10.7.0.0"
    var tunnelFakeIp: String = "10.7.0.1"
    var tunnelSubnetMask: String = "255.255.255.0"
    
    private var deviceIpValue: UInt32 = 0
    private var fakeIpValue: UInt32 = 0
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let deviceIp = options?["TunnelDeviceIP"] as? String {
            tunnelDeviceIp = deviceIp
        }
        if let fakeIp = options?["TunnelFakeIP"] as? String {
            tunnelFakeIp = fakeIp
        }
        
        deviceIpValue = ipToUInt32(tunnelDeviceIp)
        fakeIpValue = ipToUInt32(tunnelFakeIp)
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelDeviceIp)
        let ipv4 = NEIPv4Settings(addresses: [tunnelDeviceIp], subnetMasks: [tunnelSubnetMask])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: tunnelDeviceIp, subnetMask: tunnelSubnetMask)]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        
        setTunnelNetworkSettings(settings) { error in
            guard error == nil else { return completionHandler(error) }
            self.setPackets()
            completionHandler(nil)
        }
    }
    
    func setPackets() {
        packetFlow.readPackets { [self] packets, protocols in
            let fakeip = self.fakeIpValue
            let deviceip = self.deviceIpValue
            var modified = packets
            for i in modified.indices where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
                modified[i].withUnsafeMutableBytes { bytes in
                    guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                    let src = UInt32(bigEndian: ptr[3])
                    let dst = UInt32(bigEndian: ptr[4])
                    if src == deviceip { ptr[3] = fakeip.bigEndian }
                    if dst == fakeip { ptr[4] = deviceip.bigEndian }
                }
            }
            self.packetFlow.writePackets(modified, withProtocols: protocols)
            setPackets()
        }
    }

    private func ipToUInt32(_ ipString: String) -> UInt32 {
        let components = ipString.split(separator: ".")
        guard components.count == 4,
              let b1 = UInt32(components[0]),
              let b2 = UInt32(components[1]),
              let b3 = UInt32(components[2]),
              let b4 = UInt32(components[3]) else {
            return 0
        }
        return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    }
}
