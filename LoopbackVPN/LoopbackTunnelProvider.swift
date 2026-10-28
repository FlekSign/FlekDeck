//
//  LoopbackTunnelProvider.swift
//  LoopbackVPN
//
//  A VPN that leads nowhere but back to this device. Built-in JIT needs it:
//  iOS's debug service only takes a connection that arrives from somewhere
//  else, never one from the device itself, and what arrives through this
//  tunnel looks like it came from another machine.
//
//  The tunnel carries only what is sent to its peer address. Every packet read
//  from it is written straight back with its source and destination swapped: a
//  packet from this device to the peer returns as one from the peer to this
//  device, so the two ends of the connection are both here. Nothing leaves the
//  device and no other traffic is routed through it.
//
//  This is the approach of LocalDevVPN (formerly StosVPN), whose addresses are
//  kept so that either works with the same tools.
//

import NetworkExtension

final class LoopbackTunnelProvider: NEPacketTunnelProvider {
    /// This device's address on the tunnel.
    private static let interfaceAddress = "10.7.0.0"
    /// The address that stands for this device as seen from outside, and the
    /// one built-in JIT connects to.
    private static let peerAddress = "10.7.0.1"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let ipv4 = NEIPv4Settings(addresses: [Self.interfaceAddress], subnetMasks: ["255.255.255.0"])
        // Only the peer goes through the tunnel; everything else keeps the
        // route it had.
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: Self.peerAddress, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [NEIPv4Route.default()]

        // The remote address is what Settings shows; it plays no part in routing.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.peerAddress)
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            if error == nil {
                self?.reflectPackets()
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    /// Hands back whatever comes in, turned around, for as long as the tunnel
    /// is up: the read is asked for again from its own completion.
    private func reflectPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            let reflected = zip(packets, protocols).map { packet, family in
                family.int32Value == AF_INET ? Self.swappingAddresses(of: packet) : packet
            }
            self.packetFlow.writePackets(reflected, withProtocols: protocols)
            self.reflectPackets()
        }
    }

    /// An IPv4 header holds its source address in bytes 12 to 15 and its
    /// destination in 16 to 19. Both checksums cover the two addresses as a
    /// sum, so exchanging them leaves the checksums valid.
    private static func swappingAddresses(of packet: Data) -> Data {
        guard packet.count >= 20 else {
            return packet
        }
        var packet = packet
        packet.withUnsafeMutableBytes { bytes in
            for offset in 12..<16 {
                bytes.swapAt(offset, offset + 4)
            }
        }
        return packet
    }
}
