/// Decides whether a *per-app* route claim (badge / confidence) is supportable.
///
/// Socket inspection can see which apps entered a local proxy and which routes left
/// the proxy, but it cannot pair those two sides. Multiple apps plus multiple route
/// kinds therefore forbid a per-app route badge: no single app can be asserted as
/// "proxied" or "direct".
///
/// This gate deliberately does NOT apply to byte accounting. The direct/proxy/unknown
/// egress mix is measured per connection at the host level and stays route-specific;
/// only which client owns each byte is a (disclosed) proportional estimate.
public enum ProxyEgressAttribution {
    public static func requiresUnknownPerApp(
        clientCount: Int,
        directEgress: Int,
        proxyEgress: Int,
        unknownEgress: Int
    ) -> Bool {
        guard clientCount > 1 else { return false }
        let observedKinds = [
            directEgress > 0,
            proxyEgress > 0,
            unknownEgress > 0,
        ].filter { $0 }.count
        return observedKinds > 1
    }
}
