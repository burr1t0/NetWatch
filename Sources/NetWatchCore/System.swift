import Foundation
import SystemConfiguration
import CoreWLAN
import IOKit.ps

struct NetEnv {
    var iface: String?
    var gateway: String?
    var dnsServers: [String] = []
    var vpn = false
}

/// Reads network state from the OS without spawning processes.
enum SystemInfo {
    private static let tunnelPrefixes = ["utun", "ppp", "ipsec", "ipsec0", "gif", "stf"]

    private static func isTunnel(_ name: String) -> Bool {
        tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    static func environment() -> NetEnv {
        guard let store = SCDynamicStoreCreate(nil, "NetWatch" as CFString, nil, nil) else { return NetEnv() }
        var env = NetEnv()

        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        if let primary = global?["PrimaryInterface"] as? String { env.vpn = isTunnel(primary) }

        let wifiName = CWWiFiClient.shared().interface()?.interfaceName
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []

        // Physical services that have a router, Wi-Fi first.
        var candidates: [(iface: String, router: String, key: String)] = []
        for key in keys {
            guard let d = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let name = d["InterfaceName"] as? String, !isTunnel(name),
                  let router = d["Router"] as? String else { continue }
            candidates.append((name, router, key))
        }
        guard let pick = candidates.first(where: { $0.iface == wifiName }) ?? candidates.first else { return env }

        env.iface = pick.iface
        env.gateway = pick.router
        let dnsKey = pick.key.replacingOccurrences(of: "/IPv4", with: "/DNS")
        if let d = SCDynamicStoreCopyValue(store, dnsKey as CFString) as? [String: Any],
           let servers = d["ServerAddresses"] as? [String] {
            env.dnsServers = servers.filter { !$0.contains(":") } // IPv4 only for now
        }
        return env
    }

    static func wifi() -> WiFiInfo? {
        guard let i = CWWiFiClient.shared().interface(), let name = i.interfaceName,
              let ch = i.wlanChannel(), i.rssiValue() != 0 else { return nil }
        let band: String
        switch ch.channelBand {
        case .band2GHz: band = "2.4GHz"
        case .band5GHz: band = "5GHz"
        case .band6GHz: band = "6GHz"
        default: band = "?"
        }
        let n = ch.channelNumber
        let dfs = band == "5GHz" && ((52...64).contains(n) || (100...144).contains(n))
        return WiFiInfo(interface: name, rssi: i.rssiValue(), noise: i.noiseMeasurement(),
                        txRateMbps: i.transmitRate(), channel: n, band: band, isDFS: dfs)
    }

    struct IfCounters {
        var rx: UInt32
        var tx: UInt32
        var rxErr: UInt32
        var txErr: UInt32
    }

    /// Byte and error counters per interface. They are 32-bit, so callers subtract with wrapping arithmetic.
    static func interfaceCounters() -> [String: IfCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: IfCounters] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let raw = ifa.ifa_data else { continue }
            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            result[String(cString: ifa.ifa_name)] = IfCounters(rx: d.ifi_ibytes, tx: d.ifi_obytes, rxErr: d.ifi_ierrors, txErr: d.ifi_oerrors)
        }
        return result
    }

    static func systemStats() -> SystemStats {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let info = ProcessInfo.processInfo
        return SystemStats(load1: load[0], cores: info.activeProcessorCount, thermal: info.thermalState.rawValue,
                           lowPower: info.isLowPowerModeEnabled, onBattery: onBattery())
    }

    static func onBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
