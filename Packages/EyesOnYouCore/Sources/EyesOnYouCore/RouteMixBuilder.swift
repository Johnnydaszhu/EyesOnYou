import Foundation

/// Builds the route chart from measured bytes.
///
/// An explicit per-app route may be shown when that app has no traffic yet, but an
/// enabled macOS system proxy is never treated as proof of proxy traffic.
public enum RouteMixBuilder {
    public static func make(
        routes: RouteDirectionalTotals,
        selectedRoute: RouteAction?,
        blockedFallback: UInt64,
        activeRules: Int
    ) -> RouteMix {
        let blocked = routes.all.flowsBlocked > 0
            ? routes.all.flowsBlocked
            : blockedFallback
        let total = routes.all.totalBytes
        if total > 0 {
            let denominator = Double(total)
            let direct = Double(routes.direct.totalBytes) / denominator * 100
            let system = Double(routes.systemProxy.totalBytes) / denominator * 100
            let custom = Double(routes.customProxy.totalBytes) / denominator * 100
            let unknown = max(0, 100 - direct - system - custom)
            return RouteMix(
                directPercent: direct,
                systemProxyPercent: system,
                customProxyPercent: custom,
                unknownPercent: unknown,
                blockedCount: blocked,
                activeRules: activeRules
            )
        }

        if let selectedRoute {
            switch selectedRoute {
            case .inherit:
                break
            case .direct:
                return RouteMix(
                    directPercent: 100,
                    blockedCount: blocked,
                    activeRules: activeRules
                )
            case .systemProxy:
                return RouteMix(
                    systemProxyPercent: 100,
                    blockedCount: blocked,
                    activeRules: activeRules
                )
            case .proxy:
                return RouteMix(
                    customProxyPercent: 100,
                    blockedCount: blocked,
                    activeRules: activeRules
                )
            }
        }

        return RouteMix(
            blockedCount: blocked,
            activeRules: activeRules
        )
    }
}
