import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

/// How the machine's proxy client (Clash / Shadowrocket / Surge / …) is actually
/// deployed — the thing users mean by "配置模式还是代理模式".
///
/// The same merged proxy dictionary can come from very different setups, and what
/// EyesOnYou can monitor or enforce differs for each:
/// - a proxy written at the settings layer (`networksetup`, Clash "system proxy"),
/// - a proxy published by a VPN's NetworkExtension (Shadowrocket, Clash TUN with
///   "set system proxy"), which outranks the settings layer,
/// - a TUN tunnel with no proxy config at all (captures everything at the IP layer),
/// - a PAC / WPAD script.
public struct ProxyDeploymentSnapshot: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        /// No proxy configured and no tunnel up.
        case none
        /// A utun tunnel is up but no proxy is configured: all traffic is captured
        /// at the IP layer (Clash/Surge enhanced mode without system proxy).
        case tunnelOnly = "tunnel_only"
        /// The proxy settings are published by a VPN / NetworkExtension service and
        /// shadow anything written with `networksetup`.
        case vpnProvidedProxy = "vpn_provided_proxy"
        /// The proxy lives at the macOS settings layer (Clash "system proxy" mode,
        /// or EyesOnYou's own takeover).
        case systemProxy = "system_proxy"
        /// Routing is decided per-URL by a PAC script / WPAD; not chainable.
        case pac
    }

    public var mode: Mode
    /// Human endpoint for the active mode (proxy host:port or PAC URL).
    public var endpoint: String?
    /// At least one utun interface is up.
    public var tunnelActive: Bool
    /// The system resolver answers from 198.18.0.0/15 — a fake-IP DNS run inside
    /// the tunnel, meaning domain resolution itself happens in the proxy client.
    public var fakeIPDNS: Bool

    public init(mode: Mode, endpoint: String?, tunnelActive: Bool, fakeIPDNS: Bool) {
        self.mode = mode
        self.endpoint = endpoint
        self.tunnelActive = tunnelActive
        self.fakeIPDNS = fakeIPDNS
    }
}

public enum ProxyDeploymentClassifier {
    /// Pure classification from independently observable facts (all injectable in
    /// tests; the live gathering lives in `ProxyDeploymentReader`).
    public static func classify(
        merged: SystemProxySnapshot,
        setupLayerHasFixedProxy: Bool,
        serviceLayerHasFixedProxy: Bool,
        tunnelActive: Bool,
        fakeIPDNS: Bool
    ) -> ProxyDeploymentSnapshot {
        if merged.autoConfigEnabled, let url = merged.autoConfigURL, !url.isEmpty {
            return .init(mode: .pac, endpoint: url, tunnelActive: tunnelActive, fakeIPDNS: fakeIPDNS)
        }
        if merged.autoDiscoveryEnabled {
            return .init(mode: .pac, endpoint: "WPAD", tunnelActive: tunnelActive, fakeIPDNS: fakeIPDNS)
        }
        if let endpoint = merged.primaryEndpointLabel {
            // A dynamic (State:) per-service proxy wins the merge over the Setup:
            // layer, so its presence — not the Setup layer's — decides the mode.
            let mode: ProxyDeploymentSnapshot.Mode = serviceLayerHasFixedProxy
                ? .vpnProvidedProxy
                : .systemProxy
            return .init(mode: mode, endpoint: endpoint, tunnelActive: tunnelActive, fakeIPDNS: fakeIPDNS)
        }
        return .init(
            mode: tunnelActive ? .tunnelOnly : .none,
            endpoint: nil,
            tunnelActive: tunnelActive,
            fakeIPDNS: fakeIPDNS
        )
    }

    /// True when a dynamic-store Proxies dictionary carries a usable fixed proxy.
    /// (`Enable` flags arrive as NSNumber 0/1 from SCDynamicStore.)
    public static func hasFixedProxy(_ dictionary: [String: Any]) -> Bool {
        func enabled(_ key: String) -> Bool {
            if let n = dictionary[key] as? NSNumber { return n.boolValue }
            if let i = dictionary[key] as? Int { return i != 0 }
            return false
        }
        return enabled("HTTPEnable") || enabled("HTTPSEnable") || enabled("SOCKSEnable")
    }

    /// True when any resolver lives in the fake-IP benchmarking range 198.18.0.0/15.
    public static func isFakeIPResolver(_ servers: [String]) -> Bool {
        servers.contains { $0.hasPrefix("198.18.") || $0.hasPrefix("198.19.") }
    }
}

/// Gathers the live facts for `ProxyDeploymentClassifier` from the SystemConfiguration
/// dynamic store (the same data `scutil` shows). Read-only.
public enum ProxyDeploymentReader {
    public static func current(
        merged: SystemProxySnapshot,
        tunnelActive: Bool = HostNetworkSampler.hasActiveTunnelInterface()
    ) -> ProxyDeploymentSnapshot {
        #if canImport(SystemConfiguration)
        let store = SCDynamicStoreCreate(nil, "EyesOnYou.ProxyDeployment" as CFString, nil, nil)
        return ProxyDeploymentClassifier.classify(
            merged: merged,
            setupLayerHasFixedProxy: anyServiceProxies(store, layer: "Setup"),
            serviceLayerHasFixedProxy: anyServiceProxies(store, layer: "State"),
            tunnelActive: tunnelActive,
            fakeIPDNS: ProxyDeploymentClassifier.isFakeIPResolver(globalDNSServers(store))
        )
        #else
        return ProxyDeploymentClassifier.classify(
            merged: merged,
            setupLayerHasFixedProxy: false,
            serviceLayerHasFixedProxy: false,
            tunnelActive: tunnelActive,
            fakeIPDNS: false
        )
        #endif
    }

    #if canImport(SystemConfiguration)
    private static func anyServiceProxies(_ store: SCDynamicStore?, layer: String) -> Bool {
        guard let store else { return false }
        let pattern = "\(layer):/Network/Service/[^/]+/Proxies"
        guard let values = SCDynamicStoreCopyMultiple(store, nil, [pattern] as CFArray)
                as? [String: [String: Any]] else {
            return false
        }
        return values.values.contains(where: ProxyDeploymentClassifier.hasFixedProxy)
    }

    private static func globalDNSServers(_ store: SCDynamicStore?) -> [String] {
        guard let store,
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString)
                as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String] else {
            return []
        }
        return servers
    }
    #endif
}
