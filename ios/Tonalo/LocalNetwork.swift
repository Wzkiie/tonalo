import Foundation
import Network

/// What the app can tell about the network it's in – without asking for location access (which the Wi-Fi name needs):
/// the device's own IPv4 addresses with their netmasks, and the router addresses iOS reports.
enum LocalNetwork {
    private struct Address { let ip: UInt32; let mask: UInt32 }

    /// IPv4 addresses of the active Wi-Fi/Ethernet interfaces.
    private static func addresses() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [Address] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard String(cString: i.ifa_name).hasPrefix("en"), Int32(i.ifa_flags) & IFF_UP != 0,
                  let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = i.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            out.append(Address(ip: ip, mask: m))
        }
        return out
    }

    private static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return nil }
        return parts.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Whether an IPv4 address lies in the subnet the device itself is in. Nil for host names and IPv6,
    /// which can't be checked this way. In a café whose network has other addresses, the home address can't be there.
    static func sameSubnet(_ host: String) -> Bool? {
        guard let ip = ipv4(host) else { return nil }
        return addresses().contains { $0.mask != 0 && $0.ip & $0.mask == ip & $0.mask }
    }

    /// Changes when the device joins another network: its own addresses and the routers'.
    static func fingerprint(_ path: NWPath) -> String {
        let own = addresses().map { "\($0.ip)/\($0.mask)" }.sorted()
        let routers = path.gateways.map { "\($0)" }.sorted()
        return (own + ["|"] + routers).joined(separator: ",")
    }
}
